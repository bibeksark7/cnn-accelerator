"""sync_2ff: the output is the input delayed by two clock edges, and the reset value in reset."""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset


@cocotb.test()
async def test_two_cycle_delay_and_reset(dut):
    rng = seeded_rng(dut, "sync")
    dut.i_async.value = 0
    await start_clock_and_reset(dut)
    # Reset was released at a falling edge; the next rising edge loaded meta with the input (0)
    # and sync with the reset value. A value driven at a falling edge appears on o_sync after the
    # second rising edge, i.e. history[-2] after the first.
    history = [0b1010, 0]
    for cycle in range(200):
        await FallingEdge(dut.clk)
        v = rng.getrandbits(4)
        dut.i_async.value = v
        history.append(v)
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.o_sync.value) == history[-2], f"cycle {cycle}"
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    await FallingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.o_sync.value) == 0b1010, "reset value"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_sync_2ff(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="sync_2ff",
        sources=[RTL_DIR / "top" / "sync_2ff.sv"],
        test_module=Path(__file__).stem,
        parameters={"W": 4, "RESET": 0b1010},
    )
