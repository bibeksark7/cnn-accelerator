"""Formal proofs with SymbiYosys (docs/decisions.md D-033).

Each `<module>.sby` has two tasks. `prove` proves the assertions in `<module>_props.sv` for all
inputs (unbounded: k-induction for the MAC cell, PDR for argmax and postproc); `cover` must reach
every cover statement (a witness trace exists). Every proof must PASS on the RTL, and must FAIL
on the named mutant from testbench/mutants/ with the named property, which shows the properties
constrain the behaviour they describe (not vacuous).

  mac_cell      accumulate exactly a*b, clear, hold, operand/valid forwarding (32-bit acc)
  argmax_unit   result is the first maximum of the window, done exactly count + 2 cycles after
                the start (VAL_W = 4, IDX_W = 3: 8 logits)
  postproc      the elastic pipeline's handshake: in order, no loss or duplication, at most
                four inside, ready when there is room, output stable under backpressure, a
                4-cycle latency and a full drain while i_ready stays high
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FORMAL_DIR = Path(__file__).resolve().parent
MUTANT_DIR = ROOT / "testbench" / "mutants"
WORK_DIR = ROOT / "sim_build" / "formal"

PROOFS = ["mac_cell", "argmax_unit", "postproc"]
MUTANTS = [  # (proof, mutant patch, property that must fail)
    ("mac_cell", "m31_mac_clear_ignored", "p_clear"),
    ("argmax_unit", "m16_argmax_tie_last", "p_lowest_tie"),
    ("argmax_unit", "m17_argmax_unsigned", "p_is_max"),
    ("postproc", "m24_postproc_ready_dropped", "p_stable"),
    ("argmax_unit", "m33_argmax_last_hangs", "p_done_on_time"),
    ("postproc", "m34_postproc_deadlock", "p_drains"),
]


def run_sby(sby: Path, workdir: Path, task: str = "prove") -> tuple[str, str]:
    """Run one task of a .sby; returns (status, log). status is PASS, FAIL or ERROR."""
    if workdir.exists():
        shutil.rmtree(workdir)
    proc = subprocess.run(
        ["sby", "-f", "-d", str(workdir), str(sby), task],
        cwd=sby.parent,
        capture_output=True,
        text=True,
        timeout=1800,
    )
    log = proc.stdout + proc.stderr
    m = re.search(r"DONE \((PASS|FAIL|ERROR|UNKNOWN|TIMEOUT)", log)
    return (m.group(1) if m else "ERROR"), log


@pytest.mark.parametrize("proof", PROOFS)
def test_proof(proof: str) -> None:
    status, log = run_sby(FORMAL_DIR / f"{proof}.sby", WORK_DIR / proof)
    assert status == "PASS", f"{proof}: {status}\n{log[-3000:]}"


@pytest.mark.parametrize("proof", PROOFS)
def test_cover(proof: str) -> None:
    status, log = run_sby(FORMAL_DIR / f"{proof}.sby", WORK_DIR / f"{proof}_cover", "cover")
    assert status == "PASS", f"{proof} cover: {status}\n{log[-3000:]}"
    reached = re.findall(r"Reached cover statement in step \d+ at \w+: (\w+)", log)
    assert reached, f"{proof} cover: no cover statement reported as reached\n{log[-2000:]}"


@pytest.mark.parametrize(("proof", "mutant", "prop"), MUTANTS)
def test_proof_fails_on_mutant(proof: str, mutant: str, prop: str, tmp_path: Path) -> None:
    """Copy the proof and its RTL file, apply the mutant patch to the copy, remove every assertion
    but `prop`, and expect FAIL on `prop`."""
    sby_text = (FORMAL_DIR / f"{proof}.sby").read_text()
    rtl_rel = next(line for line in sby_text.splitlines() if line.startswith("../../rtl/"))
    rtl_path = rtl_rel.removeprefix("../../")
    (tmp_path / Path(rtl_path).parent).mkdir(parents=True)
    shutil.copy(ROOT / rtl_path, tmp_path / rtl_path)
    subprocess.run(
        ["patch", "-p1", "-s", "-i", str(MUTANT_DIR / f"{mutant}.patch")],
        cwd=tmp_path,
        check=True,
    )
    shutil.copy(FORMAL_DIR / f"{proof}_props.sv", tmp_path)
    sby = tmp_path / f"{proof}.sby"
    # Keep only the named assertion: it alone must catch the mutant.
    prep = f"prep -top {proof}_props"
    keep_only = f"{prep}\nchformal -assert -remove t:$check c:{prop} %d"
    sby.write_text(sby_text.replace(rtl_rel, str(tmp_path / rtl_path)).replace(prep, keep_only))
    status, log = run_sby(sby, WORK_DIR / f"{proof}_{mutant}")
    assert status == "FAIL", f"{proof} with {mutant}: {status}, want FAIL\n{log[-3000:]}"
    failed = re.findall(r"Assert failed in \w+: (\w+)", log)
    assert prop in failed, f"{proof} with {mutant}: failed {sorted(set(failed))}, want {prop}"
