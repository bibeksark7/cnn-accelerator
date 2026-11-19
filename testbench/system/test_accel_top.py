"""accel_top: the whole accelerator through its CSR bus and memory port vs the golden model.

Weights, parameters and the descriptor table are preloaded from the exported init files
(model/artifacts/mem/*.hex), as on the FPGA. Images are written through the memory port, 16 at a
time (the IMG buffer's capacity), and run back to back with IMG_SEL; weights are loaded once.

Tests:
  network          the quick subset (50 images): every logit (LOGIT[i]) and RESULT bit-exact
                   vs the committed golden outputs; STATUS, BUF_WR = the number of activation
                   outputs, LAYER_CYC; for the first images also every performance counter vs an
                   independent count of the units' port activity, and the final ACT0 / ACT1
                   contents (conv2 and pool2 outputs) read back through the memory port
  memory port      every buffer written and read back (byte buffers, 64-bit WGT and PARAM),
                   address bits above a buffer's width ignored, reserved selects, not ready while
                   busy, exactly one rvalid per read
  CSR              ID, CONFIG, the descriptor window, IMG_SEL / DESC writes and START ignored
                   while busy, START ignored while a memory-port read is pending, a read
                   accepted in the START cycle returns exactly once while busy
  errors           every spec §9 error through descriptors written over the CSR bus (including
                   ARGMAX with src != LOGIT and FC with dst != LOGIT), then a clean run
  reset            reset during each layer, then a clean run without reloading anything
  saturation       (PERF_W = 12 build) every counter saturates at 2^12 - 1
Verilator runs bind every assertion (units, engine, array, buffer ownership, accel_top).
TB_IMAGES limits the network test to the first images (the Icarus run uses 2).
"""

from __future__ import annotations

import os
from dataclasses import replace
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, with_timeout

from common import accel_bus as ab
from common.bits import to_signed
from common.runner import RTL_DIR, SVA_DIR, run_cocotb, sv_string
from common.sim import start_clock_and_reset
from model import golden, hwmap, net
from model.hwmap import Descriptor as D

ARTIFACTS = Path(golden.__file__).parent / "artifacts"
MEM_DIR = ARTIFACTS / "mem"
RTL_SOURCES = sorted(RTL_DIR.rglob("*.sv"))
SVA_SOURCES = [
    SVA_DIR / name
    for name in (
        "systolic_array_if_sva.sv",
        "systolic_array_os_sva.sv",
        "systolic_array_bind.sv",
        "unit_if_sva.sv",
        "gemm_engine_impl_sva.sv",
        "gemm_engine_bind.sv",
        "pool_unit_bind.sv",
        "argmax_unit_bind.sv",
        "buf_port_mux_sva.sv",
        "accel_top_sva.sv",
        "accel_top_bind.sv",
    )
]
TB_IMAGES = int(os.environ.get("TB_IMAGES", "50"))
TB_MODE = os.environ.get("TB_MODE", "main")  # main | quick (network test only) | saturation
NUM_SLOTS = hwmap.NUM_IMAGES
IMG_SIZE = net.IMG_SIZE
RUN_TIMEOUT_US = 5000  # hang guard for one inference (about 50k cycles at 10 ns)


def hex_words(name: str) -> list[int]:
    return [int(x, 16) for x in (MEM_DIR / name).read_text().split()]


WGT_WORDS, PARAM_WORDS, DESC_WORDS = (
    hex_words("wgt.hex"),
    hex_words("param.hex"),
    hex_words("desc.hex"),
)


def quick_subset() -> dict[str, np.ndarray]:
    with np.load(ARTIFACTS / "quick_subset.npz") as f:
        return {k: f[k] for k in f}


