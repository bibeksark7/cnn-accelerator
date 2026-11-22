"""axil_interconnect: one master, three slaves with the SoC's address map (spec §13.3).

  test_random_traffic     concurrent write and read streams to random addresses in every region,
                          at region edges, and unmapped (including RAM aliases above 64 KB):
                          each transaction reaches exactly the slave that owns its address, with
                          its address, data and strobes, and nothing else does; responses and read
                          data come back from that slave; unmapped addresses get DECERR (reads 0)
                          and reach no slave. Slaves have random ready and response delays and
                          check that VALID and the payload are held until READY
  test_one_outstanding    while a write's B (a read's R) waits for the master, no new AW (AR) is
                          accepted; a W that arrives before its AW waits for it

Slave models: SlaveBank (all NS slaves in one coroutine, writing whole vectors each cycle).
Verilator runs bind testbench/sva/axil_interconnect_bind.sv (--assert) on the master side.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

from common.axil import DECERR, OKAY, SLVERR, AxilMaster
from common.runner import RTL_DIR, SIMULATORS, SVA_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

# The SoC map (spec §13.3): RAM 64 KB, accelerator 8 MB (CSR + buffer windows), GPIO 4 KB.
REGIONS = [(0x0000_0000, 0xFFFF_0000), (0x1000_0000, 0xFF80_0000), (0x2000_0000, 0xFFFF_F000)]
NS = len(REGIONS)


def owner(addr: int) -> int | None:
    for s, (base, mask) in enumerate(REGIONS):
        if addr & mask == base:
            return s
    return None


def word_of(s: int, addr: int) -> int:
    return (addr * 40503 + s * 0x1111_1111) & 0xFFFF_FFFF


class SlaveBank:
    """NS AXI4-Lite slave models on the interconnect's packed slave-side ports."""

    def __init__(self, dut, rng):
        self.dut, self.rng = dut, rng
        self.writes = [[] for _ in range(NS)]  # (addr, data, strb, resp)
        self.reads = [[] for _ in range(NS)]  # (addr, data, resp)
        for name in ("awready", "wready", "bvalid", "bresp", "arready", "rvalid", "rdata", "rresp"):
            getattr(dut, f"i_m_{name}").value = 0

    async def run(self) -> None:
        dut, rng = self.dut, self.rng
        aw = [None] * NS  # accepted address
        w = [None] * NS  # accepted (data, strb)
        ar = [None] * NS
        b = [None] * NS  # (delay, resp) or ("valid", resp)
        r = [None] * NS  # (delay, data, resp) or ("valid", data, resp)
        waiting = {}  # (chan, s) -> payload seen while VALID && !READY
        while True:
            await FallingEdge(dut.clk)
            awready = wready = arready = bvalid = rvalid = 0
            bresp = rresp = rdata = 0
            for s in range(NS):
                if aw[s] is None and rng.random() < 0.5:
                    awready |= 1 << s
                if w[s] is None and rng.random() < 0.5:
                    wready |= 1 << s
                if ar[s] is None and rng.random() < 0.5:
                    arready |= 1 << s
                if aw[s] is not None and w[s] is not None and b[s] is None:
                    b[s] = (rng.randint(0, 3), rng.choice([OKAY, OKAY, SLVERR]))
                if b[s] is not None:
                    if b[s][0] == "valid" or b[s][0] == 0:
                        b[s] = ("valid", b[s][1])
                        bvalid |= 1 << s
                        bresp |= b[s][1] << (2 * s)
                    else:
                        b[s] = (b[s][0] - 1, b[s][1])
                if ar[s] is not None and r[s] is None:
                    r[s] = (rng.randint(0, 3), word_of(s, ar[s]), rng.choice([OKAY, OKAY, SLVERR]))
                if r[s] is not None:
                    if r[s][0] == "valid" or r[s][0] == 0:
                        r[s] = ("valid", r[s][1], r[s][2])
                        rvalid |= 1 << s
                        rdata |= r[s][1] << (32 * s)
                        rresp |= r[s][2] << (2 * s)
                    else:
                        r[s] = (r[s][0] - 1, r[s][1], r[s][2])
            dut.i_m_awready.value, dut.i_m_wready.value = awready, wready
            dut.i_m_arready.value = arready
            dut.i_m_bvalid.value, dut.i_m_bresp.value = bvalid, bresp
            dut.i_m_rvalid.value, dut.i_m_rdata.value, dut.i_m_rresp.value = rvalid, rdata, rresp
            await ReadOnly()
            v_aw, v_w, v_ar = (int(getattr(dut, f"o_m_{c}valid").value) for c in ("aw", "w", "ar"))
            r_b, r_r = int(dut.o_m_bready.value), int(dut.o_m_rready.value)
            awaddr, araddr = int(dut.o_m_awaddr.value), int(dut.o_m_araddr.value)
            wpay = (int(dut.o_m_wdata.value), int(dut.o_m_wstrb.value))
            for s in range(NS):
                bit = 1 << s
                for chan, valid, ready, pay in (
                    ("aw", v_aw, awready, awaddr),
                    ("w", v_w, wready, wpay),
                    ("ar", v_ar, arready, araddr),
                ):
                    if valid & bit:
                        held = waiting.get((chan, s))
                        assert held is None or held == pay, f"slave {s} {chan}: {held} -> {pay}"
                        if ready & bit:
                            waiting.pop((chan, s), None)
                            if chan == "aw":
                                aw[s] = pay
                            elif chan == "w":
                                w[s] = pay
                            else:
                                ar[s] = pay
                        else:
                            waiting[(chan, s)] = pay
                    else:
                        assert (chan, s) not in waiting, f"slave {s}: {chan}valid dropped"
                if (bvalid & bit) and (r_b & bit):
                    self.writes[s].append((aw[s], *w[s], b[s][1]))
                    aw[s] = w[s] = b[s] = None
                if (rvalid & bit) and (r_r & bit):
                    self.reads[s].append((ar[s], r[s][1], r[s][2]))
                    ar[s] = r[s] = None


