"""axil_slave_port: AXI4-Lite front end (spec §13.3) against a local slave model.

  test_random_sequential  random reads and writes, one at a time, with random AW/W skew,
                          BREADY/RREADY delays (some before VALID), random local ready and
                          response latency (including a response in the acceptance cycle) and
                          random responses: every AXI transaction reaches the local side exactly
                          once with its address, data and strobes, and its response (and read
                          data) comes back unchanged
  test_random_concurrent  a write stream and a read stream at the same time: the port serves
                          them one at a time (at most one local request outstanding), every
                          transaction completes with its own response
  test_write_first        a write and a read buffered in the same cycle: the write is served first
  test_reset_mid_transaction  a reset while a request waits: no valid output afterwards, every
                          channel ready, the next transaction works
  test_zz_aw_w_order_cover  (Verilator, last) the bound axil_resp_order_sva saw every AW/W
                          arrival order (c_aw_before_w, c_w_before_aw, c_aw_with_w); fails if any
                          was never hit
  test_port_sva_fires     (Verilator) a master that changes AWADDR while waiting trips the AW
                          channel's a_payload_stable

Verilator runs bind testbench/sva/axil_slave_port_bind.sv (--assert).
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

from common.axil import DECERR, OKAY, SLVERR, AxilMaster, Timing
from common.coverage import cover_aw_w_orders, is_verilator
from common.runner import RTL_DIR, SIMULATORS, SVA_DIR, run_cocotb, run_sva_violation
from common.sim import seeded_rng, start_clock_and_reset

ADDR_W = 16


def default_word(addr: int) -> int:
    return (addr * 2654435761 + 0x1234) & 0xFFFF_FFFF


class LocalSlave:
    """Local-side model: random i_req_ready, response after a random latency (0 = in the
    acceptance cycle), random response code; checks the request is held stable until accepted."""

    def __init__(self, dut, rng, max_latency: int = 3):
        self.dut, self.rng, self.max_latency = dut, rng, max_latency
        self.mem: dict[int, int] = {}
        self.log: list[tuple] = []  # (we, addr, wdata, wstrb, resp, rdata) per accepted request
        self.open = 0
        self.max_open = 0
        dut.i_req_ready.value = 0
        dut.i_rsp_valid.value = 0
        dut.i_rsp_resp.value = 0
        dut.i_rsp_rdata.value = 0

    def _serve(self, we: int, addr: int, wdata: int, wstrb: int) -> tuple[int, int]:
        resp = self.rng.choice([OKAY, OKAY, OKAY, SLVERR, DECERR])
        word = addr >> 2
        if we:
            old = self.mem.get(word, default_word(word))
            mask = sum(0xFF << (8 * b) for b in range(4) if (wstrb >> b) & 1)
            self.mem[word] = (old & ~mask) | (wdata & mask)
            rdata = 0
        else:
            rdata = self.mem.get(word, default_word(word))
        return resp, rdata

    async def run(self) -> None:
        dut = self.dut
        held = None
        due = None  # (cycles left, resp, rdata)
        while True:
            await FallingEdge(dut.clk)
            dut.i_rsp_valid.value = 0
            # Request outputs are registers: their values now are the ones the next edge sees.
            valid = int(dut.o_req_valid.value)
            req = None
            if valid:
                req = (
                    int(dut.o_req_we.value),
                    int(dut.o_req_addr.value),
                    int(dut.o_req_wdata.value) if int(dut.o_req_we.value) else 0,
                    int(dut.o_req_wstrb.value) if int(dut.o_req_we.value) else 0,
                )
                assert held is None or req == held, (
                    f"request changed while waiting: {held} -> {req}"
                )
                held = req
            ready = int(valid and due is None and self.rng.random() < 0.5)
            dut.i_req_ready.value = ready
            if due is not None:
                left, resp, rdata = due
                if left == 0:
                    dut.i_rsp_valid.value = 1
                    dut.i_rsp_resp.value = resp
                    dut.i_rsp_rdata.value = rdata
                    due = None
                    self.open -= 1
                else:
                    due = (left - 1, resp, rdata)
            if ready:
                resp, rdata = self._serve(*req)
                self.log.append((*req, resp, rdata))
                self.open += 1
                self.max_open = max(self.max_open, self.open)
                held = None
                lat = self.rng.randint(0, self.max_latency)
                if lat == 0:
                    dut.i_rsp_valid.value = 1
                    dut.i_rsp_resp.value = resp
                    dut.i_rsp_rdata.value = rdata
                    self.open -= 1
                else:
                    due = (lat - 1, resp, rdata)
            await ReadOnly()


async def setup(dut, name: str, timing: Timing | None = None):
    rng = seeded_rng(dut, name)
    master = AxilMaster(dut, rng, timing=timing)
    local = LocalSlave(dut, rng)
    await start_clock_and_reset(dut)
    cocotb.start_soon(local.run())
    return rng, master, local


def random_addr(rng) -> int:
    return rng.getrandbits(ADDR_W) & ~3 if rng.random() < 0.5 else rng.choice([0, 4, 8]) & ~3


@cocotb.test()
async def test_random_sequential(dut):
    rng, master, local = await setup(dut, "sequential")
    results = []
    for _ in range(400):
        addr = random_addr(rng) | rng.getrandbits(2)
        if rng.random() < 0.5:
            data, strb = rng.getrandbits(32), rng.getrandbits(4)
            resp = await master.write(addr, data, strb)
            results.append((1, addr, data, strb, resp, 0))
        else:
            data, resp = await master.read(addr)
            results.append((0, addr, 0, 0, resp, data))
    assert len(local.log) == len(results), (
        f"{len(local.log)} local requests for {len(results)} AXI transactions"
    )
    for i, (got, want) in enumerate(zip(local.log, results, strict=True)):
        assert got == want, f"transaction {i}: local side {got}, AXI side {want}"
    assert local.max_open == 1


@cocotb.test()
async def test_random_concurrent(dut):
    rng, master, local = await setup(dut, "concurrent")
    writes: list[tuple] = []
    reads: list[tuple] = []
    # Writes and reads go to disjoint word sets, so the read data does not depend on the order.
    for w in range(0, 64):
        local.mem[w] = default_word(w)

    async def writer():
        for _ in range(150):
            addr = (0x400 + rng.randrange(64)) * 4
            data = rng.getrandbits(32)
            resp = await master.write(addr, data)
            writes.append((addr, data, resp))

    async def reader():
        for _ in range(150):
            addr = rng.randrange(64) * 4
            data, resp = await master.read(addr)
            reads.append((addr, data, resp))

    tw, tr = cocotb.start_soon(writer()), cocotb.start_soon(reader())
    await tw
    await tr
    log_w = [(a, d, r) for we, a, d, _, r, _ in local.log if we]
    log_r = [(a, rd, r) for we, a, _, _, r, rd in local.log if not we]
    assert log_w == writes, "write responses do not match the local side, in order"
    assert log_r == reads, "read data/responses do not match the local side, in order"
    assert local.max_open == 1, "more than one local request outstanding"
    interleaved = sum(1 for a, b in zip(local.log, local.log[1:], strict=False) if a[0] != b[0])
    assert interleaved > 20, "the two streams were not interleaved"


@cocotb.test()
async def test_write_first(dut):
    _, _, local = await setup(dut, "write_first")
    for s in ("bready", "rready"):
        getattr(dut, f"i_{s}").value = 1
    await FallingEdge(dut.clk)
    dut.i_awvalid.value, dut.i_awaddr.value = 1, 0x10
    dut.i_wvalid.value, dut.i_wdata.value, dut.i_wstrb.value = 1, 0xAB, 0xF
    dut.i_arvalid.value, dut.i_araddr.value = 1, 0x20
    await FallingEdge(dut.clk)  # all three accepted at the edge just passed
    dut.i_awvalid.value = dut.i_wvalid.value = dut.i_arvalid.value = 0
    for _ in range(100):
        await FallingEdge(dut.clk)
        if len(local.log) == 2:
            break
    assert [e[0] for e in local.log] == [1, 0], f"order {local.log}"


@cocotb.test()
async def test_reset_mid_transaction(dut):
    rng = seeded_rng(dut, "reset")
    master = AxilMaster(dut, rng)
    dut.i_req_ready.value = 0
    dut.i_rsp_valid.value = 0
    dut.i_rsp_resp.value = 0
    dut.i_rsp_rdata.value = 0
    await start_clock_and_reset(dut)
    await FallingEdge(dut.clk)
    dut.i_awvalid.value, dut.i_awaddr.value = 1, 0x40
    dut.i_wvalid.value, dut.i_wdata.value, dut.i_wstrb.value = 1, 0x55, 0xF
    await FallingEdge(dut.clk)
    dut.i_awvalid.value = dut.i_wvalid.value = 0
    for _ in range(5):
        await FallingEdge(dut.clk)
    assert int(dut.o_req_valid.value), "request not presented"
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await ReadOnly()
    for s in ("o_req_valid", "o_bvalid", "o_rvalid"):
        assert int(getattr(dut, s).value) == 0, f"{s} high after reset"
    for s in ("o_awready", "o_wready", "o_arready"):
        assert int(getattr(dut, s).value) == 1, f"{s} low after reset"
    await FallingEdge(dut.clk)
    local = LocalSlave(dut, rng)
    cocotb.start_soon(local.run())
    resp = await master.write(0x80, 0x1234)
    data, rresp = await master.read(0x80)
    assert local.log[0][:3] == (1, 0x80, 0x1234) and resp == local.log[0][4]
    assert data == 0x1234 and rresp == local.log[1][4]


@cocotb.test(skip=not is_verilator() or os.environ.get("SVA_VIOLATION") is not None)
async def test_zz_aw_w_order_cover(dut):
    """Last test (Verilator): every AW/W arrival order reached the port."""
    cover_aw_w_orders("slave port", dut.u_order_sva)


@cocotb.test(skip=os.environ.get("SVA_VIOLATION") is None)
async def sva_violation_aw_changed(dut):
    """AWADDR changes while AW waits (the AW buffer is full while the first write's request is
    held by a local side that never accepts)."""
    dut.i_req_ready.value = 0
    dut.i_rsp_valid.value = 0
    dut.i_rsp_resp.value = 0
    dut.i_rsp_rdata.value = 0
    for s in ("i_wvalid", "i_arvalid", "i_bready", "i_rready", "i_wdata", "i_wstrb", "i_araddr"):
        getattr(dut, s).value = 0
    await start_clock_and_reset(dut)
    await FallingEdge(dut.clk)
    dut.i_awvalid.value, dut.i_awaddr.value = 1, 0x10
    await FallingEdge(dut.clk)  # first AW accepted; the next one waits
    dut.i_awaddr.value = 0x14
    await FallingEdge(dut.clk)
    dut.i_awaddr.value = 0x18  # changed while waiting
    await ClockCycles(dut.clk, 4)


def sources_and_args(sim: str) -> tuple[list[Path], list[str]]:
    sources = [RTL_DIR / "axi" / "axil_slave_port.sv"]
    args: list[str] = []
    if sim == "verilator":
        sources += [
            SVA_DIR / "valid_ready_sva.sv",
            SVA_DIR / "axil_resp_order_sva.sv",
            SVA_DIR / "req_rsp_sva.sv",
            SVA_DIR / "axil_slave_port_bind.sv",
        ]
        args = ["--assert"]
    return sources, args


@pytest.mark.parametrize("sim", SIMULATORS)
def test_axil_slave_port(sim: str) -> None:
    sources, args = sources_and_args(sim)
    run_cocotb(
        sim=sim,
        toplevel="axil_slave_port",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={"ADDR_W": ADDR_W},
        extra_build_args=args,
    )


def test_port_sva_fires() -> None:
    sources, args = sources_and_args("verilator")
    run_sva_violation(
        toplevel="axil_slave_port",
        sources=sources,
        test_module=Path(__file__).stem,
        violation="aw_changed",
        assertion="u_aw_vr_sva",
        parameters={"ADDR_W": ADDR_W},
        extra_build_args=args,
    )