class Accel:
    def __init__(self, dut):
        self.dut = dut
        self.csr = ab.CsrMaster(dut)
        self.mem = ab.MemMaster(dut)

    async def start(self) -> None:
        await self.csr.write(ab.CTRL, 1)

    async def run(self, img_sel: int | None = None) -> int:
        """START (after setting IMG_SEL) and wait for BUSY to fall; returns STATUS."""
        if img_sel is not None:
            await self.csr.write(ab.IMG_SEL, img_sel)
        await self.start()
        await ReadOnly()
        assert int(self.dut.o_busy.value) == 1, "START not accepted"
        await with_timeout(FallingEdge(self.dut.o_busy), RUN_TIMEOUT_US, "us")
        return await self.csr.read(ab.STATUS)

    async def logits(self) -> list[int]:
        return [to_signed(await self.csr.read(ab.LOGIT + 4 * i), 32) for i in range(10)]

    async def load_images(self, q: np.ndarray, first_slot: int = 0) -> None:
        for i, img in enumerate(q):
            base = (first_slot + i) * IMG_SIZE
            await self.mem.write_block(ab.SEL_IMG, base, img.reshape(-1).astype(np.uint8))

    async def write_desc_table(self, table: list[D]) -> None:
        words = [w for d in table for w in d.encode()]
        words += [0] * (4 * hwmap.DESC_DEPTH - len(words))
        for i, w in enumerate(words):
            await self.csr.write(ab.DESC + 4 * i, w)

    async def restore_desc_table(self) -> None:
        for i, w in enumerate(DESC_WORDS):
            await self.csr.write(ab.DESC + 4 * i, w)


async def setup(dut) -> Accel:
    acc = Accel(dut)
    await start_clock_and_reset(dut)
    return acc


class PortCounter:
    """Independent count of the units' buffer traffic while BUSY (unit ports, not the muxes)."""

    def __init__(self, dut):
        self.dut = dut
        self.rd = self.wr = self.mac = self.cycles = 0

    async def run(self):
        dut, g, p = self.dut, self.dut.u_gemm_engine, self.dut.u_pool_unit
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if not int(dut.o_busy.value):
                continue
            self.cycles += 1
            self.rd += int(g.o_src_re.value) + int(g.o_wgt_re.value) + int(g.o_prm_re.value)
            self.rd += int(p.o_src_re.value)
            self.wr += int(g.o_dst_we.value) + int(p.o_dst_we.value)
            self.mac += int(g.o_mac_active.value)


# Outputs written to ACT0/ACT1 per inference: conv1 + pool1 + conv2 + pool2 (every element once).
ACT_WRITES = sum(net.LAYER_BY_NAME[n].out_elems for n in ("conv1", "pool1", "conv2", "pool2"))


@cocotb.test(skip=TB_MODE not in ("main", "quick"))
async def test_network_quick_subset(dut):
    """Quick-subset images back to back: logits and class bit-exact; counters consistent."""
    acc = await setup(dut)
    qs = quick_subset()
    params = golden.QuantParams.load()
    n_img = min(TB_IMAGES, len(qs["q"]))
    golden_out = golden.infer(params, qs["q"][:n_img], keep=True)
    assert (golden_out["logits"] == qs["logits"][:n_img]).all(), "golden model drifted"
    detailed = min(2, n_img)  # images with per-cycle port counting and buffer read-back
    for first in range(0, n_img, NUM_SLOTS):
        batch = range(first, min(first + NUM_SLOTS, n_img))
        await acc.load_images(qs["q"][batch.start : batch.stop])
        for i in batch:
            counter = PortCounter(dut) if i < detailed else None
            task = cocotb.start_soon(counter.run()) if counter else None
            status = await acc.run(img_sel=i - first)
            if task:
                task.cancel()
            assert status & 0x7 == ab.DONE, f"image {i}: STATUS {status:#x}"
            assert (status >> 8) & 0xF == 5, f"image {i}: last layer {(status >> 8) & 0xF}"
            got = await acc.logits()
            want = [int(v) for v in qs["logits"][i]]
            assert got == want, f"image {i}: logits {got}, want {want}"
            result = await acc.csr.read(ab.RESULT)
            assert result == int(qs["pred"][i]), f"image {i}: RESULT {result}, want {qs['pred'][i]}"
            perf = {
                n: await acc.csr.read(a)
                for n, a in (
                    ("total", ab.CYC_TOTAL), ("mac", ab.CYC_MAC),
                    ("rd", ab.BUF_RD), ("wr", ab.BUF_WR),
                )
            }  # fmt: skip
            layers = [await acc.csr.read(ab.LAYER_CYC + 4 * k) for k in range(hwmap.DESC_DEPTH)]
            assert perf["wr"] == ACT_WRITES, f"image {i}: BUF_WR {perf['wr']} != {ACT_WRITES}"
            assert int(dut.o_cyc_total.value) == perf["total"]
            assert all(layers[:6]) and not any(layers[6:]), f"image {i}: LAYER_CYC {layers}"
            assert sum(layers) < perf["total"], f"image {i}: layers {sum(layers)} >= total"
            if counter:
                seen = {"total": counter.cycles, "mac": counter.mac, "rd": counter.rd}
                seen["wr"] = counter.wr
                assert perf == seen, f"image {i}: counters {perf}, unit ports {seen}"
                await check_final_activations(acc, golden_out, i)
            if i == 0:
                dut._log.info("image 0: counters %s, LAYER_CYC %s", perf, layers)
        dut._log.info("images %d-%d: logits and RESULT match", batch.start, batch.stop - 1)
    dut._log.info("%d images: logits and RESULT bit-exact vs the golden model", n_img)


