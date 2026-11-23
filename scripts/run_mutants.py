#!/usr/bin/env python3
"""Run every RTL mutant in testbench/mutants/ against its killing test and report the result.

For each patch:
  1. create a temporary git worktree at HEAD and overlay the current working tree on it
     (modified, new and deleted files; ignored files are not copied), so the run sees exactly
     the RTL and tests being reviewed; submodules (PicoRV32) are linked from the main checkout;
  2. apply the patch there (the main working tree is never modified);
  3. run the killing test named in testbench/mutants/README.md with pytest;
  4. parse pytest's JUnit file and cocotb's results files (<node>.result.xml).

Verdicts:
  KILLED    the killing test failed and, if the row names a required kill mechanism, the
            simulator log shows it (see below)
  WRONG     the killing test failed, but not through the required mechanism
  SURVIVED  the killing test passed
  ERROR     the patch did not apply, the test was not collected, or no simulation ran

Required kill mechanism (the table's fourth column; "—" for none): one or more backticked names,
any one of which must appear. `a_name` (or a dotted `u_inst.a_name`) is an assertion: an
"Assertion failed" line must name it. `[ID]` is a UVM message ID: a UVM_ERROR or UVM_FATAL line
with that ID must appear in the UVM test's log (testbench/uvm). So a UVM kill through the
scoreboard (`[SB]`), the hang watchdog (`[HANG]`) or the status monitor (`[STATUS]`) cannot be
replaced by an unrelated failure without the verdict turning WRONG.

The report's "First failure" for a UVM kill is the first assertion, UVM_ERROR or UVM_FATAL line of
the simulator log (worktree paths removed); for a cocotb kill, the first failing cocotb test.

Before the mutants, every distinct killing test runs once on the unmutated tree (baseline); a
failing baseline aborts the run, since a kill would then mean nothing.

With --table FILE the mutants and killing tests come from that Markdown table instead (same row
format; every name must be a patch in testbench/mutants/): testbench/uvm/mutants.md runs a set of
the same patches against the UVM bench.

Usage: scripts/run_mutants.py [-j JOBS] [--table FILE] [--report FILE] [--no-baseline] [name ...]
Exit status: 0 if every selected mutant is KILLED, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MUTANT_DIR = ROOT / "testbench" / "mutants"
README = MUTANT_DIR / "README.md"
LOG_DIR = ROOT / "sim_build" / "mutants"

# | `m01_name` | bug | `testbench/unit/test_x.py::test_x[icarus-8]` | `a_name`, `[ID]` or — |
ROW_RE = re.compile(
    r"^\| `(?P<name>m\d+_\w+)` \| (?P<bug>[^|]+) \| `(?P<node>[^`]+)` \| (?P<req>[^|]+) \|$"
)
UVM_ID_RE = re.compile(r"^\[(\w+)\]$")
ASSERTION_RE = re.compile(r"^[A-Za-z_][\w.]*$")
# A UVM report line of severity ERROR or FATAL, with its message ID (not the summary counts).
UVM_MSG_RE = re.compile(r"^UVM_(?:ERROR|FATAL) .*? \[(?P<id>\w+)\] ")


@dataclass(frozen=True)
class Mutant:
    name: str
    bug: str
    node: str  # pytest node id, relative to the repository root
    requires: tuple[str, ...] = ()  # any one of: assertion names, UVM message IDs as "[ID]"

    @property
    def patch(self) -> Path:
        return MUTANT_DIR / f"{self.name}.patch"


@dataclass
class Result:
    mutant: Mutant | None
    node: str
    verdict: str
    detail: str
    log: Path


def parse_readme(text: str | None = None) -> list[Mutant]:
    """Mutant table rows of testbench/mutants/README.md, in order."""
    text = README.read_text() if text is None else text
    mutants = []
    for line in text.splitlines():
        m = ROW_RE.match(line.strip())
        if m:
            req = tuple(re.findall(r"`([^`]+)`", m["req"]))
            bad = [r for r in req if not (UVM_ID_RE.match(r) or ASSERTION_RE.match(r))]
            if bad:
                raise ValueError(f"{m['name']}: not an assertion or a UVM ID: {bad}")
            mutants.append(Mutant(m["name"], m["bug"].strip(), m["node"], req))
    return mutants


def uvm_logs(wt: Path) -> list[Path]:
    """The UVM simulator logs of a run in worktree `wt` (testbench/uvm writes one per test)."""
    return sorted(p for p in (wt / "sim_build" / "uvm").glob("*.log") if p.name != "build.log")


def failure_lines(text: str) -> list[str]:
    """Assertion failures and UVM_ERROR / UVM_FATAL messages, in log order."""
    return [
        ln.strip() for ln in text.splitlines() if "Assertion failed" in ln or UVM_MSG_RE.match(ln)
    ]


def mechanism_hit(requires: tuple[str, ...], lines: list[str]) -> str | None:
    """The first failure line that shows one of the required mechanisms, or None."""
    for ln in lines:
        for r in requires:
            uvm_id = UVM_ID_RE.match(r)
            if uvm_id:
                m = UVM_MSG_RE.match(ln)
                if m and m["id"] == uvm_id[1]:
                    return ln
            elif "Assertion failed" in ln and re.search(rf"(^|[\s.]){re.escape(r)}\b", ln):
                return ln
    return None


def strip_paths(line: str, wt: Path) -> str:
    """Drop the temporary worktree and the repository root from paths in a log line."""
    for prefix in (f"{wt}/", f"{ROOT}/"):
        line = line.replace(prefix, "")
    return line


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout


def make_worktree(parent: Path, tag: str) -> Path:
    """A worktree at HEAD with the current working tree's changes copied over it."""
    wt = parent / tag
    git("worktree", "add", "--detach", "--quiet", str(wt), "HEAD")
    # Modified and untracked, non-ignored files (honours .gitignore and info/exclude).
    for rel in git("ls-files", "-z", "-m", "-o", "--exclude-standard").split("\0"):
        if rel and (ROOT / rel).is_file():
            dst = wt / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, dst)
    for rel in git("ls-files", "-z", "-d").split("\0"):
        if rel:
            (wt / rel).unlink(missing_ok=True)
    link_submodules(wt)
    return wt


