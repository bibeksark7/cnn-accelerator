"""logit_rf: LOGIT register file. Random writes and reads on both read ports vs a Python model.

The registered port must return the entry one cycle after i_re (written values are visible from
the edge after the write) and hold it while i_re is low; the CSR port is combinational. Reset
clears every entry.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

SOURCES = [RTL_DIR / "mem" / "logit_rf.sv"]


@cocotb.test()
async def test_random_access_and_reset(dut):
    rng = seeded_rng(dut, "logit_rf")
    depth = 1 << len(dut.i_waddr)
    for sig in (dut.i_we, dut.i_re, dut.i_waddr, dut.i_raddr, dut.i_wdata, dut.i_csr_raddr):
        sig.value = 0
    await start_clock_and_reset(dut)
    model = [0] * depth
    held = None  # expected registered read data (None until the first read)
    for cycle in range(3000):
        await FallingEdge(dut.clk)
        if cycle == 1500:  # reset in the middle: every entry back to 0
            dut.rst.value = 1
            await FallingEdge(dut.clk)
            dut.rst.value = 0
            model = [0] * depth
        we, re = rng.random() < 0.5, rng.random() < 0.5
        wa, ra, ca = rng.randrange(depth), rng.randrange(depth), rng.randrange(depth)
        wd = rng.getrandbits(32)
        dut.i_we.value, dut.i_waddr.value, dut.i_wdata.value = int(we), wa, wd
        dut.i_re.value, dut.i_raddr.value, dut.i_csr_raddr.value = int(re), ra, ca
        await ReadOnly()
        got_csr = int(dut.o_csr_rdata.value)
        assert got_csr == model[ca], f"cycle {cycle}: CSR read {ca}: {got_csr:#x} != {model[ca]:#x}"
        if held is not None:
            got = int(dut.o_rdata.value)
            assert got == held, f"cycle {cycle}: registered read {got:#x} != {held:#x}"
        if re:
            held = model[ra]  # read-before-write in the same cycle returns the old value
        if we:
            model[wa] = wd
        await RisingEdge(dut.clk)


@pytest.mark.parametrize("sim", SIMULATORS)
def test_logit_rf(sim: str) -> None:
    run_cocotb(sim=sim, toplevel="logit_rf", sources=SOURCES, test_module=Path(__file__).stem)
