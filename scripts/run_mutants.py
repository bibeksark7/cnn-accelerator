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
  KILLED    the killing test failed, and, if the README names a required assertion, an
            "Assertion failed" line in the simulator log names that assertion
  WRONG     the killing test failed, but not through the required assertion
  SURVIVED  the killing test passed
  ERROR     the patch did not apply, the test was not collected, or no simulation ran

Before the mutants, every distinct killing test runs once on the unmutated tree (baseline); a
failing baseline aborts the run, since a kill would then mean nothing.

Usage: scripts/run_mutants.py [-j JOBS] [--report FILE] [--no-baseline] [name ...]
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

# | `m01_name` | bug | `testbench/unit/test_x.py::test_x[icarus-8]` | `a_name` or — |
ROW_RE = re.compile(
    r"^\| `(?P<name>m\d+_\w+)` \| (?P<bug>[^|]+) \| `(?P<node>[^`]+)` \| (?P<sva>[^|]+) \|$"
)


@dataclass(frozen=True)
class Mutant:
    name: str
    bug: str
    node: str  # pytest node id, relative to the repository root
    assertion: str | None  # required assertion name for SVA kills

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
            sva = m["sva"].strip().strip("`")
            mutants.append(
                Mutant(m["name"], m["bug"].strip(), m["node"], None if sva in ("—", "-") else sva)
            )
    return mutants


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


def cocotb_ran(wt: Path) -> bool:
    return bool(cocotb_results(wt))


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
        text = log.read_text(errors="replace")
        asserts = [ln.strip() for ln in text.splitlines() if "Assertion failed" in ln]
        detail = first_cocotb_failure(wt) or first_pytest_failure(
            wt / "sim_build" / "mutant_junit.xml"
        )
        if tests == 0:
            return Result(mutant, node, "ERROR", "test not collected (check the node id)", log)
        if not cocotb_ran(wt):
            return Result(mutant, node, "ERROR", f"no simulation ran: {detail}", log)
        if failed == 0:
            return Result(mutant, node, "SURVIVED" if mutant else "PASS", "test passed", log)
        if mutant is None:
            return Result(None, node, "FAIL", detail or "failed", log)
        if mutant.assertion:
            hit = [a for a in asserts if mutant.assertion in a]
            if not hit:
                first = asserts[0] if asserts else "no assertion fired"
                return Result(
                    mutant, node, "WRONG", f"{mutant.assertion} did not fire ({first})", log
                )
            return Result(mutant, node, "KILLED", f"{hit[0]} | first failing test: {detail}", log)
        return Result(mutant, node, "KILLED", detail or "failed", log)
    finally:
        remove_worktree(wt)


def write_report(path: Path, results: list[Result]) -> None:
    killed = sum(r.verdict == "KILLED" for r in results)
    lines = [
        "# Mutation results",
        "",
        "Generated by `scripts/run_mutants.py`. Each mutant (`testbench/mutants/*.patch`) is",
        "applied in a temporary git worktree and its killing test from",
        "`testbench/mutants/README.md` is run; every killing test also passes on the unmutated",
        "design (baseline).",
        "",
        f"**{killed} / {len(results)} mutants killed.**",
        "",
        "| Mutant | Verdict | Killing test | First failure |",
        "|---|---|---|---|",
    ]
    for r in results:
        assert r.mutant is not None
        detail = r.detail.replace("|", "\\|")
        lines.append(f"| `{r.mutant.name}` | {r.verdict} | `{r.node}` | {detail} |")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("names", nargs="*", help="mutant names or prefixes (default: all)")
    ap.add_argument("-j", "--jobs", type=int, default=3)
    ap.add_argument("--report", type=Path, help="write a Markdown report here")
    ap.add_argument("--no-baseline", action="store_true")
    args = ap.parse_args()

    mutants = parse_readme()
    listed = {m.name for m in mutants}
    patches = {p.stem for p in MUTANT_DIR.glob("*.patch")}
    if listed != patches:
        print(f"README and patches differ: {sorted(listed ^ patches)}", file=sys.stderr)
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
        write_report(args.report, results)
    return 0 if killed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