def random_address(rng) -> int:
    kind = rng.random()
    if kind < 0.75:
        base, mask = rng.choice(REGIONS)
        size = (~mask & 0xFFFF_FFFF) + 1
        off = rng.choice([0, size - 4, rng.randrange(size) & ~3])
        return base + off
    # Unmapped: just past a region, RAM aliases, holes between regions, the top of memory.
    return rng.choice(
        [
            0x0001_0000,
            0x0002_0000 + rng.randrange(0x1000) * 4,
            0x1080_0000,
            0x2000_1000,
            0x3000_0000,
            0xFFFF_FFFC,
            0x0FFF_FFFC,
        ]
    )


@cocotb.test()
async def test_random_traffic(dut):
    rng = seeded_rng(dut, "interconnect")
    master = AxilMaster(dut, rng, pin_in="i_s_", pin_out="o_s_")
    bank = SlaveBank(dut, rng)
    await start_clock_and_reset(dut)
    cocotb.start_soon(bank.run())
    expect_w = [[] for _ in range(NS)]
    expect_r = [[] for _ in range(NS)]
    results_w, results_r = [], []
    decerr = {"w": 0, "r": 0}

    async def writer():
        for _ in range(300):
            addr = random_address(rng)
            data, strb = rng.getrandbits(32), rng.getrandbits(4)
            resp = await master.write(addr, data, strb)
            s = owner(addr)
            if s is None:
                assert resp == DECERR, f"write {addr:#010x}: resp {resp}, want DECERR"
                decerr["w"] += 1
            else:
                expect_w[s].append((addr, data, strb))
                results_w.append((s, resp))

    async def reader():
        for _ in range(300):
            addr = random_address(rng)
            data, resp = await master.read(addr)
            s = owner(addr)
            if s is None:
                assert (data, resp) == (0, DECERR), f"read {addr:#010x}: {data:#x} {resp}"
                decerr["r"] += 1
            else:
                expect_r[s].append(addr)
                results_r.append((s, data, resp))

    tw, tr = cocotb.start_soon(writer()), cocotb.start_soon(reader())
    await tw
    await tr
    for s in range(NS):
        got_w = [(a, d, st) for a, d, st, _ in bank.writes[s]]
        assert got_w == expect_w[s], f"slave {s}: writes seen differ from the writes routed to it"
        got_r = [a for a, _, _ in bank.reads[s]]
        assert got_r == expect_r[s], f"slave {s}: reads seen differ from the reads routed to it"
    # Responses: the k-th response from slave s goes to the k-th transaction routed to s.
    for s in range(NS):
        want = [resp for _, _, _, resp in bank.writes[s]]
        assert [resp for t, resp in results_w if t == s] == want, f"slave {s}: write responses"
        want_r = [(d, resp) for _, d, resp in bank.reads[s]]
        assert [(d, resp) for t, d, resp in results_r if t == s] == want_r, f"slave {s}: reads"
    assert decerr["w"] > 10 and decerr["r"] > 10, f"too few unmapped accesses: {decerr}"
    assert all(len(bank.writes[s]) > 20 and len(bank.reads[s]) > 20 for s in range(NS))


