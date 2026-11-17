"""Toolchain check: 8-bit counter counts, wraps and resets on Icarus and Verilator."""

from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb

CYCLES = 300  # > 256, so the wrap from 255 to 0 is exercised


async def _reset(dut) -> None:
    dut.rst.value = 1
    dut.en.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0


@cocotb.test()
async def test_count_and_wrap(dut):
    """Counts up by one per enabled cycle and wraps modulo 256."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await ReadOnly()
    assert int(dut.count.value) == 0

    await RisingEdge(dut.clk)  # leave the read-only phase before driving
    dut.en.value = 1
    expected = 0
    for _ in range(CYCLES):
        await RisingEdge(dut.clk)
        await ReadOnly()
        expected = (expected + 1) % 256
        assert int(dut.count.value) == expected, f"got {int(dut.count.value)}, want {expected}"


@cocotb.test()
async def test_enable_holds(dut):
    """Count holds while en is low."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    dut.en.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.en.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    held = int(dut.count.value)
    for _ in range(10):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.count.value) == held


@cocotb.test()
async def test_sync_reset(dut):
    """Reset mid-count returns the counter to zero on the next clock edge."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    dut.en.value = 1
    for _ in range(17):
        await RisingEdge(dut.clk)
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.count.value) == 0


@pytest.mark.parametrize("sim", SIMULATORS)
def test_counter(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="counter",
        sources=[RTL_DIR / "counter.sv"],
        test_module=Path(__file__).stem,
    )
