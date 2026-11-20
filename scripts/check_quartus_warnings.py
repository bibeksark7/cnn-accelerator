#!/usr/bin/env python3
"""Check the DE10-Lite build's Quartus warnings against the list of expected ones.

Reads fpga/de10lite/reports/warnings.txt (every warning of the compile and the timing analysis,
nested ones included; written by fpga/de10lite/build_win.sh) and
fpga/de10lite/expected_warnings.txt, whose entries are

    <message id> | <regular expression for the whole message text> | <reason>

Fails if a warning matches no entry, if there is any Critical Warning or Error, if an entry has
no reason, or if the number of warnings differs from the totals Quartus reports in
fpga/de10lite/reports/messages.txt (so the list is complete). Entries that match nothing are
listed but do not fail the check. The separator is " | " (space, bar, space); a regular expression
matches a hierarchy bar as "\\|", without spaces.

Usage: scripts/check_quartus_warnings.py [--reports DIR] [--expected FILE]
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FPGA = ROOT / "fpga" / "de10lite"
MESSAGE = re.compile(r"^(Critical Warning|Warning|Error) \((\d+)\): (.*)$")
TOTAL = re.compile(
    r"Quartus Prime (Shell|Timing Analyzer) was successful\. \d+ errors?, (\d+) warnings?"
)


@dataclass
class Entry:
    line: int
    msg_id: str
    pattern: re.Pattern[str]
    reason: str
    hits: int = 0


def parse_expected(text: str) -> tuple[list[Entry], list[str]]:
    entries, problems = [], []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(" | ", 2)]
        if len(parts) != 3 or not parts[0].isdigit():
            problems.append(f"expected_warnings line {n}: not '<id> | <regex> | <reason>'")
            continue
        if not parts[2]:
            problems.append(f"expected_warnings line {n}: no reason")
            continue
        try:
            entries.append(Entry(n, parts[0], re.compile(parts[1]), parts[2]))
        except re.error as e:
            problems.append(f"expected_warnings line {n}: bad regex ({e})")
    return entries, problems


def check(warnings: str, expected: str, messages: str) -> tuple[list[str], list[Entry], int]:
    entries, problems = parse_expected(expected)
    count = 0
    for raw in warnings.splitlines():
        if not raw.strip():
            continue
        m = MESSAGE.match(raw.strip())
        if not m:
            problems.append(f"unparsed line in warnings.txt: {raw.strip()}")
            continue
        kind, msg_id, text = m.groups()
        if kind != "Warning":
            problems.append(f"{kind} ({msg_id}): {text}")
            continue
        count += 1
        hit = next((e for e in entries if e.msg_id == msg_id and e.pattern.fullmatch(text)), None)
        if hit is None:
            problems.append(f"new warning ({msg_id}): {text}")
        else:
            hit.hits += 1
    # The compile's Shell total already includes the Timing Analyzer run inside the flow; the
    # separate timing run (sta_reports.tcl, logged last) adds its own Timing Analyzer total.
    shell = [int(m.group(2)) for m in TOTAL.finditer(messages) if m.group(1) == "Shell"]
    sta = [int(m.group(2)) for m in TOTAL.finditer(messages) if m.group(1) == "Timing Analyzer"]
    if len(shell) != 1:
        problems.append(f"messages.txt has {len(shell)} Quartus Shell totals, expected 1")
    else:
        reported = shell[0] + (sta[-1] if len(sta) >= 2 else 0)
        if reported != count:
            problems.append(f"warnings.txt has {count} warnings, Quartus reported {reported}")
    return problems, entries, count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--reports", type=Path, default=FPGA / "reports")
    ap.add_argument("--expected", type=Path, default=FPGA / "expected_warnings.txt")
    args = ap.parse_args()
    problems, entries, count = check(
        (args.reports / "warnings.txt").read_text(),
        args.expected.read_text(),
        (args.reports / "messages.txt").read_text(),
    )
    print(f"{count} Quartus warnings, {len(entries)} expected entries")
    for e in entries:
        if e.hits == 0:
            print(f"  note: expected entry on line {e.line} ({e.msg_id}) matched nothing")
    for p in problems:
        print(f"  {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
