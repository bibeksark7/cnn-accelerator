"""reset_gen: from power-up (registers 0) o_rst is high for the power-on time, then low; a reset
press raises it (after the synchronizer) and it falls a fixed few cycles after the release."""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, Timer

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import CLK_PERIOD_NS

POR_CYCLES = 20
SOURCES = [RTL_DIR / "top" / "reset_gen.sv", RTL_DIR / "top" / "sync_2ff.sv"]


async def cycles_until(dut, value: int, limit: int) -> int:
    for n in range(limit):
        await FallingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_rst.value) == value:
            return n + 1
    raise TimeoutError(f"o_rst never became {value}")


@cocotb.test()
async def test_power_up_from_initializer(dut):
    # Runs first, from time 0, with nothing deposited: por_cnt_q starts at 0 from its
    # declaration initializer, and the power-on reset lasts POR_CYCLES.
    # Checked before the clock starts (its first edge would already advance the counter).
    dut.i_key_rst_n.value = 1
    await ReadOnly()
    assert dut.por_cnt_q.value.is_resolvable, f"por_cnt_q is {dut.por_cnt_q.value} at power-up"
    assert int(dut.por_cnt_q.value) == 0, "por_cnt_q does not start at 0"
    assert int(dut.o_rst.value) == 1, "reset not active at power-up"
    await Timer(1, unit="ns")
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    n = await cycles_until(dut, 0, 10 * POR_CYCLES)
    assert POR_CYCLES <= n <= POR_CYCLES + 4, f"power-on reset lasted {n} cycles"


@cocotb.test()
async def test_power_on_and_button(dut):
    # Power-up: MAX 10 registers start at 0 (Quartus default power-up level).
    for sig in (dut.por_cnt_q, dut.rst1_q, dut.rst2_q):
        sig.value = 0
    dut.i_key_rst_n.value = 1
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await ReadOnly()
    assert int(dut.o_rst.value) == 1, "reset not active at power-up"
    n = await cycles_until(dut, 0, 10 * POR_CYCLES)
    assert POR_CYCLES <= n <= POR_CYCLES + 4, f"power-on reset lasted {n} cycles"
    for _ in range(50):  # stays released
        await FallingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.o_rst.value) == 0
    for hold in (1, 3, 10):
        await FallingEdge(dut.clk)
        dut.i_key_rst_n.value = 0
        rise = await cycles_until(dut, 1, 10)
        assert rise == 2, f"reset rose {rise} cycles after the press"
        for _ in range(hold):
            await FallingEdge(dut.clk)
        dut.i_key_rst_n.value = 1
        fall = await cycles_until(dut, 0, 20)
        assert fall == 4, f"reset fell {fall} cycles after the release"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_reset_gen(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="reset_gen",
        sources=SOURCES,
        test_module=Path(__file__).stem,
        parameters={"POR_CYCLES": POR_CYCLES},
    )
