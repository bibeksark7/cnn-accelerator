"""argmax_unit: first index of the largest signed int32 logit (ties to the lowest index).

Compared against np.argmax, whose tie rule is the spec's. A register-file model answers reads
with a 1-cycle latency.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.bits import to_signed, to_unsigned
from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

I32_MIN, I32_MAX = -(2**31), 2**31 - 1
SOURCE = RTL_DIR / "post" / "argmax_unit.sv"


async def serve(dut, regs: list[int]) -> None:
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        idx = int(dut.o_rd_idx.value) if int(dut.o_rd_en.value) else None
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
        if int(dut.o_done.value):
            break
        await FallingEdge(dut.clk)
        dut.i_start.value = 0
    else:
        raise TimeoutError("o_done never pulsed")
    result, best = int(dut.o_result.value), to_signed(int(dut.o_max.value), 32)
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


@cocotb.test()
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


@cocotb.test()
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


@pytest.mark.parametrize("sim", SIMULATORS)
def test_argmax_unit(sim: str) -> None:
    run_cocotb(sim=sim, toplevel="argmax_unit", sources=[SOURCE], test_module=Path(__file__).stem)
