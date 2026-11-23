"""UVM testbench for the accelerator's AXI4-Lite slave (accel_axil_slave + accel_top, spec §13.4)
on Verilator with uvm-core (IEEE 1800.2-2020 reference library, third_party/uvm-core).

The bench (testbench/uvm/src, testbench/uvm/tb) is built once per session; each UVM test is then a
pytest case, run with its own seed. A test passes only if the simulator exits 0, the UVM report
summary shows no UVM_ERROR, no UVM_FATAL and no UVM_WARNING, and the test printed its own
"TEST PASSED" line (which also requires the scoreboard to have checked a minimum amount; see
accel_tests.svh).

  test_uvm[<test>]          one UVM test (accel_tests.svh), with its fixed default seed
  test_uvm[<test>-s<seed>]  the same with a random seed (UVM_SEEDS > 0: the nightly seed sweep)
  test_uvm_violation[<ch>]  a master that breaks the AXI4-Lite rules on purpose (channel AW, W or
                            AR): the run must fail, and the first "Assertion failed" line must
                            name that channel's valid/ready check (axil_if_bind.sv)
  test_uvm_coverage         merges the functional coverage of every test_uvm run of this session
                            and writes the coverage report (scripts/uvm_coverage.py checks the
                            goals) and the per-run check counts (uvm_checks.md); in a sweep, one
                            report of both (uvm_seed_sweep.md)

Expected results come from Python: the quick subset and the saturating images (model/artifacts),
with their golden logits and classes, exported to hex files (export_ref); the network's buffer
contents are the committed model/artifacts/mem files. Nothing is trained or downloaded.

Environment:
  UVM_SEED       overrides every test's seed (replays a failing seed of the sweep)
  UVM_SEEDS      N > 0: run every test with N random seeds instead of its default seed; the seeds
                 come from UVM_SEED_BASE (default: a fresh random number, printed in each test's
                 output) and each appears in the test's name
  BUILD_JOBS     the C++ build parallelism (default 2: measured, a from-scratch UVM build adds
                 about 4.8 GB of memory in use at -j 2, with the largest compiler process at 2.6 GB)
"""

from __future__ import annotations

import os
import random
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pytest

from common.runner import REPO_ROOT, RTL_DIR, SIM_BUILD_DIR

UVM_TB = Path(__file__).resolve().parent
UVM_CORE = REPO_ROOT / "third_party" / "uvm-core" / "src"
ARTIFACTS = REPO_ROOT / "model" / "artifacts"
MEM_DIR = ARTIFACTS / "mem"
BUILD = SIM_BUILD_DIR / "uvm"
BINARY = BUILD / "obj" / "Vtb_top"
REF_DIR = BUILD / "ref"
COV_DIR = BUILD / "coverage"

# UVM test -> default seed (logged; UVM_SEED overrides).
TESTS = {
    "accel_reg_test": 101,
    "accel_bus_test": 202,
    "accel_infer_test": 303,
    "accel_poll_test": 404,
    "accel_error_test": 505,
    "accel_reset_test": 606,
    "accel_random_test": 707,
}
RUN_TIMEOUT_S = 900  # wall clock per test: a hang guard, not an expected time
SWEEP = int(os.environ.get("UVM_SEEDS", "0"))
SWEEP_BASE = int(os.environ.get("UVM_SEED_BASE") or random.SystemRandom().randrange(1, 2**31))
# Violation variants: channel -> the assertion that must fire first (axil_if_bind.sv).
VIOLATIONS = {
    "AW": ("u_aw_vr_sva.a_valid_held", "withdrawing AWVALID"),
    "W": ("u_w_vr_sva.a_valid_held", "withdrawing WVALID"),
    "AR": ("u_ar_vr_sva.a_valid_held", "withdrawing ARVALID"),
}

sys.path.insert(0, str(REPO_ROOT / "scripts"))
import uvm_coverage  # noqa: E402  (scripts/uvm_coverage.py)


