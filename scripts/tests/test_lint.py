"""scripts/lint.sh rejects known-bad RTL (fixtures) and accepts the committed RTL."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def lint(*files: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(ROOT / "scripts" / "lint.sh"), *map(str, files)],
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.parametrize(
    ("fixture", "stage"),
    [
        ("bare_generate.sv", "quartus compat"),
        ("icarus_sorry.sv", "iverilog output"),
        ("twocells.sv", "FAIL"),  # Verilator MULTIDRIVEN or Yosys conflicting drivers
        ("combloop.sv", "FAIL"),  # Verilator UNOPTFLAT or Yosys logic loop
        ("undriven.sv", "FAIL"),  # Verilator UNDRIVEN or Yosys undriven wire
    ],
)
def test_lint_rejects_fixture(fixture: str, stage: str):
    result = lint(FIXTURES / fixture)
    assert result.returncode != 0, result.stdout
    assert stage in result.stdout, result.stdout


def test_lint_accepts_committed_rtl():
    result = lint()
    assert result.returncode == 0, result.stdout
