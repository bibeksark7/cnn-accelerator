"""Functional coverage collector (docs/decisions.md D-034).

In-house, because cocotb-coverage does not support cocotb 2.x and the collector needed here is
small enough not to justify another dependency. A test records hits with `cover(point, bin)`;
the counts of one simulation are written to `coverage.json` in the simulation's working
directory (its build directory) when the simulator's Python interpreter exits.
`scripts/coverage_report.py` merges every build directory's file, compares the counts with the
goals and writes testbench/reports/coverage.md.

File format: {"scope": <toplevel>, "points": {point: {bin: hits}}}.
"""

from __future__ import annotations

import atexit
import json
from collections import defaultdict
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

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


def is_verilator() -> bool:
    """True inside a Verilator simulation (False when pytest imports a test module to collect)."""
    return (getattr(cocotb, "SIM_NAME", None) or "").lower().startswith("verilator")


def cover_vr_links(links: dict[str, object], must_stall: set[str]) -> None:
    """Coverage from the bound valid_ready_sva monitors (testbench/sva/valid_ready_sva.sv).

    `links` maps a link name to the monitor instance's handle. Records each link's transfers and
    stalls as DUT-observed coverage, and fails if a link in `must_stall` never transferred or
    never stalled (the stall cover). Verilator runs only (the monitors are SVA binds).
    """
    for name, mon in links.items():
        stalls, transfers = int(mon.stalls_q.value), int(mon.transfers_q.value)
        if transfers:
            cover("valid/ready links (SVA monitor)", f"{name}: transfer", transfers)
        if stalls:
            cover("valid/ready links (SVA monitor)", f"{name}: stall", stalls)
        if name in must_stall:
            assert transfers and stalls, f"{name}: {transfers} transfers, {stalls} stalls"


async def csr_wait_monitor(dut) -> None:
    """DUT-observed: each new CSR request (rising i_csr_valid) is accepted at once or waits."""
    while True:
        await RisingEdge(dut.i_csr_valid)
        await ReadOnly()
        if int(dut.o_csr_ready.value):
            cover("CSR bus", "accepted at once")
        else:
            cover("CSR bus", "waited (descriptor read)")


async def mem_wait_monitor(dut, busy) -> None:
    """DUT-observed: each memory-port request is accepted at once, or held because the
    accelerator is busy or a read is pending (`busy` is STATUS.BUSY). A request starts when
    i_mem_valid rises, or in the cycle after an accepted request while i_mem_valid stays high
    (back-to-back requests); it is followed until accepted or withdrawn."""
    valid, ready = dut.i_mem_valid, dut.o_mem_ready
    in_readonly = False  # True when the loop below left us in a ReadOnly phase
    while True:
        if not (valid.value.is_resolvable and int(valid.value)):
            await RisingEdge(valid)
            await ReadOnly()
        elif not in_readonly:
            await ReadOnly()
        if int(ready.value):
            cover("memory port", "accepted at once")
        elif int(busy.value):
            cover("memory port", "request held while busy")
        else:
            cover("memory port", "request held while a read is pending")
        while True:  # follow the request until it is accepted or withdrawn
            accepted = int(valid.value) and int(ready.value)
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            await ReadOnly()
            if accepted or not int(valid.value):
                break
        in_readonly = True