async def check_final_activations(acc: Accel, gold: dict, i: int) -> None:
    """After the run ACT0 holds conv2's output and ACT1 pool2's (the last writes to each)."""
    for sel, name in ((ab.SEL_ACT0, "conv2"), (ab.SEL_ACT1, "pool2")):
        want = gold[name][i].reshape(-1).astype(np.int64)
        got = [to_signed(await acc.mem.read(sel, a), 8) for a in range(len(want))]
        bad = [a for a in range(len(want)) if got[a] != want[a]]
        assert not bad, f"image {i}: {name} in buffer {sel} differs at {bad[:8]}"


@cocotb.test(skip=TB_MODE != "main")
async def test_memory_port(dut):
    """Write and read back every buffer; reserved selects; high address bits; busy blocks it."""
    acc = await setup(dut)
    rng = np.random.default_rng(7)
    widths = {ab.SEL_IMG: 14, ab.SEL_ACT0: 13, ab.SEL_ACT1: 13, ab.SEL_WGT: 10, ab.SEL_PARAM: 6}
    bits = {ab.SEL_IMG: 8, ab.SEL_ACT0: 8, ab.SEL_ACT1: 8, ab.SEL_WGT: 64, ab.SEL_PARAM: 64}
    for sel, aw in widths.items():
        addrs = sorted({int(a) for a in rng.integers(0, 1 << aw, 24)} | {0, (1 << aw) - 1})
        data = {a: int(rng.integers(0, 1 << 63)) * 2 + int(rng.integers(0, 2)) for a in addrs}
        for a in addrs:  # upper address bits set: they must be ignored
            await acc.mem.write(sel, a | (0xFFFF << aw) & 0xFFFF, data[a])
        for a in addrs:
            got = await acc.mem.read(sel, a)
            want = data[a] & ((1 << bits[sel]) - 1)
            assert got == want, f"sel {sel} addr {a}: read {got:#x}, want {want:#x}"
    # Reserved selects: writes go nowhere, reads return 0 (with one rvalid each).
    before = [await acc.mem.read(ab.SEL_WGT, a) for a in range(4)]
    for sel in (5, 6, 7):
        await acc.mem.write(sel, 1, 0xFFFF_FFFF_FFFF_FFFF)
        assert await acc.mem.read(sel, 1) == 0
    assert [await acc.mem.read(ab.SEL_WGT, a) for a in range(4)] == before
    # Restore the weights and parameters the test overwrote, then run one image while hammering
    # the memory port: it must not accept anything while BUSY.
    for a, w in enumerate(WGT_WORDS):
        await acc.mem.write(ab.SEL_WGT, a, w)
    for a, w in enumerate(PARAM_WORDS):
        await acc.mem.write(ab.SEL_PARAM, a, w)
    qs = quick_subset()
    await acc.load_images(qs["q"][:1])
    await acc.csr.write(ab.IMG_SEL, 0)
    await acc.start()
    accepted_while_busy = 0
    dut.i_mem_valid.value, dut.i_mem_we.value, dut.i_mem_sel.value = 1, 1, ab.SEL_ACT0
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        if not int(dut.o_busy.value):
            break
        accepted_while_busy += int(dut.o_mem_ready.value)
    await FallingEdge(dut.clk)
    dut.i_mem_valid.value = 0
    assert accepted_while_busy == 0, f"{accepted_while_busy} requests accepted while busy"
    assert await acc.logits() == [int(v) for v in qs["logits"][0]]