def export_ref(out: Path) -> int:
    """Reference images, logits and classes as hex files; returns the number of images."""
    out.mkdir(parents=True, exist_ok=True)
    sets = [np.load(ARTIFACTS / f) for f in ("quick_subset.npz", "saturation_subset.npz")]
    q = np.concatenate([s["q"].reshape(len(s["q"]), -1) for s in sets]).astype(np.int8)
    logits = np.concatenate([s["logits"] for s in sets]).astype(np.int64)
    pred = np.concatenate([s["pred"] for s in sets]).astype(np.int64)
    (out / "images.hex").write_text("".join(f"{b:02x}\n" for b in q.view(np.uint8).ravel()))
    (out / "logits.hex").write_text("".join(f"{v & 0xFFFF_FFFF:08x}\n" for v in logits.ravel()))
    (out / "pred.hex").write_text("".join(f"{v:02x}\n" for v in pred))
    (out / "count.txt").write_text(f"{len(q):x}\n")
    return len(q)


def sources() -> list[Path]:
    return [
        REPO_ROOT / "third_party" / "uvm-core.vlt",
        UVM_TB / "uvm_bench.vlt",
        UVM_CORE / "uvm_pkg.sv",
        UVM_TB / "uvm_dpi.cc",
        *sorted(RTL_DIR.rglob("*.sv")),
        REPO_ROOT / "testbench" / "hdl" / "accel_axil_tb.sv",
        REPO_ROOT / "testbench" / "sva" / "valid_ready_sva.sv",
        REPO_ROOT / "testbench" / "sva" / "axil_resp_order_sva.sv",
        UVM_TB / "tb" / "axil_if.sv",
        UVM_TB / "tb" / "axil_if_bind.sv",
        UVM_TB / "tb" / "accel_status_if.sv",
        UVM_TB / "tb" / "accel_backdoor_if.sv",
        UVM_TB / "src" / "axil_pkg.sv",
        UVM_TB / "src" / "accel_pkg.sv",
        UVM_TB / "tb" / "tb_top.sv",
    ]


def build() -> Path:
    """Verilate and compile the bench (incremental: unchanged inputs rebuild nothing)."""
    jobs = os.environ.get("BUILD_JOBS", "2")
    cmd = [
        "verilator",
        "--binary",
        "--timing",
        "--assert",
        "--coverage-user",
        "--vpi",
        "-j",
        jobs,
        "--timescale",
        "1ns/1ps",
        "--top-module",
        "tb_top",
        "--Mdir",
        str(BINARY.parent),
        "-o",
        BINARY.name,
        "+define+UVM_HDL_NO_DPI",
        f"+incdir+{UVM_CORE}",
        f"+incdir+{UVM_TB / 'src'}",
        "-CFLAGS",
        f"-I{UVM_CORE / 'dpi'}",
        *map(str, sources()),
    ]
    BUILD.mkdir(parents=True, exist_ok=True)
    log = BUILD / "build.log"
    t0 = time.monotonic()
    with log.open("w") as f:
        f.write(" ".join(cmd) + "\n")
        f.flush()
        rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=BUILD).returncode
    text = log.read_text()
    assert rc == 0, f"UVM bench build failed (exit {rc}); see {log}:\n{text[-3000:]}"
    print(f"UVM bench built in {time.monotonic() - t0:.0f} s (-j {jobs}): {BINARY}")
    return BINARY


@pytest.fixture(scope="module")
def uvm_bin() -> Path:
    export_ref(REF_DIR)
    return build()


def seed_for(test: str) -> int:
    return int(os.environ.get("UVM_SEED", TESTS.get(test, 1)))


def cases() -> list:
    """(test, seed) per test_uvm case: the default seeds, or UVM_SEEDS random seeds per test."""
    if SWEEP <= 0:
        return [pytest.param(t, seed_for(t), id=t) for t in TESTS]
    rng = random.Random(SWEEP_BASE)
    seeds = {t: [rng.randrange(1, 2**31) for _ in range(SWEEP)] for t in TESTS}
    return [pytest.param(t, s, id=f"{t}-s{s}") for t in TESTS for s in seeds[t]]


CASES = cases()


@dataclass
class Run:
    test: str
    seed: int
    cov: Path
    stats: dict[str, int]


RUNS: dict[tuple[str, int], Run] = {}  # test_uvm runs of this session

