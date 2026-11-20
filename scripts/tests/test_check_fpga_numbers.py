"""Tests for scripts/check_fpga_numbers.py: the committed docs match the committed reports; a stale
Fmax, slack or resource figure, a slack in an unrecognized form, or a missing figure fails; a
changed report fails the unchanged docs."""

from __future__ import annotations

import importlib.util
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("fn", ROOT / "scripts" / "check_fpga_numbers.py")
fn = importlib.util.module_from_spec(_spec)
sys.modules["fn"] = fn
_spec.loader.exec_module(fn)

REPORTS = ROOT / "fpga" / "de10lite" / "reports"
WANT = {
    "fmax": "65.85",
    "setup": "+4.813",
    "hold": "+0.095",
    "les": "8322",
    "les_pct": "17",
    "registers": "5587",
    "mem_bits": "340608",
    "mem_pct": "20",
    "mults": "68",
    "mults_total": "288",
}
GOOD = (
    "| Timing | 65.85 MHz Fmax; worst slack: +4.813 ns setup, +0.095 ns hold |\n"
    "| Resources | 8,322 LEs (17 %), 5,587 registers, 340,608 memory bits (20 %), "
    "68 9-bit multipliers |\n"
    "The design uses 8,322 logic elements (17 %), 68 of the 288 9-bit multipliers and 20 % of the\n"
    "memory bits; worst setup\nslack +4.813 ns, worst hold slack +0.095 ns. It runs at 50 MHz.\n"
)


def problems(text: str) -> list[str]:
    return fn.check_text("doc.md", text, WANT)


def test_committed_docs_match_committed_reports() -> None:
    want = fn.report_values(REPORTS)
    for doc in fn.DOCS:
        assert fn.check_text(doc.name, doc.read_text(), want) == []


def test_report_values() -> None:
    assert fn.report_values(REPORTS) == WANT


def test_matching_figures_pass() -> None:
    assert problems(GOOD) == []


@pytest.mark.parametrize(
    ("old", "new", "kind"),
    [
        ("65.85 MHz", "75.06 MHz", "fmax"),
        ("+4.813 ns setup", "+6.678 ns setup", "setup"),
        ("slack +4.813 ns", "slack +6.678 ns", "setup"),
        ("+0.095 ns hold", "+0.116 ns hold", "hold"),
        ("8,322 LEs", "8,324 LEs", "les"),
        ("8,322 logic elements", "8,324 logic elements", "les"),
        ("LEs (17 %)", "LEs (18 %)", "les_pct"),
        ("5,587 registers", "5,588 registers", "registers"),
        ("340,608 memory bits", "340,992 memory bits", "mem_bits"),
        ("20 % of the", "19 % of the", "mem_pct"),
        ("68 9-bit", "64 9-bit", "mults"),
        ("of the 288", "of the 280", "mults_total"),
    ],
)
def test_stale_figure_fails(old: str, new: str, kind: str) -> None:
    assert old in GOOD
    found = problems(GOOD.replace(old, new, 1))
    assert any(f": {kind} " in p for p in found), found


def test_unrecognized_slack_form_fails() -> None:
    found = problems(GOOD + "The margin is +4.813 ns.\n")
    assert any("not written as" in p for p in found)


def test_missing_figure_fails() -> None:
    text = GOOD.replace("65.85 MHz Fmax", "an Fmax well above the clock")
    assert "65.85" not in text
    assert "doc.md: states no fmax figure" in problems(text)


def test_changed_report_fails_unchanged_docs(tmp_path: Path) -> None:
    reports = tmp_path / "reports"
    shutil.copytree(REPORTS, reports)
    fmax = reports / "fmax.rpt"
    fmax.write_text(fmax.read_text().replace("65.85 MHz", "70.00 MHz"))
    corners = reports / "timing_corners.rpt"
    corners.write_text(corners.read_text().replace(";0.095", ";0.120"))
    want = fn.report_values(reports)
    assert (want["fmax"], want["hold"]) == ("70.00", "+0.120")
    found = fn.check_text("README.md", (ROOT / "README.md").read_text(), want)
    assert any(": fmax 65.85" in p for p in found)
    assert any(": hold +0.095" in p for p in found)