@cocotb.test(skip=TB_MODE != "main")
async def test_csr_rules(dut):
    """Register identity, descriptor window, and the writes and STARTs that must be ignored."""
    acc = await setup(dut)
    csr = acc.csr
    assert await csr.read(ab.ID) == 0x434E4E31
    assert await csr.read(ab.CONFIG) == 8 | 8 << 8 | 32 << 16 | hwmap.DESC_DEPTH << 24
    assert [await csr.read(ab.DESC + 4 * w) for w in range(len(DESC_WORDS))] == DESC_WORDS
    assert await csr.read(ab.STATUS) == 0
    qs = quick_subset()
    await acc.load_images(qs["q"][:2])
    # During a run: IMG_SEL and DESC writes are ignored, extra STARTs are ignored.
    await csr.write(ab.IMG_SEL, 0)
    await acc.start()
    await csr.write(ab.IMG_SEL, 1)
    await csr.write(ab.DESC + 4 * 9, 0xDEAD_BEEF)
    for _ in range(5):
        await csr.write(ab.CTRL, 1)
    desc_during_run = await csr.read(ab.DESC + 4 * 8)  # readable while busy
    await with_timeout(FallingEdge(dut.o_busy), RUN_TIMEOUT_US, "us")
    assert desc_during_run == DESC_WORDS[8]
    assert await csr.read(ab.IMG_SEL) == 0, "IMG_SEL written while busy"
    assert await csr.read(ab.DESC + 4 * 9) == DESC_WORDS[9], "DESC written while busy"
    assert await csr.read(ab.STATUS) == ab.DONE | 5 << 8
    assert await acc.logits() == [int(v) for v in qs["logits"][0]]
    # START in the cycle after a memory-port read was accepted (read pending): ignored.
    await FallingEdge(dut.clk)
    dut.i_mem_valid.value, dut.i_mem_we.value, dut.i_mem_sel.value = 1, 0, ab.SEL_IMG
    await ReadOnly()
    assert int(dut.o_mem_ready.value)
    await FallingEdge(dut.clk)
    dut.i_mem_valid.value = 0
    dut.i_csr_valid.value, dut.i_csr_we.value = 1, 1
    dut.i_csr_addr.value, dut.i_csr_wdata.value = ab.CTRL, 1
    await ReadOnly()
    assert int(dut.o_mem_rvalid.value) and int(dut.o_csr_ready.value), "test timing is off"
    await FallingEdge(dut.clk)
    dut.i_csr_valid.value = 0
    await ReadOnly()
    assert int(dut.o_busy.value) == 0, "START accepted while a memory-port read was pending"
    # The next START works and IMG_SEL = 1 selects the second image.
    assert await acc.run(img_sel=1) == ab.DONE | 5 << 8
    assert await acc.logits() == [int(v) for v in qs["logits"][1]]
    # A memory-port read accepted in the same cycle as START (spec §10.3, D-016): both are
    # accepted, the read returns its data exactly once while BUSY is already high, and the run
    # is unaffected.
    await acc.csr.write(ab.IMG_SEL, 0)
    addr = IMG_SIZE + 100
    want = await acc.mem.read(ab.SEL_IMG, addr)
    await FallingEdge(dut.clk)
    dut.i_mem_valid.value, dut.i_mem_we.value = 1, 0
    dut.i_mem_sel.value, dut.i_mem_addr.value = ab.SEL_IMG, addr
    dut.i_csr_valid.value, dut.i_csr_we.value = 1, 1
    dut.i_csr_addr.value, dut.i_csr_wdata.value = ab.CTRL, 1
    await ReadOnly()
    both = int(dut.o_mem_ready.value) and int(dut.o_csr_ready.value)
    assert both and not int(dut.o_busy.value), "read and START not offered in one idle cycle"
    await FallingEdge(dut.clk)
    dut.i_mem_valid.value = dut.i_csr_valid.value = 0
    rvalids = []
    for _ in range(20):
        await ReadOnly()
        assert int(dut.o_busy.value), "START accepted with the read was not taken"
        if int(dut.o_mem_rvalid.value):
            rvalids.append(int(dut.o_mem_rdata.value))
        await FallingEdge(dut.clk)
    assert rvalids == [want], f"read in the START cycle returned {rvalids}, want [{want}]"
    await with_timeout(FallingEdge(dut.o_busy), RUN_TIMEOUT_US, "us")
    assert await csr.read(ab.STATUS) == ab.DONE | 5 << 8
    assert await acc.logits() == [int(v) for v in qs["logits"][0]]


