#!/usr/bin/env python3
"""Write the README badges from the committed reports.

Between the markers <!-- badges:start --> and <!-- badges:end --> in README.md: the CI status
badge, a functional-coverage badge (testbench/reports/coverage.json) and a mutation badge
(testbench/reports/mutation.md). The coverage and mutation badges are static shields.io images
whose numbers come only from those reports.

Usage: scripts/readme_badges.py [--check]
  --check  exit 1 if README.md's badges differ from what the reports give (nothing is written)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
START, END = "<!-- badges:start -->", "<!-- badges:end -->"
CI = "https://github.com/bibeksark7/cnn-accelerator/actions/workflows/ci.yml"


def shield(label: str, message: str, color: str) -> str:
    esc = lambda s: quote(s.replace("-", "--").replace("_", "__"), safe="")  # noqa: E731
    return f"https://img.shields.io/badge/{esc(label)}-{esc(message)}-{color}"


def badges() -> str:
    cov = json.loads((ROOT / "testbench" / "reports" / "coverage.json").read_text())
    text = (ROOT / "testbench" / "reports" / "mutation.md").read_text()
    killed, total = map(int, re.search(r"\*\*(\d+) / (\d+) mutants killed", text).groups())
    cov_msg = f"{cov['met']}/{cov['bins']} bins, {cov['documented_gaps']} documented gaps"
    cov_color = "brightgreen" if cov["missed"] == 0 else "red"
    mut_color = "brightgreen" if killed == total else "red"
    return "\n".join(
        [
            START,
            f"[![CI]({CI}/badge.svg)]({CI})",
            f"[![functional coverage]({shield('functional coverage', cov_msg, cov_color)})]"
            "(testbench/reports/coverage.md)",
            f"[![mutants killed]({shield('mutants killed', f'{killed}/{total}', mut_color)})]"
            "(testbench/reports/mutation.md)",
            END,
        ]
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = README.read_text()
    m = re.search(re.escape(START) + r".*?" + re.escape(END), text, re.S)
    if not m:
        print("README.md has no badge markers", file=sys.stderr)
        return 1
    new = text[: m.start()] + badges() + text[m.end() :]
    if args.check:
        ok = new == text
        print("README badges match the reports" if ok else "README badges are stale")
        return 0 if ok else 1
    README.write_text(new)
    print("README badges updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
