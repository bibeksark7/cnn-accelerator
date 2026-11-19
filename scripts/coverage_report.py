#!/usr/bin/env python3
"""Functional coverage report: merge the tests' coverage.json files and check the goals.

Every cocotb simulation that records coverage (testbench/common/coverage.py) leaves a
coverage.json in its build directory, sim_build/<build>/. This script merges them per scope (the
simulation's toplevel, over all simulators and parameter sets), compares every bin with its goal
below, and writes testbench/reports/coverage.{md,json}.

A bin is
  met       hits >= goal
  GAP       below goal, with a documented reason in GAPS (reported, does not fail)
  MISSED    below goal without a documented reason (fails)
A documented gap that is hit anyway also fails, so GAPS never goes stale.

Usage: scripts/coverage_report.py [--run] [--check]
  --run    delete old coverage files, run pytest testbench/unit testbench/system, then report
  --check  only check (exit status), do not write the report files
Exit status: 0 if no bin is MISSED and no documented gap is stale, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM_BUILD = ROOT / "sim_build"
REPORT_MD = ROOT / "testbench" / "reports" / "coverage.md"
REPORT_JSON = ROOT / "testbench" / "reports" / "coverage.json"
EXCLUDE = ("sva_violation", "full_run")  # deliberate-failure builds; scripts/full_run.py

HANDSHAKE = ["transfer", "stall (valid, not ready)"]

# scope -> point -> bins (goal: 1 hit each). Written from docs/verification_plan.md §5.
GOALS: dict[str, dict[str, list[str]]] = {
    "gemm_engine": {
        "layer type": ["CONV", "FC"],
        "ReLU": ["on", "off"],
        "row tiles (M)": ["last tile full", "last tile partial"],
        "column tiles (Ncols)": ["last tile full", "last tile partial"],
        "column tile count": ["1", "more than 1"],
        "K": ["K = 1", "1 < K <= K_TILE", "K > K_TILE"],
        "K chunks": ["1", "more than 1"],
        "layers without work": ["C_out = 0", "M = 0 or K = 0"],
        "array rows -> row register": HANDSHAKE,
        "row register -> postproc": HANDSHAKE,
        "postproc -> write port": HANDSHAKE,
    },
    "postproc": {
        "mode": ["requantize", "FC bypass"],
        "saturation": ["high", "low", "in range"],
        "rounding": ["exact tie, positive", "exact tie, negative"],
        "ReLU": ["clamped", "passed"],
        "input handshake": HANDSHAKE,
        "output handshake": HANDSHAKE,
    },
    "systolic_array": {
        "K": ["0 (drain only)", "1", "2 .. N-1", "N", "N+1 .. 127", "128 (K_TILE)"],
        "steps": ["with gaps", "back to back"],
        "result rows": HANDSHAKE,
    },
    "pool_unit": {
        "shape": ["even H and W", "odd H or W (floor)", "no output (H < 2, W < 2 or C = 0)"],
        "channels": ["C = 1", "C > 1"],
        "values": ["negative window maximum", "int8 extreme maximum"],
    },
    "argmax_unit": {
        "count": ["0", "1", "more than 1"],
        "maximum": ["tie (lowest index wins)", "negative"],
        "values": ["int32 extreme"],
        "position of the maximum": ["last", "not last"],
    },
    "layer_seq": {
        "unit started": ["gemm", "pool", "argmax"],
        "descriptor errors": [
            "reserved op",
            "dst = IMG",
            "dst = LOGIT",
            "src = dst",
            "src = LOGIT",
            "FC with dst != LOGIT",
            "ARGMAX with src != LOGIT",
            "missing last",
        ],
        "START": ["ignored: busy", "ignored: memory-port read pending"],
        "reset mid-run": ["between units", "while a unit runs"],
    },
    "csr_block": {"CSR bus": ["accepted at once", "waited (descriptor read)"]},
    "accel_top": {
        "layers started": ["CONV", "POOL", "FC", "ARGMAX"],
        "inferences": ["after loading images", "back to back, no reload"],
        "descriptor errors": [
            "reserved op",
            "dst = IMG",
            "dst = LOGIT",
            "src = dst",
            "src = LOGIT",
            "FC with dst != LOGIT",
            "ARGMAX with src != LOGIT",
            "missing last",
        ],
        "reset during a layer": [f"layer {i}" for i in range(6)],
        "START": [
            "ignored: busy",
            "ignored: memory-port read pending",
            "with a memory-port read in the same cycle",
            "with a memory-port write in the same cycle",
        ],
        "CSR bus": ["accepted at once", "waited (descriptor read)"],
        "memory port": [
            "accepted at once",
            "request held while busy",
            "request held while a read is pending",
        ],
        "performance counters": ["saturated at 2^PERF_W - 1"],
        "network data: post-processing saturation": ["high", "low"],
    },
}

# (scope, point, bin) -> why the bin cannot or need not be hit.
GAPS: dict[tuple[str, str, str], str] = {
    ("gemm_engine", "postproc -> write port", "stall (valid, not ready)"): (
        "unreachable, and asserted: the write ports accept a write every cycle, so the engine "
        "ties postproc's i_ready high (a_pp_out_never_stalled, gemm_engine_impl_sva.sv). "
        "Backpressure through postproc is covered by its unit test and formal proof."
    ),
    ("gemm_engine", "row register -> postproc", "stall (valid, not ready)"): (
        "unreachable, and asserted: with its output never stalled postproc never fills, so the "
        "row register never waits (a_pp_in_never_stalled)."
    ),
    ("accel_top", "network data: post-processing saturation", "high"): (
        "data property, not a design gap: no MNIST test image saturates high in any layer "
        "(model/reports/saturation.json, all 10,000 images). Covered by the postproc unit test "
        "(directed and random values) and its saturation mutant (m22)."
    ),
    ("accel_top", "network data: post-processing saturation", "low"): (
        "not in the quick subset: over all 10,000 test images conv2 saturates low only 4 times "
        "(images 3081, 5555, 8619, 9427; model/reports/saturation.json), and those images are "
        "bit-exact in the full run (testbench/reports/full_run.md). Covered in the postproc unit "
        "test."
    ),
}


def merge() -> tuple[dict[str, dict[str, dict[str, int]]], list[str]]:
    merged: dict[str, dict[str, dict[str, int]]] = defaultdict(
        lambda: defaultdict(lambda: defaultdict(int))
    )
    files = []
    for f in sorted(SIM_BUILD.glob("*/coverage.json")):
        if any(x in f.parent.name for x in EXCLUDE):
            continue
        data = json.loads(f.read_text())
        files.append(f.parent.name)
        for point, bins in data["points"].items():
            for b, n in bins.items():
                merged[data["scope"]][point][b] += n
    return merged, files


def evaluate(merged) -> tuple[list[dict], list[str]]:
    rows, problems = [], []
    for scope, points in GOALS.items():
        for point, bins in points.items():
            for b in bins:
                hits = merged.get(scope, {}).get(point, {}).get(b, 0)
                gap = GAPS.get((scope, point, b))
                if hits >= 1:
                    status = "met"
                    if gap:
                        problems.append(f"{scope} / {point} / {b}: documented gap was hit")
                elif gap:
                    status = "GAP"
                else:
                    status = "MISSED"
                    problems.append(f"{scope} / {point} / {b}: not hit")
                rows.append(
                    {
                        "scope": scope,
                        "point": point,
                        "bin": b,
                        "hits": hits,
                        "goal": 1,
                        "status": status,
                        "gap": gap,
                    }
                )
    return rows, problems


def write_report(rows: list[dict], merged, files: list[str]) -> None:
    met = sum(r["status"] == "met" for r in rows)
    gaps = [r for r in rows if r["status"] == "GAP"]
    missed = sum(r["status"] == "MISSED" for r in rows)
    extra = [
        (scope, point, b, n)
        for scope, points in sorted(merged.items())
        for point, bins in sorted(points.items())
        for b, n in sorted(bins.items())
        if b not in GOALS.get(scope, {}).get(point, [])
    ]
    REPORT_JSON.write_text(
        json.dumps(
            {
                "script": "scripts/coverage_report.py",
                "bins": len(rows),
                "met": met,
                "documented_gaps": len(gaps),
                "missed": missed,
                "rows": rows,
                "simulations": files,
            },
            indent=1,
        )
        + "\n"
    )
    lines = [
        "# Functional coverage",
        "",
        "Generated by `scripts/coverage_report.py --run` from the `coverage.json` files that the",
        "unit and system tests write (`testbench/common/coverage.py`, D-034), merged over every",
        f"simulator and parameter set ({len(files)} simulations). Goal: at least one hit per bin.",
        "",
        f"**{len(rows)} bins: {met} met, {len(gaps)} documented gaps, {missed} missed.**",
        "",
        "## Documented gaps",
        "",
    ]
    lines += [f"- `{r['scope']}` / {r['point']} / {r['bin']}: {r['gap']}" for r in gaps] or [
        "None."
    ]
    lines += ["", "## Bins", ""]
    for scope in GOALS:
        lines += [f"### `{scope}`", "", "| Point | Bin | Hits | Status |", "|---|---|---|---|"]
        lines += [
            f"| {r['point']} | {r['bin']} | {r['hits']:,} | {r['status']} |"
            for r in rows
            if r["scope"] == scope
        ]
        lines.append("")
    if extra:
        lines += ["## Other recorded bins (no goal)", "", "| Scope | Point | Bin | Hits |"]
        lines += ["|---|---|---|---|"]
        lines += [f"| `{s}` | {p} | {b} | {n:,} |" for s, p, b, n in extra]
        lines.append("")
    REPORT_MD.write_text("\n".join(lines))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if args.run:
        for f in SIM_BUILD.glob("*/coverage.json"):
            f.unlink()
        rc = subprocess.run(
            [sys.executable, "-m", "pytest", "-q", "testbench/unit", "testbench/system"],
            cwd=ROOT,
        ).returncode
        if rc != 0:
            print("tests failed; coverage report not written", file=sys.stderr)
            return 1
    merged, files = merge()
    rows, problems = evaluate(merged)
    if not args.check:
        write_report(rows, merged, files)
        print(f"wrote {REPORT_MD.relative_to(ROOT)}")
    for p in problems:
        print("coverage:", p, file=sys.stderr)
    met = sum(r["status"] == "met" for r in rows)
    gaps = sum(r["status"] == "GAP" for r in rows)
    print(f"{len(rows)} bins: {met} met, {gaps} documented gaps, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