@cocotb.test()
async def test_one_outstanding(dut):
    rng = seeded_rng(dut, "outstanding")
    AxilMaster(dut, rng, pin_in="i_s_", pin_out="o_s_")  # drives the master inputs to 0
    for name in ("bresp", "rdata", "rresp"):
        getattr(dut, f"i_m_{name}").value = 0
    dut.i_m_awready.value = dut.i_m_wready.value = dut.i_m_arready.value = (1 << NS) - 1
    dut.i_m_bvalid.value = dut.i_m_rvalid.value = 0
    await start_clock_and_reset(dut)

    # W before AW: W waits (not accepted, not forwarded) until its address is valid.
    await FallingEdge(dut.clk)
    dut.i_s_wvalid.value, dut.i_s_wdata.value, dut.i_s_wstrb.value = 1, 0x11, 0xF
    for _ in range(3):
        await ReadOnly()
        assert not int(dut.o_s_wready.value) and not int(dut.o_m_wvalid.value), "W ran ahead"
        await FallingEdge(dut.clk)
    dut.i_s_awvalid.value, dut.i_s_awaddr.value = 1, 0x2000_0010  # GPIO, slave 2
    await ReadOnly()
    assert int(dut.o_s_awready.value) and int(dut.o_s_wready.value)
    assert int(dut.o_m_wvalid.value) == 4 and int(dut.o_m_awvalid.value) == 4
    await FallingEdge(dut.clk)
    dut.i_s_awvalid.value = dut.i_s_wvalid.value = 0
    # B is pending at slave 2 and the master does not take it: no new AW is accepted.
    dut.i_m_bvalid.value = 4
    dut.i_s_bready.value = 0
    await FallingEdge(dut.clk)
    dut.i_s_awvalid.value, dut.i_s_awaddr.value = 1, 0x0000_0020
    for _ in range(4):
        await ReadOnly()
        assert int(dut.o_s_bvalid.value), "B not forwarded"
        assert not int(dut.o_s_awready.value) and not int(dut.o_m_awvalid.value), "AW accepted"
        await FallingEdge(dut.clk)
    dut.i_s_bready.value = 1
    await ReadOnly()
    assert int(dut.o_m_bready.value) == 4
    await FallingEdge(dut.clk)
    dut.i_s_bready.value = 0
    dut.i_m_bvalid.value = 0
    await ReadOnly()
    assert int(dut.o_s_awready.value) and int(dut.o_m_awvalid.value) == 1, "next AW not routed"
    await FallingEdge(dut.clk)
    dut.i_s_awvalid.value = 0

    # Read: R pending at slave 1, not taken by the master: no new AR is accepted.
    dut.i_s_arvalid.value, dut.i_s_araddr.value = 1, 0x1040_0000
    await FallingEdge(dut.clk)
    dut.i_s_arvalid.value = 0
    dut.i_m_rvalid.value, dut.i_m_rdata.value = 2, 0xCAFE << 32
    dut.i_s_rready.value = 0
    await FallingEdge(dut.clk)
    dut.i_s_arvalid.value, dut.i_s_araddr.value = 1, 0x0000_0040
    for _ in range(4):
        await ReadOnly()
        assert int(dut.o_s_rvalid.value) and int(dut.o_s_rdata.value) == 0xCAFE
        assert not int(dut.o_s_arready.value) and not int(dut.o_m_arvalid.value), "AR accepted"
        await FallingEdge(dut.clk)
    dut.i_s_rready.value = 1
    await FallingEdge(dut.clk)
    dut.i_s_rready.value = 0
    dut.i_m_rvalid.value = 0
    await ReadOnly()
    assert int(dut.o_s_arready.value) and int(dut.o_m_arvalid.value) == 1, "next AR not routed"
    await ClockCycles(dut.clk, 2)


def params() -> dict[str, object]:
    base = sum(b << (32 * s) for s, (b, _) in enumerate(REGIONS))
    mask = sum(m << (32 * s) for s, (_, m) in enumerate(REGIONS))
    return {
        "NS": NS,
        "BASE": f"{NS * 32}'h{base:0{NS * 8}x}",
        "MASK": f"{NS * 32}'h{mask:0{NS * 8}x}",
    }


@pytest.mark.parametrize("sim", SIMULATORS)
def test_axil_interconnect(sim: str) -> None:
    sources = [RTL_DIR / "axi" / "axil_interconnect.sv"]
    args: list[str] = []
    if sim == "verilator":
        sources += [
            SVA_DIR / "valid_ready_sva.sv",
            SVA_DIR / "axil_resp_order_sva.sv",
            SVA_DIR / "axil_interconnect_bind.sv",
        ]
        args = ["--assert"]
    run_cocotb(
        sim=sim,
        toplevel="axil_interconnect",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters=params(),
        extra_build_args=args,
    )