# The scoreboard's summary line (accel_scoreboard.svh, report_phase).
SB_RE = re.compile(
    r"\[SB\] (?P<txn>\d+) transactions, (?P<resp>\d+) responses checked; reads: (?P<checked>\d+) "
    r"checked, (?P<unpred>\d+) not predictable; runs: (?P<started>\d+) started, (?P<ended>\d+) "
    r"ended, (?P<golden>\d+) against the golden model \((?P<logits>\d+) logits compared\); "
    r"counter bounds: (?P<bounds>\d+) checked; (?P<mismatch>\d+) mismatches"
)


def run_uvm(
    binary: Path, test: str, seed: int, *plusargs: str, tag: str = ""
) -> tuple[int, str, Path]:
    COV_DIR.mkdir(parents=True, exist_ok=True)
    name = test + (f".{tag}" if tag else "")
    log = BUILD / f"{name}.log"
    cov = COV_DIR / f"{name}.dat"
    cov.unlink(missing_ok=True)
    cmd = [
        str(binary),
        f"+UVM_TESTNAME={test}",
        f"+REF_DIR={REF_DIR}",
        f"+MEM_DIR={MEM_DIR}",
        f"+verilator+seed+{seed}",
        f"+verilator+coverage+file+{cov}",
        "+UVM_NO_RELNOTES",
        *plusargs,
    ]
    t0 = time.monotonic()
    with log.open("w") as f:
        f.write(" ".join(cmd) + "\n")
        f.flush()
        rc = subprocess.run(
            cmd, stdout=f, stderr=subprocess.STDOUT, cwd=BUILD, timeout=RUN_TIMEOUT_S
        ).returncode
    print(f"{test}: seed {seed}, exit {rc}, {time.monotonic() - t0:.1f} s, log {log}")
    return rc, log.read_text(), log


def replay(test: str, seed: int) -> str:
    return f"replay: UVM_SEED={seed} pytest 'testbench/uvm/test_uvm.py::test_uvm[{test}]'"


def summary_count(text: str, severity: str) -> int | None:
    m = re.search(rf"^{severity} :\s+(\d+)$", text, re.MULTILINE)
    return int(m.group(1)) if m else None


def check_passed(test: str, seed: int, rc: int, text: str, log: Path) -> dict[str, int]:
    """Assert the run passed; return the scoreboard's counts."""
    errors, fatals = summary_count(text, "UVM_ERROR"), summary_count(text, "UVM_FATAL")
    warnings = summary_count(text, "UVM_WARNING")
    lines = [ln for ln in text.splitlines() if re.search(r"UVM_(ERROR|FATAL|WARNING) |%Error", ln)]
    lines = lines[:10]
    head = f"{test}, seed {seed} ({replay(test, seed)})"
    assert rc == 0, f"{head}: simulator exit {rc} ({log}):\n" + "\n".join(lines)
    assert errors == 0 and fatals == 0, (
        f"{head}: UVM_ERROR {errors}, UVM_FATAL {fatals} ({log}):\n" + "\n".join(lines)
    )
    assert warnings == 0, f"{head}: {warnings} UVM_WARNING ({log}):\n" + "\n".join(lines)
    assert f"TEST PASSED: {test}" in text, f"{head}: no TEST PASSED line ({log})"
    sb = SB_RE.search(text)
    assert sb, f"{head}: no scoreboard summary line ({log})"
    print(f"{test}: {sb.group(0)}")
    return {k: int(v) for k, v in sb.groupdict().items()}


@pytest.mark.parametrize("test,seed", CASES)
def test_uvm(uvm_bin: Path, test: str, seed: int) -> None:
    tag = f"s{seed}" if SWEEP > 0 else ""
    if SWEEP > 0:
        print(f"seed sweep: {SWEEP} seeds per test from UVM_SEED_BASE={SWEEP_BASE}")
    rc, text, log = run_uvm(uvm_bin, test, seed, tag=tag)
    stats = check_passed(test, seed, rc, text, log)
    RUNS[(test, seed)] = Run(test, seed, COV_DIR / f"{log.stem}.dat", stats)


