"""mac_cell: multiply-accumulate, clear, hold on idle cycles, one-cycle operand forwarding.

Convention: inputs are driven after a falling edge and outputs are checked in ReadOnly after
the following rising edge.
"""

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.bits import to_signed, to_unsigned
from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

DATA_W, ACC_W = 8, 32


def acc_value(dut) -> int:
    return to_signed(int(dut.o_acc.value), ACC_W)


def idle_inputs(dut) -> None:
    dut.i_clear.value = 0
    dut.i_valid.value = 0
    dut.i_a.value = 0
    dut.i_b.value = 0


async def clock_edge_and_sample(dut) -> None:
    await RisingEdge(dut.clk)
    await ReadOnly()


@cocotb.test()
async def test_reset_state(dut):
    idle_inputs(dut)
    await start_clock_and_reset(dut)
    await clock_edge_and_sample(dut)
    assert acc_value(dut) == 0
    assert int(dut.o_valid.value) == 0


@cocotb.test()
async def test_random_accumulate_with_gaps_and_clears(dut):
    """Random operands (biased to int8 extremes), idle gaps and clears vs a Python model."""
    rng = seeded_rng(dut, "mac")
    idle_inputs(dut)
    await start_clock_and_reset(dut)
    model = 0
    for step in range(2000):
        await FallingEdge(dut.clk)
        action = rng.random()
        if action < 0.05:
            dut.i_clear.value, dut.i_valid.value = 1, 0
            model = 0
        elif action < 0.30:
            dut.i_clear.value, dut.i_valid.value = 0, 0
        else:
            a = rng.choice([-128, 127, rng.randint(-128, 127)])
            b = rng.choice([-128, 127, rng.randint(-128, 127)])
            dut.i_clear.value, dut.i_valid.value = 0, 1
            dut.i_a.value, dut.i_b.value = to_unsigned(a, DATA_W), to_unsigned(b, DATA_W)
            model = to_signed(model + a * b, ACC_W)
        await clock_edge_and_sample(dut)
        assert acc_value(dut) == model, f"step {step}: got {acc_value(dut)}, want {model}"


@cocotb.test()
async def test_accumulator_wraps_modulo_2_pow_acc_w(dut):
    """The accumulator wraps (no saturation), as spec §3 defines."""
    idle_inputs(dut)
    await start_clock_and_reset(dut)
    model = 0
    steps = (2**31) // (128 * 128) + 2  # enough (-128)*(-128) products to pass INT32_MAX
    for _ in range(steps):
        await FallingEdge(dut.clk)
        dut.i_valid.value = 1
        dut.i_a.value = dut.i_b.value = to_unsigned(-128, DATA_W)
        model = to_signed(model + 128 * 128, ACC_W)
    await FallingEdge(dut.clk)
    idle_inputs(dut)
    await clock_edge_and_sample(dut)
    assert model < 0  # the reference wrapped
    assert acc_value(dut) == model


@cocotb.test()
async def test_forwarding_is_one_cycle(dut):
    rng = seeded_rng(dut, "fwd")
    idle_inputs(dut)
    await start_clock_and_reset(dut)
    for _ in range(200):
        await FallingEdge(dut.clk)
        a, b, v = rng.randint(-128, 127), rng.randint(-128, 127), rng.randint(0, 1)
        dut.i_a.value, dut.i_b.value = to_unsigned(a, DATA_W), to_unsigned(b, DATA_W)
        dut.i_valid.value = v
        await clock_edge_and_sample(dut)
        assert int(dut.o_valid.value) == v
        assert to_signed(int(dut.o_a.value), DATA_W) == a
        assert to_signed(int(dut.o_b.value), DATA_W) == b


@pytest.mark.parametrize("sim", SIMULATORS)
def test_mac_cell(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="mac_cell",
        sources=[RTL_DIR / "core" / "mac_cell.sv"],
        test_module=Path(__file__).stem,
        parameters={"DATA_W": DATA_W, "ACC_W": ACC_W},
    )
