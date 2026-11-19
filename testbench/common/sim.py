"""Common cocotb helpers: clock, reset, seeded RNG, bounded waits, X-checked reads."""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

CLK_PERIOD_NS = 10
DEFAULT_SEED = 20261117


def seeded_rng(dut, name: str = "") -> random.Random:
    """RNG seeded from TB_SEED (default fixed) and logged so any failure can be reproduced."""
    seed = int(os.environ.get("TB_SEED", DEFAULT_SEED))
    dut._log.info(
        "random seed %d%s (set TB_SEED to override)", seed, f" for {name}" if name else ""
    )
    return random.Random(f"{seed}:{name}")


async def start_clock_and_reset(dut, cycles: int = 3) -> None:
    """Start `clk`, hold `rst` high for `cycles` rising edges, then release it on a falling edge.

    Releasing away from the rising edge avoids any race between the reset change and the edge.
    """
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk, cycles)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def wait_until(dut, predicate, timeout_cycles: int, what: str) -> int:
    """Wait for rising edges until predicate() holds (sampled in ReadOnly). Returns cycles waited.

    The timeout is a generous upper bound to catch hangs, never an expected latency.
    """
    for n in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if predicate():
            return n
    raise TimeoutError(f"timed out after {timeout_cycles} cycles waiting for {what}")


def resolved(handle, what: str) -> int:
    """The value of `handle` as an int; fails with an explicit message if any bit is X or Z.

    Use it wherever a monitor turns a DUT output into a number, so an X shows up as
    "<what>: X/Z on <signal>" with its time and bit pattern, not as a conversion error.
    """
    value = handle.value
    if not value.is_resolvable:
        raise AssertionError(
            f"{what}: X/Z on {handle._name} = {value} at {get_sim_time(unit='ns'):.0f} ns"
        )
    return int(value)