def network_table() -> list[D]:
    return [D.decode(DESC_WORDS[4 * i : 4 * i + 4]) for i in range(hwmap.DESC_DEPTH)]


@cocotb.test(skip=TB_MODE != "main")
async def test_errors(dut):
    """Each §9 error stops the run at its layer with ERROR = DONE = 1; then a clean run."""
    acc = await setup(dut)
    qs = quick_subset()
    await acc.load_images(qs["q"][:1])
    table0 = network_table()
    cases = [
        ("reserved op", 2, replace(table0[2], op=5)),
        ("CONV dst = IMG", 2, replace(table0[2], dst=hwmap.BUF_IMG)),
        ("POOL dst = IMG", 1, replace(table0[1], dst=hwmap.BUF_IMG)),
        ("FC src = dst = LOGIT", 4, replace(table0[4], src=hwmap.BUF_LOGIT)),
        ("POOL src = dst", 3, replace(table0[3], dst=hwmap.BUF_ACT0)),
        ("CONV src = LOGIT", 2, replace(table0[2], src=hwmap.BUF_LOGIT)),
        ("CONV dst = LOGIT", 0, replace(table0[0], dst=hwmap.BUF_LOGIT)),
        ("POOL src = LOGIT", 3, replace(table0[3], src=hwmap.BUF_LOGIT)),
        ("POOL dst = LOGIT", 1, replace(table0[1], dst=hwmap.BUF_LOGIT)),
        ("FC src = LOGIT", 4, replace(table0[4], src=hwmap.BUF_LOGIT, dst=hwmap.BUF_ACT1)),
        ("FC dst = ACT0", 4, replace(table0[4], dst=hwmap.BUF_ACT0)),
        ("FC dst = ACT1", 4, replace(table0[4], src=hwmap.BUF_ACT0, dst=hwmap.BUF_ACT1)),
        ("FC dst = IMG", 4, replace(table0[4], dst=hwmap.BUF_IMG)),
        ("ARGMAX src = IMG", 5, replace(table0[5], src=hwmap.BUF_IMG)),
        ("ARGMAX src = ACT0", 5, replace(table0[5], src=hwmap.BUF_ACT0)),
        ("ARGMAX src = ACT1", 5, replace(table0[5], src=hwmap.BUF_ACT1)),
    ]
    for what, layer, bad in cases:
        assert hwmap.descriptor_error(bad), f"test bug: {what} is legal"
        table = [*table0[:layer], bad, *table0[layer + 1 :]]
        await acc.write_desc_table(table)
        status = await acc.run(img_sel=0)
        want = ab.DONE | ab.ERROR | layer << 8
        assert status == want, f"{what}: STATUS {status:#x}, want {want:#x}"
        layers = [await acc.csr.read(ab.LAYER_CYC + 4 * k) for k in range(hwmap.DESC_DEPTH)]
        assert all(layers[:layer]) and not any(layers[layer:]), f"{what}: LAYER_CYC {layers}"
    # Missing last: every descriptor is a (cheap) ARGMAX without last.
    argmax = replace(table0[5], last=0)
    await acc.write_desc_table([argmax] * hwmap.DESC_DEPTH)
    status = await acc.run(img_sel=0)
    want = ab.DONE | ab.ERROR | (hwmap.DESC_DEPTH - 1) << 8
    assert status == want, f"missing last: STATUS {status:#x}, want {want:#x}"
    await acc.restore_desc_table()
    assert await acc.run(img_sel=0) == ab.DONE | 5 << 8
    assert await acc.logits() == [int(v) for v in qs["logits"][0]]


