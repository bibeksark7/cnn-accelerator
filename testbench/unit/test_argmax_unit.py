"""argmax_unit: first index of the largest signed int32 logit (ties to the lowest index).

Compared against np.argmax, whose tie rule is the spec's. A register-file model answers reads
with a 1-cycle latency. Verilator runs bind the shared unit contract
(testbench/sva/unit_if_sva.sv); test_argmax_sva_fires shows the sequencer-side assertions are live.
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.bits import to_signed, to_unsigned
from common.runner import RTL_DIR, SIMULATORS, SVA_DIR, run_cocotb, run_sva_violation
from common.sim import resolved, seeded_rng, start_clock_and_reset

I32_MIN, I32_MAX = -(2**31), 2**31 - 1
SOURCES = [RTL_DIR / "post" / "argmax_unit.sv"]
SVA_SOURCES = [SVA_DIR / "unit_if_sva.sv", SVA_DIR / "argmax_unit_bind.sv"]
SVA_VIOLATION = os.environ.get("SVA_VIOLATION", "")


async def serve(dut, regs: list[int]) -> None:
    """LOGIT register-file model (1-cycle read latency); an X read strobe or index fails."""
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        idx = None
        if resolved(dut.o_rd_en, "argmax read enable"):
            idx = resolved(dut.o_rd_idx, "argmax read index")
        await RisingEdge(dut.clk)
        if idx is not None:
            dut.i_rd_data.value = to_unsigned(regs[idx], 32)


async def run_argmax(dut, regs: list[int], base: int, count: int) -> tuple[int, int]:
    server = cocotb.start_soon(serve(dut, regs))
    await FallingEdge(dut.clk)
    dut.i_base.value, dut.i_count.value = base, count
    dut.i_start.value = 1
    # Watch o_done from the first edge after the start: with count = 0 it pulses immediately.
    for _ in range(count + 100):  # hang guard, not a latency
        await RisingEdge(dut.clk)
        await ReadOnly()
        if resolved(dut.o_done, "argmax done"):
            break
        await FallingEdge(dut.clk)
        dut.i_start.value = 0
    else:
        raise TimeoutError("o_done never pulsed")
    result = resolved(dut.o_result, "argmax result at done")
    best = to_signed(resolved(dut.o_max, "argmax maximum at done"), 32)
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    await FallingEdge(dut.clk)
    server.cancel()
    return result, best


async def check(dut, regs: list[int], base: int, count: int, what: str) -> None:
    window = np.array(regs[base : base + count], dtype=np.int64)
    want = (int(np.argmax(window)), int(window.max())) if count else (0, 0)
    got = await run_argmax(dut, regs, base, count)
    assert got == want, f"{what}: got (index, max) {got}, want {want}, logits {window.tolist()}"


async def setup(dut) -> list[int]:
    dut.i_start.value = 0
    dut.i_rd_data.value = 0
    await start_clock_and_reset(dut)
    return [0] * 256


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_directed(dut):
    regs = await setup(dut)
    cases = {
        "tie at the max": [5, 9, 9, 1, 0, 0, 0, 0, 0, 0],
        "all equal": [-3] * 10,
        "max last": [0] * 9 + [7],
        "int32 min then min + 1": [I32_MIN] * 9 + [I32_MIN + 1],
        "int32 max tie": [I32_MAX, I32_MAX] + [0] * 8,
        "all negative": [-9, -2, -5, -2, -100, -3, -4, -8, -7, -6],
        "single logit": [42],
    }
    for name, vals in cases.items():
        base = 3
        regs[base : base + len(vals)] = vals
        await check(dut, regs, base, len(vals), name)
    await check(dut, regs, 0, 0, "count 0")


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_random_with_planted_ties(dut):
    rng = seeded_rng(dut, "argmax")
    regs = await setup(dut)
    for t in range(300):
        count = rng.randint(1, 16)
        base = rng.randrange(0, 256 - count)
        if rng.random() < 0.5:
            vals = [rng.randint(-1000, 1000) for _ in range(count)]
        else:
            vals = [rng.randint(I32_MIN, I32_MAX) for _ in range(count)]
        if count > 1 and rng.random() < 0.5:  # plant a tie at the maximum
            i, j = sorted(rng.sample(range(count), 2))
            vals[j] = vals[i] = max(vals)
        regs[base : base + count] = vals
        await check(dut, regs, base, count, f"case {t}")


async def start_busy_argmax(dut) -> None:
    """Start a 10-logit scan and wait a few cycles (it is still busy)."""
    regs = await setup(dut)
    cocotb.start_soon(serve(dut, regs))
    await FallingEdge(dut.clk)
    dut.i_base.value, dut.i_count.value = 0, 10
    dut.i_start.value = 1
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)


@cocotb.test(skip=SVA_VIOLATION != "start_while_busy")
async def sva_violation_start_while_busy(dut):
    """A second i_start during the scan; only run by test_argmax_sva_fires."""
    await start_busy_argmax(dut)
    dut.i_start.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.i_start.value = 0


@cocotb.test(skip=SVA_VIOLATION != "cfg_change_while_busy")
async def sva_violation_cfg_change_while_busy(dut):
    """The logit count changes during the scan; only run by test_argmax_sva_fires."""
    await start_busy_argmax(dut)
    dut.i_count.value = 4
    for _ in range(3):
        await FallingEdge(dut.clk)


def build(sim: str) -> tuple[list[Path], list[str]]:
    if sim == "verilator":
        return SOURCES + SVA_SOURCES, ["--assert"]
    return SOURCES, []


@pytest.mark.parametrize("sim", SIMULATORS)
def test_argmax_unit(sim: str) -> None:
    sources, args = build(sim)
    run_cocotb(
        sim=sim,
        toplevel="argmax_unit",
        sources=sources,
        test_module=Path(__file__).stem,
        extra_build_args=args,
    )


@pytest.mark.parametrize(
    ("violation", "assertion"),
    [
        ("start_while_busy", "a_start_only_when_idle"),
        ("cfg_change_while_busy", "a_cfg_stable_while_busy"),
    ],
)
def test_argmax_sva_fires(violation: str, assertion: str) -> None:
    sources, args = build("verilator")
    run_sva_violation(
        toplevel="argmax_unit",
        sources=sources,
        test_module=Path(__file__).stem,
        violation=violation,
        assertion=assertion,
        extra_build_args=args,
    )
