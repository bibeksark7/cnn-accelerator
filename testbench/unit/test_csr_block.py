"""csr_block: CSR bus and register map (spec §10.1, §10.2).

Status, result, performance-counter and LOGIT inputs are driven with random values; the
descriptor table is a Python 1-cycle-latency RAM model, and its read grant (the sequencer not
reading) is randomly withheld. Checked: every register and its decode, address bits [1:0]
ignored, unmapped and out-of-range addresses read 0 and ignore writes, START pulses, IMG_SEL and
DESC writes ignored while busy, register reads answered without wait states, descriptor reads
only through a granted RAM read, and a withdrawn descriptor read leaving nothing pending.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common import accel_bus as ab
from common.runner import RTL_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

SOURCES = [RTL_DIR / "ctrl" / "csr_block.sv"]


def dims(dut) -> tuple[int, int, int]:
    perf_w = len(dut.i_cyc_total)
    desc_depth = len(dut.i_layer_cyc) // perf_w
    logit_depth = 1 << len(dut.o_logit_raddr)
    return perf_w, desc_depth, logit_depth


class DescRam:
    """Descriptor table model plus random read-grant withholding and START pulse counting."""

    def __init__(self, dut, rng, words: int):
        self.dut, self.rng = dut, rng
        self.mem = [0] * words
        self.starts = 0
        self.reads = 0
        self.gnt_prob = 1.0

    async def run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            dut.i_desc_gnt.value = int(self.rng.random() < self.gnt_prob)
            await ReadOnly()
            re, ra = int(dut.o_desc_re.value), int(dut.o_desc_raddr.value)
            we, wa, wd = int(dut.o_desc_we.value), int(dut.o_desc_waddr.value), 0
            if we:
                wd = int(dut.o_desc_wdata.value)
            if re:
                assert int(dut.i_desc_gnt.value), "descriptor read issued without the grant"
            self.starts += int(dut.o_start.value)
            await RisingEdge(dut.clk)
            if re:
                self.reads += 1
                dut.i_desc_rdata.value = self.mem[ra]
            if we:
                self.mem[wa] = wd


async def setup(dut, rng) -> tuple[DescRam, ab.CsrMaster]:
    _, desc_depth, _ = dims(dut)
    csr = ab.CsrMaster(dut)  # drives the bus inputs before anything samples the outputs
    for s in (dut.i_busy, dut.i_done, dut.i_error, dut.i_layer, dut.i_result):
        s.value = 0
    for s in (dut.i_cyc_total, dut.i_cyc_mac, dut.i_buf_rd, dut.i_buf_wr, dut.i_layer_cyc):
        s.value = 0
    dut.i_logit_rdata.value = 0
    dut.i_desc_rdata.value = 0
    dut.i_desc_gnt.value = 1
    ram = DescRam(dut, rng, 4 * desc_depth)
    cocotb.start_soon(ram.run())
    await start_clock_and_reset(dut)
    return ram, csr


@cocotb.test()
async def test_register_map(dut):
    rng = seeded_rng(dut, "csr_map")
    _, csr = await setup(dut, rng)
    perf_w, desc_depth, logit_depth = dims(dut)
    n = 8
    want_config = n | (8 << 8) | (32 << 16) | (desc_depth << 24)
    assert await csr.read(ab.ID) == 0x434E4E31
    assert await csr.read(ab.CONFIG) == want_config, hex(await csr.read(ab.CONFIG))
    assert await csr.read(ab.CTRL) == 0
    for _ in range(40):
        await FallingEdge(dut.clk)
        busy, done, err = rng.randint(0, 1), rng.randint(0, 1), rng.randint(0, 1)
        layer = rng.randrange(16)
        result = rng.getrandbits(8)
        perf = [rng.getrandbits(perf_w) for _ in range(4)]
        layers = [rng.getrandbits(perf_w) for _ in range(desc_depth)]
        dut.i_busy.value, dut.i_done.value, dut.i_error.value = busy, done, err
        dut.i_layer.value, dut.i_result.value = layer, result
        for sig, v in zip(
            (dut.i_cyc_total, dut.i_cyc_mac, dut.i_buf_rd, dut.i_buf_wr), perf, strict=True
        ):
            sig.value = v
        dut.i_layer_cyc.value = sum(v << (i * perf_w) for i, v in enumerate(layers))
        low = rng.randrange(4)  # address bits [1:0] are ignored
        got, wait = await csr.read_with_wait(ab.STATUS | low)
        assert got == busy | (done << 1) | (err << 2) | (layer << 8), f"STATUS {got:#x}"
        assert wait == 0, "register read took wait states"
        assert await csr.read(ab.RESULT | low) == result
        for addr, v in zip((ab.CYC_TOTAL, ab.CYC_MAC, ab.BUF_RD, ab.BUF_WR), perf, strict=True):
            assert await csr.read(addr | low) == v, f"counter {addr:#x}"
        for i in range(16):
            got = await csr.read(ab.LAYER_CYC + 4 * i + low)
            assert got == (layers[i] if i < desc_depth else 0), f"LAYER_CYC[{i}] = {got:#x}"
    # LOGIT: the index goes to the register file, its data comes back.
    for i in range(32):
        v = rng.getrandbits(32)
        await FallingEdge(dut.clk)
        dut.i_logit_rdata.value = v
        dut.i_csr_valid.value, dut.i_csr_we.value, dut.i_csr_addr.value = 1, 0, ab.LOGIT + 4 * i
        await ReadOnly()
        if i < logit_depth:
            assert int(dut.o_logit_raddr.value) == i
            assert int(dut.o_csr_rdata.value) == v, f"LOGIT[{i}]"
        else:
            assert int(dut.o_csr_rdata.value) == 0, f"LOGIT[{i}] beyond LOGIT_DEPTH"
        await FallingEdge(dut.clk)
        dut.i_csr_valid.value = 0
    # Unmapped addresses read 0 and writes to them change nothing.
    dut.i_busy.value = 0
    mapped = {ab.ID, ab.CONFIG, ab.STATUS, ab.IMG_SEL, ab.RESULT}
    mapped |= {ab.CYC_TOTAL, ab.CYC_MAC, ab.BUF_RD, ab.BUF_WR}
    for addr in (0x008, 0x00C, 0x030, 0x034, 0x03C):
        assert addr not in mapped
        await csr.write(addr, 0xFFFF_FFFF)
        assert await csr.read(addr) == 0, f"unmapped {addr:#x}"
    assert await csr.read(ab.IMG_SEL) == 0, "an unmapped write reached IMG_SEL"


@cocotb.test()
async def test_img_sel_and_start(dut):
    rng = seeded_rng(dut, "csr_ctrl")
    ram, csr = await setup(dut, rng)
    await csr.write(ab.IMG_SEL, 0xFFFF_FFF7)
    assert await csr.read(ab.IMG_SEL) == 7, "IMG_SEL keeps bits [3:0] only"
    assert int(dut.o_img_sel.value) == 7
    dut.i_busy.value = 1
    await csr.write(ab.IMG_SEL, 3)
    assert await csr.read(ab.IMG_SEL) == 7, "IMG_SEL written while busy"
    dut.i_busy.value = 0
    await csr.write(ab.IMG_SEL, 12)
    assert await csr.read(ab.IMG_SEL) == 12
    before = ram.starts
    await csr.write(ab.CTRL, 0)
    await csr.write(ab.CTRL, 2)
    assert ram.starts == before, "START pulsed without bit 0"
    for _ in range(5):
        await csr.write(ab.CTRL | rng.randrange(4), 1)
    await FallingEdge(dut.clk)
    assert ram.starts == before + 5, f"{ram.starts - before} START pulses for 5 writes"
    assert await csr.read(ab.CTRL) == 0, "CTRL reads 0"


@cocotb.test()
async def test_descriptor_window(dut):
    rng = seeded_rng(dut, "csr_desc")
    ram, csr = await setup(dut, rng)
    _, desc_depth, _ = dims(dut)
    words = 4 * desc_depth
    model = [0] * words
    for w in range(words):
        model[w] = rng.getrandbits(32)
        await csr.write(ab.DESC + 4 * w, model[w])
    ram.gnt_prob = 0.4  # the sequencer often holds the table's read port
    waits = []
    for _ in range(200):
        w = rng.randrange(words)
        if rng.random() < 0.3:
            busy = rng.random() < 0.5
            dut.i_busy.value = int(busy)
            v = rng.getrandbits(32)
            await csr.write(ab.DESC + 4 * w + rng.randrange(4), v)
            if not busy:
                model[w] = v
        else:
            reads = ram.reads
            got, wait = await csr.read_with_wait(ab.DESC + 4 * w)
            assert got == model[w], f"DESC[{w}] = {got:#x}, want {model[w]:#x}"
            assert ram.reads == reads + 1, "descriptor read without exactly one RAM read"
            assert wait >= 1, "descriptor read answered before the RAM data"
            waits.append(wait)
    dut.i_busy.value = 0
    assert ram.mem == model, "descriptor table differs (a write while busy got through?)"
    # Beyond the table: reads 0 without touching the RAM; writes are dropped.
    for w in (words, words + 1, 0x3BF):
        reads = ram.reads
        await csr.write(ab.DESC + 4 * w, 0xDEAD_BEEF)
        assert await csr.read(ab.DESC + 4 * w) == 0
        assert ram.reads == reads
    assert ram.mem == model
    dut._log.info("descriptor read wait states: min %d, max %d", min(waits), max(waits))
    assert max(waits) > 1, "the grant was never withheld during a read"


@cocotb.test()
async def test_withdrawn_descriptor_read(dut):
    """A descriptor read withdrawn after its RAM read (a §10.1 violation) leaves nothing pending:
    the next descriptor read waits for its own RAM data instead of returning the old word."""
    rng = seeded_rng(dut, "csr_withdraw")
    ram, csr = await setup(dut, rng)
    _, desc_depth, _ = dims(dut)
    words = [rng.getrandbits(32) for _ in range(4 * desc_depth)]
    for w, v in enumerate(words):
        await csr.write(ab.DESC + 4 * w, v)
    for gap in (0, 1, 3):
        first, second = rng.sample(range(len(words)), 2)
        await FallingEdge(dut.clk)
        dut.i_csr_valid.value, dut.i_csr_we.value = 1, 0
        dut.i_csr_addr.value = ab.DESC + 4 * first
        await ReadOnly()
        assert int(dut.o_desc_re.value) and not int(dut.o_csr_ready.value), "test timing is off"
        await FallingEdge(dut.clk)
        dut.i_csr_valid.value = 0  # withdrawn after the RAM read, before the answer
        for _ in range(gap):
            await FallingEdge(dut.clk)
        reads = ram.reads
        got, wait = await csr.read_with_wait(ab.DESC + 4 * second)
        assert got == words[second], (
            f"gap {gap}: DESC[{second}] = {got:#x}, want {words[second]:#x} "
            f"(DESC[{first}] = {words[first]:#x})"
        )
        assert wait >= 1 and ram.reads == reads + 1, f"gap {gap}: answered without its own read"


@pytest.mark.parametrize(
    ("sim", "desc_depth", "logit_depth", "perf_w"),
    [("icarus", 8, 16, 32), ("icarus", 4, 8, 20), ("verilator", 8, 16, 32)],
)
def test_csr_block(sim: str, desc_depth: int, logit_depth: int, perf_w: int) -> None:
    run_cocotb(
        sim=sim,
        toplevel="csr_block",
        sources=SOURCES,
        test_module=Path(__file__).stem,
        parameters={"DESC_DEPTH": desc_depth, "LOGIT_DEPTH": logit_depth, "PERF_W": perf_w},
    )
