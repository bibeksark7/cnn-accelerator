"""Fail unless a pytest JUnit XML report shows enough tests and no failures, errors or skips.

Usage: python scripts/check_junit.py <report.xml> [--min-tests N] [--allow-skips]

CI uses this so a pass is decided from the results file, not only the exit code.
"""

import argparse
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report")
    parser.add_argument("--min-tests", type=int, default=1)
    parser.add_argument("--allow-skips", action="store_true")
    args = parser.parse_args()

    root = ET.parse(args.report).getroot()
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    totals = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
    for suite in suites:
        for key in totals:
            totals[key] += int(suite.get(key, 0))

    print(
        f"{args.report}: {totals['tests']} tests, {totals['failures']} failures, "
        f"{totals['errors']} errors, {totals['skipped']} skipped"
    )
    if totals["tests"] < args.min_tests:
        print(f"FAIL: expected at least {args.min_tests} tests", file=sys.stderr)
        return 1
    if totals["failures"] or totals["errors"]:
        print("FAIL: failures or errors in report", file=sys.stderr)
        return 1
    if totals["skipped"] and not args.allow_skips:
        print("FAIL: skipped tests (pass --allow-skips if intended)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