def submodule_paths() -> list[str]:
    """Paths of the submodules listed in .gitmodules."""
    if not (ROOT / ".gitmodules").exists():
        return []
    out = subprocess.run(
        ["git", "config", "--file", ".gitmodules", "--get-regexp", r"\.path$"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout  # fmt: skip
    return [line.split(maxsplit=1)[1] for line in out.splitlines() if " " in line]


def link_submodules(wt: Path) -> None:
    """A new worktree has empty submodule directories; link the main tree's checkouts instead
    (mutants never patch third-party code), so tests that build the SoC find PicoRV32."""
    for rel in submodule_paths():
        src, dst = ROOT / rel, wt / rel
        if not src.is_dir() or not any(src.iterdir()):
            continue  # not checked out in the main tree either
        if dst.is_dir() and not dst.is_symlink():
            if any(dst.iterdir()):
                continue
            dst.rmdir()
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.symlink_to(src, target_is_directory=True)


def remove_worktree(wt: Path) -> None:
    subprocess.run(["git", "worktree", "remove", "--force", str(wt)], cwd=ROOT, capture_output=True)


def cocotb_results(wt: Path) -> list[Path]:
    """cocotb's results files (named <pytest node>.result.xml when run under pytest)."""
    sim = wt / "sim_build"
    return sorted({*sim.rglob("results.xml"), *sim.rglob("*.result.xml")})


def first_cocotb_failure(wt: Path) -> str | None:
    """'<test>: <message>' of the first failing cocotb test in any results file, or None."""
    for xml in cocotb_results(wt):
        for case in ET.parse(xml).getroot().iter("testcase"):
            for tag in ("failure", "error"):
                el = case.find(tag)
                if el is not None:
                    msg = (el.get("message") or el.text or "").strip().splitlines()
                    return f"{case.get('name')}: {msg[0] if msg else '(no message)'}"
    return None


def simulation_ran(wt: Path) -> bool:
    """A cocotb results file, or a UVM test log that reached run_test (testbench/uvm)."""
    if cocotb_results(wt):
        return True
    return any(
        "[RNTST]" in f.read_text(errors="replace") for f in (wt / "sim_build" / "uvm").glob("*.log")
    )


def junit_counts(xml: Path) -> tuple[int, int]:
    """(tests, failures + errors) from a pytest JUnit file; (0, 0) if it is missing."""
    if not xml.exists():
        return 0, 0
    root = ET.parse(xml).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    tests = sum(int(s.get("tests", 0)) for s in suites)
    bad = sum(int(s.get("failures", 0)) + int(s.get("errors", 0)) for s in suites)
    return tests, bad


def first_pytest_failure(xml: Path) -> str | None:
    if not xml.exists():
        return None
    for case in ET.parse(xml).getroot().iter("testcase"):
        for tag in ("failure", "error"):
            el = case.find(tag)
            if el is not None:
                msg = (el.get("message") or "").strip().splitlines()
                return msg[0] if msg else "(no message)"
    return None


def run_node(wt: Path, node: str, log: Path) -> tuple[int, int]:
    """Run one pytest node in the worktree; output goes to `log`. Returns (tests, failed)."""
    junit = wt / "sim_build" / "mutant_junit.xml"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as f:
        subprocess.run(
            [sys.executable, "-m", "pytest", node, "-q", "-s", "-p", "no:cacheprovider",
             f"--junitxml={junit}"],
            cwd=wt, stdout=f, stderr=subprocess.STDOUT,
        )  # fmt: skip
    return junit_counts(junit)


def run_one(parent: Path, mutant: Mutant | None, node: str) -> Result:
    tag = mutant.name if mutant else "baseline_" + re.sub(r"\W+", "_", node)
    log = LOG_DIR / f"{tag}.log"
    wt = make_worktree(parent, tag)
    try:
        if mutant:
            ap = subprocess.run(
                ["git", "apply", str(mutant.patch)], cwd=wt, capture_output=True, text=True
            )
            if ap.returncode:
                return Result(mutant, node, "ERROR", f"patch does not apply: {ap.stderr}", log)
        tests, failed = run_node(wt, node, log)
        sim_logs = uvm_logs(wt)
        # Failure lines: the UVM simulator logs if this is a UVM test, else the pytest log (which
        # carries the simulator output of cocotb tests).
        texts = [p.read_text(errors="replace") for p in sim_logs] or [
            log.read_text(errors="replace")
        ]
        lines = [strip_paths(ln, wt) for t in texts for ln in failure_lines(t)]
        if sim_logs:
            for p in sim_logs:  # keep the UVM logs next to the pytest log
                shutil.copy2(p, LOG_DIR / f"{tag}.{p.name}")
        detail = (lines[0] if sim_logs and lines else None) or first_cocotb_failure(wt)
        detail = detail or first_pytest_failure(wt / "sim_build" / "mutant_junit.xml")
        detail = strip_paths(detail, wt) if detail else detail
        if tests == 0:
            return Result(mutant, node, "ERROR", "test not collected (check the node id)", log)
        if not simulation_ran(wt):
            return Result(mutant, node, "ERROR", f"no simulation ran: {detail}", log)
        if failed == 0:
            return Result(mutant, node, "SURVIVED" if mutant else "PASS", "test passed", log)
        if mutant is None:
            return Result(None, node, "FAIL", detail or "failed", log)
        if mutant.requires:
            hit = mechanism_hit(mutant.requires, lines)
            want = " or ".join(mutant.requires)
            if not hit:
                first = lines[0] if lines else "no assertion or UVM error"
                return Result(mutant, node, "WRONG", f"{want} not seen (first: {first})", log)
            if sim_logs:
                return Result(mutant, node, "KILLED", detail or hit, log)
            return Result(mutant, node, "KILLED", f"{hit} | first failing test: {detail}", log)
        return Result(mutant, node, "KILLED", detail or "failed", log)
    finally:
        remove_worktree(wt)


def write_report(path: Path, results: list[Result], table: Path = README) -> None:
    killed = sum(r.verdict == "KILLED" for r in results)
    lines = [
        "# Mutation results",
        "",
        "Generated by `scripts/run_mutants.py`. Each mutant (`testbench/mutants/*.patch`) is",
        "applied in a temporary git worktree and its killing test from",
        f"`{table.resolve().relative_to(ROOT)}` is run; every killing test also passes on the",
        "unmutated design (baseline).",
        "",
        f"**{killed} / {len(results)} mutants killed.**",
        "",
        "Required: the kill mechanism the table names (an assertion, or a UVM message ID in",
        "brackets; any one of those listed), checked in the simulator log.",
        "",
        "| Mutant | Verdict | Killing test | Required | First failure |",
        "|---|---|---|---|---|",
    ]
    for r in results:
        assert r.mutant is not None
        detail = r.detail.replace("|", "\\|")
        req = " or ".join(f"`{x}`" for x in r.mutant.requires) or "—"
        lines.append(f"| `{r.mutant.name}` | {r.verdict} | `{r.node}` | {req} | {detail} |")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("names", nargs="*", help="mutant names or prefixes (default: all)")
    ap.add_argument("-j", "--jobs", type=int, default=3)
    ap.add_argument("--report", type=Path, help="write a Markdown report here")
    ap.add_argument("--no-baseline", action="store_true")
    ap.add_argument("--table", type=Path, default=README, help="mutant table (default: README)")
    args = ap.parse_args()

    mutants = parse_readme(args.table.read_text())
    listed = {m.name for m in mutants}
    patches = {p.stem for p in MUTANT_DIR.glob("*.patch")}
    if args.table.resolve() == README.resolve() and listed != patches:
        print(f"README and patches differ: {sorted(listed ^ patches)}", file=sys.stderr)
        return 1
    if not listed <= patches:
        print(f"no such patch: {sorted(listed - patches)}", file=sys.stderr)
        return 1
    if args.names:
        mutants = [m for m in mutants if any(m.name.startswith(n) for n in args.names)]
    if not mutants:
        print("no mutants selected", file=sys.stderr)
        return 1

    parent = Path(tempfile.mkdtemp(prefix="mutants_"))
    try:
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            if not args.no_baseline:
                nodes = sorted({m.node for m in mutants})
                base = list(pool.map(lambda n: run_one(parent, None, n), nodes))
                for r in base:
                    print(
                        f"baseline {r.verdict:4} {r.node}"
                        + ("" if r.verdict == "PASS" else f"  {r.detail}  (log {r.log})")
                    )
                if any(r.verdict != "PASS" for r in base):
                    print("baseline failed: fix the design or tests before judging mutants")
                    return 1
            results = list(pool.map(lambda m: run_one(parent, m, m.node), mutants))
    finally:
        shutil.rmtree(parent, ignore_errors=True)
        subprocess.run(["git", "worktree", "prune"], cwd=ROOT, capture_output=True)

    for r in results:
        assert r.mutant is not None
        print(f"{r.mutant.name:32} {r.verdict:8} {r.node}")
        print(f"    {r.detail}")
        if r.verdict != "KILLED":
            print(f"    log: {r.log}")
    killed = sum(r.verdict == "KILLED" for r in results)
    print(f"\n{killed}/{len(results)} mutants killed")
    if args.report:
        write_report(args.report, results, args.table)
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
