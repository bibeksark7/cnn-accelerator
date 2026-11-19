"""Functional coverage collector (docs/decisions.md D-034).

In-house, because cocotb-coverage does not support cocotb 2.x and a new dependency needs
approval. A test records hits with `cover(point, bin)`; the counts of one simulation are written
to `coverage.json` in the simulation's working directory (its build directory) when the
simulator's Python interpreter exits. `scripts/coverage_report.py` merges every build
directory's file, compares the counts with the goals and writes testbench/reports/coverage.md.

File format: {"scope": <toplevel>, "points": {point: {bin: hits}}}.
"""

from __future__ import annotations

import atexit
import json
from collections import defaultdict
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly

COVERAGE_FILE = "coverage.json"

_points: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
_scope: list[str] = []  # the toplevel's name, taken at the first hit


def _save() -> None:
    data = {"scope": _scope[0], "points": {p: dict(b) for p, b in _points.items()}}
    Path(COVERAGE_FILE).write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")


def cover(point: str, bin_name: str, hits: int = 1) -> None:
    """Record `hits` hits of `bin_name` in coverage point `point`."""
    if not _scope:
        _scope.append(cocotb.top._name if cocotb.top is not None else "unknown")
        atexit.register(_save)
    _points[point][bin_name] += hits


async def handshake_monitor(clk, valid, ready, point: str) -> None:
    """Count, every cycle, transfers (valid && ready) and stalls (valid && !ready) of one link.

    Sampled where the testbench's falling-edge drives have settled (D-018). Start it with
    cocotb.start_soon; it runs until the test ends.
    """
    while True:
        await FallingEdge(clk)
        await ReadOnly()
        if not valid.value.is_resolvable or not ready.value.is_resolvable:
            continue
        v, r = int(valid.value), int(ready.value)
        if v and r:
            cover(point, "transfer")
        elif v:
            cover(point, "stall (valid, not ready)")


def start_handshake_monitor(clk, valid, ready, point: str):
    return cocotb.start_soon(handshake_monitor(clk, valid, ready, point))
