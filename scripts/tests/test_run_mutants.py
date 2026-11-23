"""scripts/run_mutants.py: the mutant tables' required kill mechanism (assertion names or UVM
message IDs, any one of them) and how a simulator log is matched against it."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def _load_runner():
    spec = importlib.util.spec_from_file_location(
        "run_mutants", ROOT / "scripts" / "run_mutants.py"
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["run_mutants"] = mod
    spec.loader.exec_module(mod)
    return mod


R = _load_runner()
NODE = "testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]"

UVM_LOG = """\
UVM_INFO /x/src/accel_ref.svh(78) @ 0: reporter [REF] 54 reference images
[1230000] %Error: v.sv:31: Assertion failed in tb_top.aif.u_b_vr_sva.a_valid_held: 'assert'
UVM_ERROR /x/src/accel_scoreboard.svh(298) @ 1240000: uvm_test_top.env.sb [SB] IMG_SEL read 0
UVM_FATAL /x/src/accel_env.svh(64) @ 9990000: uvm_test_top.env [HANG] no AXI transaction completed
--- UVM Report Summary ---
UVM_ERROR :    1
UVM_FATAL :    1
[SB]     1
"""


def row(req: str) -> str:
    return f"| `m99_x` | a bug | `{NODE}` | {req} |"


def test_parse_none():
    (m,) = R.parse_readme(row("—"))
    assert m.requires == () and m.node == NODE


def test_parse_alternatives_and_uvm_ids():
    (m,) = R.parse_readme(row("`u_b_vr_sva.a_valid_held` or `u_r_vr_sva.a_valid_held`"))
    assert m.requires == ("u_b_vr_sva.a_valid_held", "u_r_vr_sva.a_valid_held")
    (m,) = R.parse_readme(row("`[HANG]`"))
    assert m.requires == ("[HANG]",)


def test_parse_rejects_other_tokens():
    with pytest.raises(ValueError):
        R.parse_readme(row("`HANG please`"))


def test_failure_lines_skip_the_summary():
    lines = R.failure_lines(UVM_LOG)
    assert len(lines) == 3
    assert "Assertion failed" in lines[0]
    assert "[SB]" in lines[1] and "[HANG]" in lines[2]


@pytest.mark.parametrize(
    "req,hit",
    [
        (("u_b_vr_sva.a_valid_held",), "Assertion failed"),
        (("a_valid_held",), "Assertion failed"),
        (("u_r_vr_sva.a_valid_held", "u_b_vr_sva.a_valid_held"), "Assertion failed"),
        (("[SB]",), "[SB]"),
        (("[HANG]",), "[HANG]"),
        (("[STATUS]",), None),
        (("u_r_vr_sva.a_valid_held",), None),
        (("valid_held",), None),  # a whole name, not a substring of one
    ],
)
def test_mechanism_hit(req, hit):
    got = R.mechanism_hit(req, R.failure_lines(UVM_LOG))
    assert (got is None) if hit is None else (hit in got)


def test_uvm_id_needs_error_or_fatal():
    info_only = "UVM_INFO /x/a.svh(1) @ 0: reporter [HANG] just a message\n"
    assert R.mechanism_hit(("[HANG]",), R.failure_lines(info_only)) is None


def test_strip_paths(tmp_path):
    line = f"UVM_ERROR {tmp_path}/testbench/uvm/src/a.svh(3) @ 1: x [SB] m"
    assert R.strip_paths(line, tmp_path) == "UVM_ERROR testbench/uvm/src/a.svh(3) @ 1: x [SB] m"


def test_every_uvm_row_names_a_mechanism():
    rows = R.parse_readme((ROOT / "testbench" / "uvm" / "mutants.md").read_text())
    assert rows and all(m.requires for m in rows), [m.name for m in rows if not m.requires]
