"""debounce: bounces shorter than 2^CNT_W cycles never change the level or pulse; a press held
2^CNT_W cycles gives exactly one o_press pulse; a release gives none (cycle-by-cycle model)."""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

CNT_W = 4


class Model:
    def __init__(self):
        self.cnt, self.level, self.press = 0, 1, 0

    def step(self, key_n: int) -> None:
        self.press = 0
        if key_n == self.level:
            self.cnt = 0
        elif self.cnt == (1 << CNT_W) - 1:
            self.cnt, self.level, self.press = 0, key_n, int(not key_n)
        else:
            self.cnt += 1


@cocotb.test()
async def test_bouncy_presses(dut):
    rng = seeded_rng(dut, "debounce")
    dut.i_key_n.value = 1
    await start_clock_and_reset(dut)
    m = Model()
    presses = 0
    stable = 1 << CNT_W
    # Sequences of (level, cycles): bounces shorter than the stable time, then a held level.
    for _ in range(30):
        seq = [(rng.randint(0, 1), rng.randint(1, stable - 1)) for _ in range(rng.randint(0, 6))]
        seq.append((rng.randint(0, 1), rng.randint(stable + 1, 3 * stable)))
        for level, cycles in seq:
            for _ in range(cycles):
                await FallingEdge(dut.clk)
                dut.i_key_n.value = level  # sampled by the next rising edge
                await RisingEdge(dut.clk)
                m.step(level)
                await ReadOnly()
                got = (int(dut.o_level_n.value), int(dut.o_press.value))
                assert got == (m.level, m.press), f"(level, press) {got} != {(m.level, m.press)}"
                presses += m.press
    assert presses >= 5, f"only {presses} presses exercised"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_debounce(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="debounce",
        sources=[RTL_DIR / "top" / "debounce.sv"],
        test_module=Path(__file__).stem,
        parameters={"CNT_W": CNT_W},
    )
