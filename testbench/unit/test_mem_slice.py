"""mem_slice: random requests through the register stage against a memory-port model (ready only
with no read outstanding, read data 1-3 cycles later as a pulse, random wait states). Checked:
every request reaches the port exactly once, in order, held stable until accepted; each read
returns its data with one o_rvalid pulse, in order.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset


def rdata_of(sel: int, addr: int) -> int:
    return ((sel << 56) ^ (addr * 0x9E3779B97F4A7C15)) & (2**64 - 1)


async def port_model(dut, rng, seen: list) -> None:
    held, pending = None, []  # pending: [cycles left, data]
    while True:
        await FallingEdge(dut.clk)
        rvalid = bool(pending) and pending[0][0] == 0
        dut.i_mem_rvalid.value = int(rvalid)
        if rvalid:
            dut.i_mem_rdata.value = pending.pop(0)[1]
        ready = int(not pending and rng.random() < 0.5)
        dut.i_mem_ready.value = ready
        await ReadOnly()
        if int(dut.o_mem_valid.value):
            req = tuple(
                int(s.value) for s in (dut.o_mem_we, dut.o_mem_sel, dut.o_mem_addr, dut.o_mem_wdata)
            )
            assert held is None or req == held, f"request changed while waiting: {held} -> {req}"
            held = req
            if ready:
                seen.append(req)
                held = None
                if not req[0]:
                    pending.append([rng.randint(0, 2), rdata_of(req[1], req[2])])
        await RisingEdge(dut.clk)
        for p in pending:
            p[0] = max(p[0] - 1, 0)


async def responses(dut, out: list) -> None:
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_rvalid.value):
            out.append(int(dut.o_rdata.value))


@cocotb.test()
async def test_random_requests(dut):
    rng = seeded_rng(dut, "mem_slice")
    for s in (dut.i_valid, dut.i_we, dut.i_sel, dut.i_addr, dut.i_wdata):
        s.value = 0
    for s in (dut.i_mem_ready, dut.i_mem_rvalid, dut.i_mem_rdata):
        s.value = 0
    await start_clock_and_reset(dut)
    seen, reads, sent = [], [], []
    cocotb.start_soon(port_model(dut, rng, seen))
    cocotb.start_soon(responses(dut, reads))
    for _ in range(300):
        req = (rng.randint(0, 1), rng.randrange(8), rng.getrandbits(16), rng.getrandbits(64))
        await FallingEdge(dut.clk)
        dut.i_valid.value = 1
        dut.i_we.value, dut.i_sel.value, dut.i_addr.value, dut.i_wdata.value = req
        while True:
            await ReadOnly()
            accepted = int(dut.o_ready.value)
            await FallingEdge(dut.clk)
            if accepted:
                break
        dut.i_valid.value = 0
        sent.append(req)
        for _ in range(rng.choice([0, 0, 1, 4])):
            await FallingEdge(dut.clk)
    for _ in range(30):
        await FallingEdge(dut.clk)
    assert seen == sent, "requests reached the port out of order, twice or not at all"
    want = [rdata_of(sel, a) for we, sel, a, _ in sent if not we]
    assert reads == want, f"{len(reads)} read responses, want {len(want)} (in order)"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_mem_slice(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="mem_slice",
        sources=[RTL_DIR / "top" / "mem_slice.sv"],
        test_module=Path(__file__).stem,
    )
