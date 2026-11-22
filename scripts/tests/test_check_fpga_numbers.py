"""Tests for scripts/check_fpga_numbers.py: the committed docs match the committed reports; a stale
Fmax, slack or resource figure, a slack in an unrecognized form, or a missing figure fails; a
changed report fails the unchanged docs; figures in a marked region are checked against that
region's build (the SoC), and malformed regions fail."""

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
SOC_REPORTS = ROOT / "fpga" / "de10lite_soc" / "reports"
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


def _want_for(build: str) -> dict[str, str]:
    return fn.report_values(REPORTS if not build else ROOT / "fpga" / build / "reports")


def test_committed_docs_match_committed_reports() -> None:
    for doc in fn.DOCS:
        assert fn.check_document(doc.name, doc.read_text(), _want_for) == []


def test_readme_states_soc_figures() -> None:
    spans, problems = fn.split_regions((ROOT / "README.md").read_text())
    assert problems == []
    assert "de10lite_soc" in spans


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


SOC_WANT = {
    "fmax": "69.04",
    "setup": "+5.515",
    "hold": "+0.090",
    "les": "12475",
    "les_pct": "25",
    "registers": "7297",
    "mem_bits": "867520",
    "mem_pct": "52",
    "mults": "76",
    "mults_total": "288",
}
SOC_GOOD = (
    "<!-- fpga-numbers: de10lite_soc -->\n"
    "| SoC timing | 69.04 MHz Fmax; +5.515 ns setup, +0.090 ns hold |\n"
    "| SoC resources | 12,475 LEs (25 %), 76 9-bit multipliers |\n"
    "<!-- fpga-numbers: end -->\n"
)


def doc_problems(text: str) -> list[str]:
    return fn.check_document("doc.md", text, lambda b: SOC_WANT if b == "de10lite_soc" else WANT)


def test_soc_report_values() -> None:
    assert fn.report_values(SOC_REPORTS) == SOC_WANT


def test_region_checked_against_its_build() -> None:
    assert doc_problems(GOOD + SOC_GOOD) == []
    assert doc_problems(SOC_GOOD + GOOD) == []


def test_m1_figure_in_soc_region_fails() -> None:
    found = doc_problems(GOOD + SOC_GOOD.replace("12,475 LEs", "8,322 LEs"))
    assert any("[de10lite_soc]" in p and ": les 8,322" in p for p in found), found


def test_soc_figure_outside_region_fails() -> None:
    found = doc_problems(GOOD + "The SoC runs at 69.04 MHz.\n" + SOC_GOOD)
    assert any(p.startswith("doc.md:") and ": fmax 69.04" in p for p in found), found


def test_line_numbers_are_the_documents() -> None:
    text = GOOD + SOC_GOOD.replace("+0.090 ns hold", "+0.247 ns hold")
    found = doc_problems(text)
    line = text.splitlines().index(next(ln for ln in text.splitlines() if "+0.247" in ln)) + 1
    assert found == [f"doc.md [de10lite_soc]:{line}: hold +0.247 != report +0.090"], found


def test_region_missing_figure_fails() -> None:
    found = doc_problems(GOOD + SOC_GOOD.replace("69.04 MHz Fmax", "an Fmax above 50 MHz"))
    assert "doc.md [de10lite_soc]: states no fmax figure" in found, found


@pytest.mark.parametrize(
    ("text", "msg"),
    [
        (GOOD + SOC_GOOD.replace("<!-- fpga-numbers: end -->\n", ""), "is not closed"),
        (GOOD + "<!-- fpga-numbers: end -->\n" + SOC_GOOD, "'end' marker outside a region"),
        (
            GOOD + SOC_GOOD.replace("| SoC resources", "<!-- fpga-numbers: other -->\n| x"),
            "inside region",
        ),
    ],
)
def test_malformed_region_fails(text: str, msg: str) -> None:
    assert any(msg in p for p in doc_problems(text))


def test_unknown_build_fails() -> None:
    def want_for(build: str) -> dict[str, str]:
        return fn.report_values(ROOT / "fpga" / build / "reports") if build else WANT

    found = fn.check_document("doc.md", GOOD + SOC_GOOD.replace("de10lite_soc", "nosuch"), want_for)
    assert any("no reports for build 'nosuch'" in p for p in found), found
