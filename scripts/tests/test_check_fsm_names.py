"""scripts/check_fsm_names.py: testbench FSM name lists match the RTL enums."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_fsm_names.py"
_spec = importlib.util.spec_from_file_location("check_fsm_names", SCRIPT)
cfn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cfn)

SV = """
  typedef enum logic [1:0] {
    S_IDLE,   // waiting
    S_RUN,
    /* block comment */ S_DONE
  } state_t;
"""


def test_repository_lists_match():
    result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout


def test_match():
    assert cfn.check(SV, "state_t", "S_", "NAMES = ['IDLE', 'RUN', 'DONE']", "NAMES") is None


@pytest.mark.parametrize(
    "names",
    [["IDLE", "DONE", "RUN"], ["IDLE", "RUN"], ["IDLE", "RUN", "DONE", "EXTRA"]],
    ids=["reordered", "missing", "extra"],
)
def test_mismatch(names):
    assert cfn.check(SV, "state_t", "S_", f"NAMES = {names!r}", "NAMES")


def test_explicit_values_rejected():
    sv = "typedef enum logic [1:0] { S_A = 2'd1, S_B } state_t;"
    with pytest.raises(ValueError, match="explicit"):
        cfn.check(sv, "state_t", "S_", "NAMES = ['A', 'B']", "NAMES")
