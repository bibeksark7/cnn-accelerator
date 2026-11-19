"""csr_slice: random requests through the register stage against a CSR-bus model with random wait
states. Checked: every request reaches the back side exactly once, in order, held stable until
accepted; each read returns its data with one o_rvalid pulse, in order; writes return nothing.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset


def rdata_of(addr: int) -> int:
    return (addr * 2654435761) & 0xFFFF_FFFF


async def back_side(dut, rng, seen: list) -> None:
    """CSR bus model: ready after a random number of cycles; checks the hold rule."""
    held = None
    while True:
        await FallingEdge(dut.clk)
        ready = int(rng.random() < 0.4)
        dut.i_csr_ready.value = ready
        if dut.o_csr_addr.value.is_resolvable:  # read data for the address presented this cycle
            dut.i_csr_rdata.value = rdata_of(int(dut.o_csr_addr.value))
        await ReadOnly()
        if int(dut.o_csr_valid.value):
            req = (int(dut.o_csr_we.value), int(dut.o_csr_addr.value), int(dut.o_csr_wdata.value))
            assert held is None or req == held, f"request changed while waiting: {held} -> {req}"
            held = req
            if ready:
                seen.append(req)
                held = None


async def responses(dut, out: list) -> None:
    """Every o_rvalid pulse, sampled each cycle."""
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        if int(dut.o_rvalid.value):
            out.append(int(dut.o_rdata.value))


@cocotb.test()
async def test_random_requests(dut):
    rng = seeded_rng(dut, "csr_slice")
    for s in (dut.i_valid, dut.i_we, dut.i_addr, dut.i_wdata, dut.i_csr_ready, dut.i_csr_rdata):
        s.value = 0
    await start_clock_and_reset(dut)
    seen, reads = [], []
    cocotb.start_soon(back_side(dut, rng, seen))
    cocotb.start_soon(responses(dut, reads))
    sent = []
    for _ in range(300):
        req = (rng.randint(0, 1), rng.getrandbits(12), rng.getrandbits(32))
        await FallingEdge(dut.clk)
        dut.i_valid.value, dut.i_we.value, dut.i_addr.value, dut.i_wdata.value = 1, *req
        while True:
            await ReadOnly()
            accepted = int(dut.o_ready.value)
            await FallingEdge(dut.clk)
            if accepted:
                break
        dut.i_valid.value = 0
        sent.append(req)
        for _ in range(rng.choice([0, 0, 1, 3])):
            await FallingEdge(dut.clk)
    for _ in range(20):  # drain
        await FallingEdge(dut.clk)
    # The data of a read is the CSR read data in its accepting cycle (written at the previous
    # rising edge by the model, for the address presented).
    assert seen == sent, "requests reached the CSR bus out of order, twice or not at all"
    want = [rdata_of(a) for we, a, _ in sent if not we]
    assert reads == want, f"{len(reads)} read responses, want {len(want)} (in order)"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_csr_slice(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="csr_slice",
        sources=[RTL_DIR / "top" / "csr_slice.sv"],
        test_module=Path(__file__).stem,
    )
