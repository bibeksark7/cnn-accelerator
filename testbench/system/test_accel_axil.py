"""accel_axil_slave + accel_top (spec §13.4) on Verilator, with every accel_top assertion and the
AXI4-Lite port assertions bound (the slave is accel_top's CSR and memory-port master here).

  test_csr_window        ID, CONFIG, IMG_SEL and DESC through the CSR window; unmapped CSR
                         offsets read 0; the hole above the 4 KB CSR window gets DECERR (reads 0,
                         writes change nothing); partial-strobe writes get SLVERR and are not
                         performed (CTRL with a partial strobe starts nothing)
  test_buffer_window     every buffer through the window: byte buffers one low-half write per
                         byte (high half reads 0); WGT and PARAM words as high half then low half;
                         WHI cleared by each low-half write, untouched by reads, its address
                         ignored; reserved selects (writes ignored, reads 0, OKAY); address bits
                         [1:0] ignored; word addresses wrap at the buffer depth; partial writes
                         SLVERR and not performed (a partial high-half write leaves WHI alone)
  test_poll_during_run   quick-subset images uploaded through the window and run: every logit and
                         RESULT equal the golden model's; throughout each run, CSR reads (STATUS,
                         counters, RESULT, IMG_SEL, a LOGIT, a LAYER_CYC and a DESC word) and an
                         IMG_SEL write keep completing within POLL_BOUND cycles (never held for
                         the run), the polls see BUSY, and the run lasts far longer than the bound
  test_buffer_waits      a buffer-window read and a write issued during a run complete only after
                         BUSY falls, the write is then performed, and both get OKAY
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import numpy as np
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

from common import accel_bus as ab
from common.axil import DECERR, OKAY, SLVERR, AxilMaster, Timing
from common.bits import to_signed
from common.runner import RTL_DIR, SVA_DIR, run_cocotb, sv_string
from common.sim import CLK_PERIOD_NS, seeded_rng, start_clock_and_reset
from common.soc_map import buf_offset
from model import golden, hwmap, net
from system.test_accel_top import SVA_SOURCES, quick_subset

MEM_DIR = Path(golden.__file__).parent / "artifacts" / "mem"
TB_DIR = Path(__file__).resolve().parents[1]
POLL_BOUND = 32  # cycles: a generous upper bound for one register access, not an expected value
RUN_GUARD = 200_000  # cycles: hang guard for one run
IMG_SIZE = net.IMG_SIZE
DEPTHS = {
    ab.SEL_IMG: 16384,
    ab.SEL_ACT0: 8192,
    ab.SEL_ACT1: 8192,
    ab.SEL_WGT: 1024,
    ab.SEL_PARAM: 64,
}


def hex_words(name: str) -> list[int]:
    return [int(x, 16) for x in (MEM_DIR / name).read_text().split()]


class Bus:
    """The accelerator region through AXI: CSR reads/writes and buffer words."""

    def __init__(self, dut, rng, timing: Timing | None = None):
        self.m = AxilMaster(dut, rng, timing=timing)

    async def csr_read(self, off: int) -> int:
        return await self.m.read_ok(off)

    async def csr_write(self, off: int, value: int) -> None:
        await self.m.write_ok(off, value)

    async def buf_write(self, sel: int, word: int, value: int) -> None:
        """One buffer word: high half (if any bits there) then low half."""
        if sel in (ab.SEL_WGT, ab.SEL_PARAM):
            await self.m.write_ok(buf_offset(sel, word, 1), value >> 32)
        await self.m.write_ok(buf_offset(sel, word, 0), value & 0xFFFF_FFFF)

    async def buf_read(self, sel: int, word: int) -> int:
        lo = await self.m.read_ok(buf_offset(sel, word, 0))
        hi = await self.m.read_ok(buf_offset(sel, word, 1))
        return hi << 32 | lo

    async def upload_image(self, slot: int, q: np.ndarray) -> None:
        for i, b in enumerate(q.reshape(-1)):
            await self.m.write_ok(buf_offset(ab.SEL_IMG, slot * IMG_SIZE + i), int(b) & 0xFF)


async def setup(dut, name: str, timing: Timing | None = None) -> Bus:
    rng = seeded_rng(dut, name)
    bus = Bus(dut, rng, timing)
    await start_clock_and_reset(dut)
    return bus


@cocotb.test()
async def test_csr_window(dut):
    bus = await setup(dut, "csr_window")
    m = bus.m
    assert await bus.csr_read(ab.ID) == 0x434E4E31
    cfg = await bus.csr_read(ab.CONFIG)
    assert cfg == 8 | 8 << 8 | 32 << 16 | hwmap.DESC_DEPTH << 24, f"CONFIG {cfg:#x}"
    await bus.csr_write(ab.IMG_SEL, 5)
    assert await bus.csr_read(ab.IMG_SEL) == 5
    assert await bus.csr_read(0x00C) == 0, "unmapped CSR offset"
    assert await bus.csr_read(ab.IMG_SEL | 3) == 5, "address bits [1:0] not ignored"
    # DESC words through the window (restored afterwards).
    desc = hex_words("desc.hex")
    for i in range(4):
        assert await bus.csr_read(ab.DESC + 4 * i) == desc[i]
    await bus.csr_write(ab.DESC + 4 * 31, 0xA5A5_0001)
    assert await bus.csr_read(ab.DESC + 4 * 31) == 0xA5A5_0001
    await bus.csr_write(ab.DESC + 4 * 31, desc[31])
    # The hole above the 4 KB CSR window: DECERR, nothing accessed.
    for off in (0x00_1000, 0x00_1014, 0x20_0000, 0x3F_FFFC):
        data, resp = await m.read(off)
        assert (data, resp) == (0, DECERR), f"hole {off:#x}: {data:#x} {resp}"
        assert await m.write(off, 0xFFFF_FFFF) == DECERR
        assert await m.write(off | ab.IMG_SEL, 0) == DECERR
    assert await bus.csr_read(ab.IMG_SEL) == 5, "a hole write reached IMG_SEL"
    # Partial strobes: SLVERR, not performed.
    for strb in (0x0, 0x1, 0x7, 0xE):
        assert await m.write(ab.IMG_SEL, 9, strb) == SLVERR
        assert await m.write(ab.CTRL, 1, strb) == SLVERR
    assert await bus.csr_read(ab.IMG_SEL) == 5, "a partial write changed IMG_SEL"
    await ReadOnly()
    assert int(dut.o_busy.value) == 0, "a partial CTRL write started a run"
    status = await bus.csr_read(ab.STATUS)
    assert status & (ab.BUSY | ab.DONE) == 0, f"STATUS {status:#x}"


@cocotb.test()
async def test_buffer_window(dut):
    bus = await setup(dut, "buffer_window")
    m, rng = bus.m, bus.m.rng
    wgt, prm = hex_words("wgt.hex"), hex_words("param.hex")
    # Byte buffers: one low-half write per byte; high half reads 0.
    for sel in (ab.SEL_IMG, ab.SEL_ACT0, ab.SEL_ACT1):
        model = {}
        for _ in range(40):
            word = rng.choice([0, DEPTHS[sel] - 1, rng.randrange(DEPTHS[sel])])
            v = rng.getrandbits(32)
            await m.write_ok(buf_offset(sel, word, 0) | rng.getrandbits(2), v)
            model[word] = v & 0xFF
        for word, b in model.items():
            assert await bus.buf_read(sel, word) == b, f"sel {sel} word {word}"
        # Word addresses wrap at the depth (bits above the buffer's width are ignored).
        word = rng.randrange(DEPTHS[sel])
        await m.write_ok(buf_offset(sel, word + DEPTHS[sel]), 0x5A)
        assert await bus.buf_read(sel, word) == 0x5A, f"sel {sel}: no wrap at the depth"
    # 64-bit buffers: high then low; WHI cleared by the low write; reads leave WHI alone.
    for sel, init in ((ab.SEL_WGT, wgt), (ab.SEL_PARAM, prm)):
        model = list(init[: DEPTHS[sel]])  # words beyond the init file are not checked
        for _ in range(20):
            word = rng.randrange(len(model))
            v = rng.getrandbits(64)
            await bus.buf_write(sel, word, v)
            model[word] = v
            assert await bus.buf_read(sel, word) == v
        for word, v in enumerate(model):
            assert await bus.buf_read(sel, word) == v, f"sel {sel} word {word}"
        word = 3
        await m.write_ok(buf_offset(sel, word, 0), 0x1111_2222)  # WHI is 0 after the last low write
        assert await bus.buf_read(sel, word) == 0x1111_2222, "WHI not cleared by the low write"
        await m.write_ok(buf_offset(sel, 20, 1), 0xABCD_0123)  # high half of another word
        assert await bus.buf_read(sel, 20) == model[20], "a high-half write touched a buffer"
        await m.write_ok(buf_offset(sel, word, 0), 0x3333_4444)  # commits with the staged WHI
        assert await bus.buf_read(sel, word) == 0xABCD_0123_3333_4444, "WHI's address not ignored"
        # Partial writes: SLVERR, not performed; a partial high write leaves WHI alone.
        await m.write_ok(buf_offset(sel, word, 1), 0x5555_6666)
        assert await m.write(buf_offset(sel, word, 1), 0xFFFF_FFFF, 0x3) == SLVERR
        assert await m.write(buf_offset(sel, word, 0), 0xFFFF_FFFF, 0xE) == SLVERR
        assert await bus.buf_read(sel, word) == 0xABCD_0123_3333_4444, "partial write performed"
        await m.write_ok(buf_offset(sel, word, 0), 0x7777_8888)
        assert await bus.buf_read(sel, word) == 0x5555_6666_7777_8888, "partial write changed WHI"
    # Restore every WGT and PARAM word (later tests run the network).
    for sel, init in ((ab.SEL_WGT, wgt), (ab.SEL_PARAM, prm)):
        for w, v in enumerate(init):
            await bus.buf_write(sel, w, v)
    # Reserved selects: writes ignored, reads 0, OKAY.
    for sel in (5, 6, 7):
        assert await m.write(buf_offset(sel, 1, 0), 0xFFFF_FFFF) == OKAY
        assert await m.read(buf_offset(sel, 1, 0)) == (0, OKAY)
        assert await m.read(buf_offset(sel, 1, 1)) == (0, OKAY)


async def busy_edges(dut, falls: list[float]) -> None:
    while True:
        await FallingEdge(dut.o_busy)
        falls.append(get_sim_time(unit="ns"))


@cocotb.test()
async def test_poll_during_run(dut):
    bus = await setup(dut, "poll", Timing(max_skew=0, max_ready_delay=0, ready_early=1.0))
    qs = quick_subset()
    n_images = 3
    for slot in range(n_images):
        await bus.upload_image(slot, qs["q"][slot])
    polled = [
        ab.STATUS,
        ab.CYC_TOTAL,
        ab.CYC_MAC,
        ab.RESULT,
        ab.IMG_SEL,
        ab.LOGIT + 12,
        ab.LAYER_CYC + 8,
        ab.DESC + 4,
    ]
    for slot in range(n_images):
        await bus.csr_write(ab.IMG_SEL, slot)
        await bus.csr_write(ab.CTRL, 1)
        worst, polls, saw_busy = 0, 0, 0
        for i in range(RUN_GUARD):
            off = polled[i % len(polled)]
            t0 = get_sim_time(unit="ns")
            if i % 50 == 25:
                await bus.csr_write(ab.IMG_SEL, 15)  # ignored while busy, but never held
            else:
                value = await bus.csr_read(off)
            worst = max(worst, round((get_sim_time(unit="ns") - t0) / CLK_PERIOD_NS))
            polls += 1
            if off == ab.STATUS and i % 50 != 25:
                if value & ab.BUSY:
                    saw_busy += 1
                elif value & ab.DONE:
                    break
        else:
            raise TimeoutError("run never finished")
        assert value & ab.ERROR == 0, f"STATUS {value:#x}"
        cycles = await bus.csr_read(ab.CYC_TOTAL)
        assert worst <= POLL_BOUND, f"a register access took {worst} cycles during a run"
        assert saw_busy > 100 and cycles > 100 * POLL_BOUND, (saw_busy, cycles)
        assert await bus.csr_read(ab.IMG_SEL) == slot, "IMG_SEL changed while busy"
        logits = [to_signed(await bus.csr_read(ab.LOGIT + 4 * k), 32) for k in range(10)]
        want = [int(x) for x in qs["logits"][slot]]
        assert logits == want, f"image {slot}: logits {logits}, golden {want}"
        assert await bus.csr_read(ab.RESULT) == int(qs["pred"][slot])
        dut._log.info(
            "image %d: %d register accesses during a %d-cycle run, worst %d cycles",
            slot,
            polls,
            cycles,
            worst,
        )


@cocotb.test()
async def test_buffer_waits(dut):
    bus = await setup(dut, "buffer_waits")
    m = bus.m
    falls: list[float] = []
    cocotb.start_soon(busy_edges(dut, falls))
    wgt = hex_words("wgt.hex")
    # A read during a run.
    await bus.csr_write(ab.IMG_SEL, 0)
    await bus.csr_write(ab.CTRL, 1)
    await ReadOnly()
    assert int(dut.o_busy.value) == 1
    t0 = get_sim_time(unit="ns")
    lo = await m.read_ok(buf_offset(ab.SEL_WGT, 0, 0))
    t1 = get_sim_time(unit="ns")
    assert falls and t0 < falls[-1] < t1, "the buffer read completed before the run ended"
    assert lo == wgt[0] & 0xFFFF_FFFF
    # A write during a run: waits, then is performed.
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    await bus.csr_write(ab.CTRL, 1)
    await ReadOnly()
    assert int(dut.o_busy.value) == 1
    n = len(falls)
    await m.write_ok(buf_offset(ab.SEL_IMG, 15 * IMG_SIZE + 3, 0), 0x77)
    assert len(falls) == n + 1, "the buffer write completed before the run ended"
    assert await m.read_ok(buf_offset(ab.SEL_IMG, 15 * IMG_SIZE + 3, 0)) == 0x77


def test_accel_axil() -> None:
    sources = [
        *sorted(RTL_DIR.rglob("*.sv")),
        TB_DIR / "hdl" / "accel_axil_tb.sv",
        *SVA_SOURCES,
        SVA_DIR / "axil_resp_order_sva.sv",
        SVA_DIR / "req_rsp_sva.sv",
        SVA_DIR / "axil_slave_port_bind.sv",
    ]
    run_cocotb(
        sim="verilator",
        toplevel="accel_axil_tb",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={
            "WGT_INIT": sv_string(MEM_DIR / "wgt.hex"),
            "PARAM_INIT": sv_string(MEM_DIR / "param.hex"),
            "DESC_INIT": sv_string(MEM_DIR / "desc.hex"),
        },
        extra_build_args=["--assert"],
    )