@cocotb.test(skip=TB_MODE != "main")
async def test_reset_mid_run(dut):
    """Reset during each layer: idle, CSRs reset, buffers and descriptors kept; clean run after."""
    acc = await setup(dut)
    qs = quick_subset()
    await acc.load_images(qs["q"][:1])
    for layer in range(6):
        await acc.csr.write(ab.IMG_SEL, 0)
        await acc.start()
        seq = dut.u_layer_seq
        while True:  # wait for the sequencer to start this layer's unit
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(seq.o_layer_start.value) and int(seq.o_layer.value) == layer:
                break
        for _ in range(5):
            await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.rst.value = 1
        await FallingEdge(dut.clk)
        dut.rst.value = 0
        assert await acc.csr.read(ab.STATUS) == 0, f"STATUS after reset in layer {layer}"
        assert await acc.csr.read(ab.CYC_TOTAL) == 0
        assert await acc.run(img_sel=0) == ab.DONE | 5 << 8, f"run after reset in layer {layer}"
        assert await acc.logits() == [int(v) for v in qs["logits"][0]]
        dut._log.info("reset during layer %d, then a clean run: ok", layer)


@cocotb.test(skip=TB_MODE != "saturation")
async def test_counter_saturation(dut):
    """PERF_W = 12: one inference overflows 12 bits, so the counters stop at 4095."""
    acc = await setup(dut)
    qs = quick_subset()
    await acc.load_images(qs["q"][:1])
    assert await acc.run(img_sel=0) == ab.DONE | 5 << 8
    top = (1 << 12) - 1
    for name, addr in (("CYC_TOTAL", ab.CYC_TOTAL), ("BUF_RD", ab.BUF_RD), ("BUF_WR", ab.BUF_WR)):
        assert await acc.csr.read(addr) == top, f"{name} did not saturate"
    layers = [await acc.csr.read(ab.LAYER_CYC + 4 * k) for k in range(6)]
    assert layers[0] == top and layers[2] == top, f"conv LAYER_CYC did not saturate: {layers}"
    assert int(dut.o_cyc_total.value) == top
    assert await acc.logits() == [int(v) for v in qs["logits"][0]], "saturation changed results"


CONFIGS = [  # (simulator, mode, images)
    ("verilator", "main", 50),
    ("verilator", "saturation", 1),
    ("icarus", "quick", 2),
]


@pytest.mark.parametrize(("sim", "mode", "images"), CONFIGS)
def test_accel_top(sim: str, mode: str, images: int) -> None:
    params = {
        "WGT_INIT": sv_string(MEM_DIR / "wgt.hex"),
        "PARAM_INIT": sv_string(MEM_DIR / "param.hex"),
        "DESC_INIT": sv_string(MEM_DIR / "desc.hex"),
    }
    if mode == "saturation":
        params["PERF_W"] = 12
    sources = RTL_SOURCES + (SVA_SOURCES if sim == "verilator" else [])
    run_cocotb(
        sim=sim,
        toplevel="accel_top",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters=params,
        extra_build_args=["--assert"] if sim == "verilator" else [],
        extra_env={"TB_IMAGES": str(images), "TB_MODE": mode},
    )