@pytest.mark.parametrize("channel", list(VIOLATIONS))
def test_uvm_violation(uvm_bin: Path, channel: str) -> None:
    want, said = VIOLATIONS[channel]
    rc, text, log = run_uvm(
        uvm_bin, "accel_violation_test", seed_for("accel_violation_test"),
        f"+VIOLATION={channel}", tag=channel,
    )  # fmt: skip
    fired = re.findall(r"Assertion failed in ([\w.]+)", text)
    assert rc != 0, f"the protocol violation went unnoticed ({log})"
    assert fired, f"the run failed, but not through an assertion ({log})"
    assert fired[0].endswith(want), f"first assertion to fire: {fired[0]}, not {want} ({log})"
    assert said in text, f"the driver never broke the rule ({log})"


def checks_report(runs: list[Run], seeds: str) -> str:
    """What the scoreboard checked in each run (its summary line), as a Markdown table."""
    cols = [
        ("txn", "Transactions"),
        ("resp", "Responses checked"),
        ("checked", "Reads checked"),
        ("unpred", "Reads not predictable"),
        ("started", "Runs"),
        ("golden", "Golden runs"),
        ("logits", "Logits compared"),
        ("bounds", "Counter bounds"),
        ("mismatch", "Mismatches"),
    ]
    clean = uvm_coverage.git("status", "--porcelain", "--untracked-files=no") == ""
    head = uvm_coverage.git("rev-parse", "HEAD")
    lines = [
        "# UVM scoreboard checks",
        "",
        "Generated by `testbench/uvm/test_uvm.py` from each test's scoreboard summary "
        "(`accel_scoreboard.svh`, report_phase). Every response is checked. A read is checked "
        "when its value is determined by what the bench has done (the register model, the "
        "buffer words it wrote, the golden results); it is not predictable when it depends on "
        "state the bench does not model (a buffer word never written or overwritten by a run, a "
        "register read while a run may have ended or started during the access, the counters "
        "and LAYER_CYC during a run beyond never decreasing).",
        "",
        f"- Seeds: {seeds}",
        f"- Commit: `{head}` (tree {'clean' if clean else 'DIRTY'})",
        "",
        "| Test | Seed | " + " | ".join(c[1] for c in cols) + " |",
        "|---|---|" + "---|" * len(cols),
    ]
    for r in runs:
        lines.append(
            f"| `{r.test}` | {r.seed} | " + " | ".join(f"{r.stats[k]:,}" for k, _ in cols) + " |"
        )
    tot = {k: sum(r.stats[k] for r in runs) for k, _ in cols}
    lines.append("| **all** | | " + " | ".join(f"**{tot[k]:,}**" for k, _ in cols) + " |")
    return "\n".join(lines) + "\n"


def test_uvm_coverage(uvm_bin: Path) -> None:
    """Merged coverage of every test_uvm run of this session (the default seeds, or the sweep)."""
    want = [(p.values[0], p.values[1]) for p in CASES]
    missing = [f"{t}@{s}" for t, s in want if (t, s) not in RUNS or not RUNS[(t, s)].cov.exists()]
    assert not missing, f"run every test_uvm case first (this session); missing: {missing}"
    runs = [RUNS[k] for k in want]
    if SWEEP > 0:
        seeds = f"{SWEEP} random seeds per test (UVM_SEED_BASE={SWEEP_BASE}), {len(runs)} runs"
    else:
        seeds = "one per test, the fixed default seeds: " + ", ".join(
            f"{r.test} {r.seed}" for r in runs
        )
    bins = uvm_coverage.merge([r.cov for r in runs])
    report = uvm_coverage.report(bins, list(TESTS), seeds)
    checks = checks_report(runs, seeds)
    if SWEEP > 0:  # one report: the coverage merged over the sweep, then every run's checks
        text = report.text.replace("# UVM functional coverage", "# UVM seed sweep", 1)
        text += "\n## Scoreboard checks per run\n" + checks.split("\n", 1)[1]
        (BUILD / "uvm_seed_sweep.md").write_text(text)
    else:
        (BUILD / "uvm_coverage.md").write_text(report.text)
        (BUILD / "uvm_checks.md").write_text(checks)
    print(report.summary)
    assert report.ok, report.summary
