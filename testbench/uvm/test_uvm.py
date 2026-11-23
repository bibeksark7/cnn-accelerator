"""UVM testbench for the accelerator's AXI4-Lite slave (accel_axil_slave + accel_top, spec §13.4)
on Verilator with uvm-core (IEEE 1800.2-2020 reference library, third_party/uvm-core).

The bench (testbench/uvm/src, testbench/uvm/tb) is built once per session; each UVM test is then a
pytest case, run with its own seed. A test passes only if the simulator exits 0, the UVM report
summary shows no UVM_ERROR and no UVM_FATAL, and the test printed its own "TEST PASSED" line
(which also requires the scoreboard to have checked a minimum amount; see accel_tests.svh).

  test_uvm[<test>]     one UVM test (accel_tests.svh)
  test_uvm_violation   a master that breaks the AXI4-Lite rules on purpose: the run must fail,
                       and the first "Assertion failed" line must name a_awvalid_held
  test_uvm_coverage    merges the functional coverage of every test run in this session and
                       writes the report (scripts/uvm_coverage.py checks the goals)

Expected results come from Python: the quick subset and the saturating images (model/artifacts),
with their golden logits and classes, exported to hex files (export_ref); the network's buffer
contents are the committed model/artifacts/mem files. Nothing is trained or downloaded.

Environment: UVM_SEED overrides every test's seed; BUILD_JOBS sets the C++ build parallelism
(default 2: measured, a from-scratch UVM build adds about 4.8 GB of memory in use at -j 2,
with the largest compiler process at 2.6 GB).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
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
        UVM_TB / "tb" / "axil_if.sv",
        UVM_TB / "tb" / "accel_status_if.sv",
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


def run_uvm(binary: Path, test: str, seed: int, *plusargs: str) -> tuple[int, str, Path]:
    COV_DIR.mkdir(parents=True, exist_ok=True)
    log = BUILD / f"{test}.log"
    cov = COV_DIR / f"{test}.dat"
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


def summary_count(text: str, severity: str) -> int | None:
    m = re.search(rf"^{severity} :\s+(\d+)$", text, re.MULTILINE)
    return int(m.group(1)) if m else None


def check_passed(test: str, rc: int, text: str, log: Path) -> None:
    errors, fatals = summary_count(text, "UVM_ERROR"), summary_count(text, "UVM_FATAL")
    warnings = summary_count(text, "UVM_WARNING")
    lines = [ln for ln in text.splitlines() if re.search(r"UVM_(ERROR|FATAL|WARNING) |%Error", ln)]
    lines = lines[:10]
    assert rc == 0, f"{test}: simulator exit {rc} ({log}):\n" + "\n".join(lines)
    assert errors == 0 and fatals == 0, (
        f"{test}: UVM_ERROR {errors}, UVM_FATAL {fatals} ({log}):\n" + "\n".join(lines)
    )
    assert warnings == 0, f"{test}: {warnings} UVM_WARNING ({log}):\n" + "\n".join(lines)
    assert f"TEST PASSED: {test}" in text, f"{test}: no TEST PASSED line ({log})"
    sb = re.search(r"\[SB\] (\d+ transactions.*)$", text, re.MULTILINE)
    if sb:
        print(f"{test}: {sb.group(1)}")


@pytest.mark.parametrize("test", list(TESTS))
def test_uvm(uvm_bin: Path, test: str) -> None:
    rc, text, log = run_uvm(uvm_bin, test, seed_for(test))
    check_passed(test, rc, text, log)


def test_uvm_violation(uvm_bin: Path) -> None:
    rc, text, log = run_uvm(uvm_bin, "accel_violation_test", seed_for("accel_violation_test"))
    fired = re.findall(r"Assertion failed in ([\w.]+)", text)
    assert rc != 0, f"the protocol violation went unnoticed ({log})"
    assert fired, f"the run failed, but not through an assertion ({log})"
    assert fired[0].endswith("a_awvalid_held"), f"first assertion to fire: {fired[0]} ({log})"
    assert "withdrawing AWVALID" in text, f"the driver never broke the rule ({log})"


def test_uvm_coverage(uvm_bin: Path) -> None:
    """Merged coverage of this session's test runs (each must be newer than the binary)."""
    files = [COV_DIR / f"{t}.dat" for t in TESTS]
    stale = [f.name for f in files if not f.exists() or f.stat().st_mtime < uvm_bin.stat().st_mtime]
    assert not stale, f"run every test_uvm case first; missing or stale: {stale}"
    bins = uvm_coverage.merge(files)
    report = uvm_coverage.report(bins, [f.stem for f in files])
    (BUILD / "uvm_coverage.md").write_text(report.text)
    print(report.summary)
    assert report.ok, report.summary
