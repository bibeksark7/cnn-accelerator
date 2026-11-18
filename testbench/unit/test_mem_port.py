"""mem_port: host memory-port handshake and read return (spec §10.3), cycle by cycle vs a model.

Random requests (every sel including reserved 5-7, reads and writes, random valid) while BUSY
toggles. Checked every cycle:
  - o_mem_ready is low while busy and while a read is pending;
  - an accepted request raises exactly the strobe of its buffer (none for reserved sel);
  - every accepted read returns exactly one o_mem_rvalid, with the data of the buffer that was
    read (zero-extended; 0 for reserved sel), and o_rd_pending marks it.
The buffer read-data inputs change every cycle, so a wrong or late select is caught.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

SOURCES = [RTL_DIR / "mem" / "mem_port.sv"]


@cocotb.test()
async def test_random_traffic(dut):
    rng = seeded_rng(dut, "mem_port")
    wgt_w = len(dut.i_wgt_rdata)
    for s in (dut.i_mem_valid, dut.i_mem_we, dut.i_mem_sel, dut.i_busy):
        s.value = 0
    await start_clock_and_reset(dut)
    pending_sel = None  # sel of the read accepted at the previous edge
    reads = rvalids = 0
    busy = False
    for cycle in range(5000):
        await FallingEdge(dut.clk)
        if rng.random() < 0.02:
            busy = not busy
        valid, we, sel = rng.random() < 0.7, rng.random() < 0.5, rng.randrange(8)
        rdata = {
            0: rng.getrandbits(8),
            1: rng.getrandbits(8),
            2: rng.getrandbits(8),
            3: rng.getrandbits(wgt_w),
            4: rng.getrandbits(64),
        }
        dut.i_busy.value = int(busy)
        dut.i_mem_valid.value, dut.i_mem_we.value, dut.i_mem_sel.value = int(valid), int(we), sel
        dut.i_img_rdata.value, dut.i_act0_rdata.value = rdata[0], rdata[1]
        dut.i_act1_rdata.value, dut.i_wgt_rdata.value = rdata[2], rdata[3]
        dut.i_prm_rdata.value = rdata[4]
        await ReadOnly()
        ready = int(dut.o_mem_ready.value)
        want_ready = int(not busy and pending_sel is None)
        assert ready == want_ready, f"cycle {cycle}: ready {ready}, want {want_ready}"
        # Read return for the read accepted last cycle.
        rv = int(dut.o_mem_rvalid.value)
        assert rv == int(pending_sel is not None), f"cycle {cycle}: rvalid {rv}"
        assert int(dut.o_rd_pending.value) == rv, f"cycle {cycle}: o_rd_pending != o_mem_rvalid"
        if pending_sel is not None:
            rvalids += 1
            want = rdata.get(pending_sel, 0) & ((1 << 64) - 1)
            got = int(dut.o_mem_rdata.value)
            assert got == want, f"cycle {cycle}: sel {pending_sel} read {got:#x}, want {want:#x}"
        # Strobes for this cycle's request.
        accept = valid and ready
        want_re = 1 << sel if accept and not we and sel < 5 else 0
        want_we = 1 << sel if accept and we and sel < 5 else 0
        got_re, got_we = int(dut.o_re.value), int(dut.o_we.value)
        assert (got_re, got_we) == (want_re, want_we), (
            f"cycle {cycle}: strobes re {got_re:05b} we {got_we:05b}, "
            f"want {want_re:05b} {want_we:05b}"
        )
        pending_sel = sel if accept and not we else None
        reads += int(accept and not we)
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    rvalids += int(pending_sel is not None)
    assert reads == rvalids and reads > 500, f"{reads} reads accepted, {rvalids} rvalid pulses"


@pytest.mark.parametrize(("sim", "wgt_w"), [("icarus", 64), ("icarus", 24), ("verilator", 64)])
def test_mem_port(sim: str, wgt_w: int) -> None:
    run_cocotb(
        sim=sim,
        toplevel="mem_port",
        sources=SOURCES,
        test_module=Path(__file__).stem,
        parameters={"WGT_W": wgt_w},
    )
