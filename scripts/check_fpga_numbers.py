#!/usr/bin/env python3
"""Check that the FPGA numbers quoted in the docs match the committed DE10-Lite build reports.

The reports (fpga/de10lite/reports/, written by fpga/de10lite/build_win.sh) give:
  Fmax          fmax.rpt (slow 85 C corner)
  setup, hold   the worst slack over every corner (timing_corners.rpt)
  resources     logic elements (and %), registers, memory bits (and %), 9-bit multipliers
                (de10lite.fit.summary)

Every figure of those kinds in each checked document must equal the report's value, and each
document must state the Fmax, the setup and hold slack, and the logic elements at least once, so a
reworded figure fails instead of escaping the check. Words may be separated by any whitespace,
line breaks included. Accepted forms (as the docs write them):
  65.85 MHz                         any decimal MHz figure is an Fmax
  +4.813 ns setup / setup slack +4.813 ns     (likewise hold); any other signed ns figure fails
  8,322 LEs / 8,322 logic elements, optionally followed by "(17 %)"
  5,587 registers;  340,608 memory bits (20 %);  20 % of the memory bits
  68 9-bit multipliers / 68 of the 288 9-bit multipliers

Usage: scripts/check_fpga_numbers.py [--reports DIR] [FILE ...]
  FILE defaults to README.md and docs/architecture.md.
Exit status: 0 if every figure matches, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "fpga" / "de10lite" / "reports"
DOCS = [ROOT / "README.md", ROOT / "docs" / "architecture.md"]
REQUIRED = ("fmax", "setup", "hold", "les")

SIGNED_NS = re.compile(r"([+\-\u2212]\d+\.\d+)\s+ns")
SLACK_AFTER = re.compile(r"([+\-\u2212]\d+\.\d+)\s+ns\s+(setup|hold)\b")
SLACK_BEFORE = re.compile(r"\b(setup|hold)\s+slack\s+([+\-\u2212]\d+\.\d+)\s+ns")
PATTERNS = {
    "fmax": [re.compile(r"\b(\d+\.\d+)\s+MHz")],
    "les": [re.compile(r"\b(\d[\d,]*)\s+(?:LEs|logic\s+elements)\b")],
    "les_pct": [re.compile(r"\b\d[\d,]*\s+(?:LEs|logic\s+elements)\s+\((\d+)\s?%\)")],
    "registers": [re.compile(r"\b(\d[\d,]*)\s+registers\b")],
    "mem_bits": [re.compile(r"\b(\d[\d,]*)\s+memory\s+bits\b")],
    "mem_pct": [
        re.compile(r"\bmemory\s+bits\s+\((\d+)\s?%\)"),
        re.compile(r"\b(\d+)\s?%\s+of\s+the\s+memory\s+bits\b"),
    ],
    "mults": [re.compile(r"\b(\d+)(?:\s+of\s+the\s+\d+)?\s+9-bit\s+multipliers\b")],
    "mults_total": [re.compile(r"\b\d+\s+of\s+the\s+(\d+)\s+9-bit\s+multipliers\b")],
}


def _num(s: str) -> str:
    """A figure as written, normalized: no thousands separators, ASCII minus."""
    return s.replace(",", "").replace("\u2212", "-")


def report_values(reports: Path) -> dict[str, str]:
    fmax = re.search(r";\s*([\d.]+) MHz\s*;", (reports / "fmax.rpt").read_text())
    rows = [
        line.split(";")
        for line in (reports / "timing_corners.rpt").read_text().splitlines()
        if line and not line.startswith(("#", "corner;"))
    ]
    fit = (reports / "de10lite.fit.summary").read_text()

    def fit_field(name: str) -> re.Match[str]:
        m = re.search(
            rf"^\s*{re.escape(name)} : ([\d,]+)(?: / ([\d,]+) \(\s*(\d+) %\s*\))?", fit, re.M
        )
        if not m:
            raise ValueError(f"de10lite.fit.summary has no '{name}' line")
        return m

    if not fmax or not rows:
        raise ValueError("fmax.rpt or timing_corners.rpt has no figures")
    les, mem, mult = (
        fit_field("Total logic elements"),
        fit_field("Total memory bits"),
        fit_field("Embedded Multiplier 9-bit elements"),
    )
    return {
        "fmax": fmax.group(1),
        "setup": f"{min(float(r[1]) for r in rows):+.3f}",
        "hold": f"{min(float(r[2]) for r in rows):+.3f}",
        "les": _num(les.group(1)),
        "les_pct": les.group(3),
        "registers": _num(fit_field("Total registers").group(1)),
        "mem_bits": _num(mem.group(1)),
        "mem_pct": mem.group(3),
        "mults": _num(mult.group(1)),
        "mults_total": _num(mult.group(2)),
    }


def check_text(name: str, text: str, want: dict[str, str]) -> list[str]:
    """Problems with the FPGA figures in one document (empty if all match)."""
    problems: list[str] = []
    seen: set[str] = set()

    def compare(kind: str, got: str, where: int) -> None:
        seen.add(kind)
        if _num(got) != want[kind]:
            line = text.count("\n", 0, where) + 1
            problems.append(f"{name}:{line}: {kind} {got} != report {want[kind]}")

    for kind, pats in PATTERNS.items():
        for pat in pats:
            for m in pat.finditer(text):
                compare(kind, m.group(1), m.start())
    classified: set[int] = set()
    for m in SLACK_AFTER.finditer(text):
        compare(m.group(2), m.group(1), m.start())
        classified.add(m.start(1))
    for m in SLACK_BEFORE.finditer(text):
        compare(m.group(1), m.group(2), m.start())
        classified.add(m.start(2))
    for m in SIGNED_NS.finditer(text):
        if m.start(1) not in classified:
            line = text.count("\n", 0, m.start()) + 1
            problems.append(
                f"{name}:{line}: slack figure {m.group(1)} ns not written as "
                "'<v> ns setup|hold' or 'setup|hold slack <v> ns'"
            )
    problems += [f"{name}: states no {kind} figure" for kind in REQUIRED if kind not in seen]
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--reports", type=Path, default=REPORTS)
    ap.add_argument("files", nargs="*", type=Path, default=DOCS)
    args = ap.parse_args()
    want = report_values(args.reports)
    problems: list[str] = []
    for f in args.files:
        name = f.resolve().relative_to(ROOT) if f.resolve().is_relative_to(ROOT) else f
        problems += check_text(str(name), f.read_text(), want)
    print(
        f"reports: Fmax {want['fmax']} MHz, setup {want['setup']} ns, hold {want['hold']} ns, "
        f"{want['les']} LEs ({want['les_pct']} %), {want['registers']} registers, "
        f"{want['mem_bits']} memory bits ({want['mem_pct']} %), {want['mults']} multipliers; "
        f"{len(args.files)} documents checked, {len(problems)} mismatches"
    )
    for p in problems:
        print("  ", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
