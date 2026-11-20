"""Tests for scripts/check_quartus_warnings.py: expected warnings pass; a new warning, a critical
warning, an incomplete list or an entry without a reason fails; the committed build passes."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("qw", ROOT / "scripts" / "check_quartus_warnings.py")
qw = importlib.util.module_from_spec(_spec)
sys.modules["qw"] = qw  # dataclasses look the defining module up in sys.modules
_spec.loader.exec_module(qw)

EXPECTED = """\
# comment
13024 | Output pins are stuck at VCC or GND | parent of the pin lines
13410 | Pin "HEX[0-5]\\[7\\]" is stuck at VCC | decimal points off
14320 | Synthesized away node "a\\|b\\|ram_block1a(5[4-9]|6[0-3])" | reserved bits
"""
WARNINGS = """\
Warning (13024): Output pins are stuck at VCC or GND
Warning (13410): Pin "HEX0[7]" is stuck at VCC
Warning (13410): Pin "HEX5[7]" is stuck at VCC
Warning (14320): Synthesized away node "a|b|ram_block1a63"
"""
MESSAGES = """\
Info: Quartus Prime Timing Analyzer was successful. 0 errors, 0 warnings
Info: Quartus Prime Shell was successful. 0 errors, 4 warnings
Info: Quartus Prime Timing Analyzer was successful. 0 errors, 0 warnings
"""


def run(warnings: str = WARNINGS, expected: str = EXPECTED, messages: str = MESSAGES) -> list[str]:
    problems, _, _ = qw.check(warnings, expected, messages)
    return problems


def test_expected_warnings_pass() -> None:
    assert run() == []


def test_new_warning_fails() -> None:
    extra = WARNINGS + 'Warning (13410): Pin "LEDR[0]" is stuck at GND\n'
    problems = run(extra, messages=MESSAGES.replace("4 warnings", "5 warnings"))
    assert any("new warning (13410)" in p for p in problems)


def test_same_id_other_text_fails() -> None:
    changed = WARNINGS.replace("ram_block1a63", "ram_block1a53")
    assert any("new warning (14320)" in p for p in run(changed))


def test_critical_warning_fails() -> None:
    crit = WARNINGS + "Critical Warning (332012): Synopsys Design Constraints File not found\n"
    assert any(p.startswith("Critical Warning (332012)") for p in run(crit))


def test_incomplete_list_fails() -> None:
    problems = run(messages=MESSAGES.replace("4 warnings", "6 warnings"))
    assert any("Quartus reported 6" in p for p in problems)


def test_standalone_timing_run_counts() -> None:
    sta_warning = WARNINGS + 'Warning (13410): Pin "HEX1[7]" is stuck at VCC\n'
    messages = MESSAGES.rsplit("0 warnings", 1)[0] + "1 warning\n"
    assert run(sta_warning, messages=messages) == []


def test_entry_without_reason_fails() -> None:
    bad = EXPECTED + "15610 | No output dependent on input pin .* |\n"
    assert any("line 5" in p for p in run(expected=bad))


def test_committed_build_passes() -> None:
    reports = ROOT / "fpga" / "de10lite" / "reports"
    problems, entries, count = qw.check(
        (reports / "warnings.txt").read_text(),
        (ROOT / "fpga" / "de10lite" / "expected_warnings.txt").read_text(),
        (reports / "messages.txt").read_text(),
    )
    assert problems == [], problems
    assert count > 0 and entries
