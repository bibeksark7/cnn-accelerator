"""gemm_engine: whole CONV / FC layers vs the golden model, through Python buffer models.

The buffer models answer the engine's read ports with exactly the 1-cycle latency of spec §5 and
record every write. A layer passes when every expected output address is written exactly once
with the golden value and nothing else is written.

Tests:
  network layers  conv1, conv2, fc with the exported weight/param images (N = 8)
  random conv/fc  random shapes (ragged C_out, M not a multiple of N), bases, ReLU on/off,
                  full int8 activations; small K_TILE builds force K chunking
Verilator runs bind the engine and array interface assertions; test_engine_sva_fires proves the
engine assertions are live.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIM_BUILD_DIR, SVA_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset, wait_until
from model import golden, hwmap

SOURCES = [
    RTL_DIR / "core" / "mac_cell.sv",
    RTL_DIR / "core" / "systolic_array.sv",
    RTL_DIR / "mem" / "sram_1r1w.sv",
    RTL_DIR / "post" / "postproc.sv",
    RTL_DIR / "addr" / "agen_a.sv",
    RTL_DIR / "core" / "gemm_engine.sv",
]
SVA_SOURCES = [
    SVA_DIR / "systolic_array_if_sva.sv",
    SVA_DIR / "systolic_array_os_sva.sv",
    SVA_DIR / "systolic_array_bind.sv",
    SVA_DIR / "gemm_engine_if_sva.sv",
    SVA_DIR / "gemm_engine_bind.sv",
]
TB_N = int(os.environ.get("TB_N", "8"))
SVA_VIOLATION = os.environ.get("SVA_VIOLATION", "")
WGT_DEPTH, PARAM_DEPTH = 1024, 64


@dataclass
class Layer:
    """One engine run: configuration, buffer contents and the expected writes."""

    fc: bool
    relu: bool
    src_base: int
    dst_base: int
    h: int
    w: int
    c_in: int
    c_out: int
    wgt_base: int
    param_base: int
    src_bytes: np.ndarray  # int8 activations, HWC flattened, placed at src_base
    wgt_words: np.ndarray  # packed B at wgt_base
    prm_words: np.ndarray  # packed params at param_base
    expected: dict[int, int] = field(default_factory=dict)  # address -> value


class Buffers:
    def __init__(self, layer: Layer):
        self.src = np.zeros(1 << 16, dtype=np.int64)
        self.src[layer.src_base : layer.src_base + len(layer.src_bytes)] = layer.src_bytes.astype(
            np.uint8
        )
        self.wgt = [0] * WGT_DEPTH
        for i, w in enumerate(layer.wgt_words):
            self.wgt[layer.wgt_base + i] = int(w)
        self.prm = [0] * PARAM_DEPTH
        for i, p in enumerate(layer.prm_words):
            self.prm[layer.param_base + i] = int(p)
        self.writes: dict[int, int] = {}
        self.duplicates: list[int] = []


async def serve(dut, buf: Buffers) -> None:
    """Synchronous-read buffers: a request seen by rising edge E returns data after E."""
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        reads = []
        for re, addr, port in (
            (dut.o_src_re, dut.o_src_addr, "src"),
            (dut.o_wgt_re, dut.o_wgt_addr, "wgt"),
            (dut.o_prm_re, dut.o_prm_addr, "prm"),
        ):
            if int(re.value):
                reads.append((port, int(addr.value)))
        for we, addr, data, width in (
            (dut.o_dst_we, dut.o_dst_addr, dut.o_dst_wdata, 8),
            (dut.o_logit_we, dut.o_logit_idx, dut.o_logit_wdata, 32),
        ):
            if int(we.value):
                a, v = int(addr.value), int(data.value)
                v = v - (1 << width) if v >> (width - 1) else v
                if a in buf.writes:
                    buf.duplicates.append(a)
                buf.writes[a] = v
        await RisingEdge(dut.clk)
        for port, addr in reads:
            if port == "src":
                dut.i_src_rdata.value = int(buf.src[addr])
            elif port == "wgt":
                dut.i_wgt_rdata.value = buf.wgt[addr]
            else:
                dut.i_prm_rdata.value = buf.prm[addr]


async def run_layer(dut, layer: Layer, timeout: int = 400_000) -> Buffers:
    buf = Buffers(layer)
    server = cocotb.start_soon(serve(dut, buf))
    await FallingEdge(dut.clk)
    dut.i_fc.value = int(layer.fc)
    dut.i_relu_en.value = int(layer.relu and not layer.fc)
    dut.i_requant_en.value = int(not layer.fc)
    dut.i_src_base.value, dut.i_dst_base.value = layer.src_base, layer.dst_base
    dut.i_h.value, dut.i_w.value = layer.h, layer.w
    dut.i_c_in.value, dut.i_c_out.value = layer.c_in, layer.c_out
    dut.i_wgt_base.value, dut.i_param_base.value = layer.wgt_base, layer.param_base
    dut.i_start.value = 1
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    await wait_until(dut, lambda: int(dut.o_done.value) == 1, timeout, "o_done")
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    server.cancel()
    assert not buf.duplicates, f"addresses written twice: {buf.duplicates[:8]}"
    extra = sorted(set(buf.writes) - set(layer.expected))
    missing = sorted(set(layer.expected) - set(buf.writes))
    assert not extra, f"unexpected writes at {extra[:8]}"
    assert not missing, f"{len(missing)} outputs never written, e.g. {missing[:8]}"
    wrong = [(a, buf.writes[a], v) for a, v in layer.expected.items() if buf.writes[a] != v]
    assert not wrong, f"{len(wrong)} wrong outputs, e.g. (addr, got, want) {wrong[:5]}"
    return buf


def conv_layer(n, src_base, dst_base, wgt_base, param_base, act, w, b, m, s, relu) -> Layer:
    y = golden.conv_layer(act[None], w, b, m, s, relu_en=relu)[0].reshape(-1)
    return Layer(
        fc=False,
        relu=relu,
        src_base=src_base,
        dst_base=dst_base,
        h=act.shape[0],
        w=act.shape[1],
        c_in=act.shape[2],
        c_out=w.shape[0],
        wgt_base=wgt_base,
        param_base=param_base,
        src_bytes=act.reshape(-1),
        wgt_words=hwmap.pack_b(golden.conv_weights_as_b(w), n=n),
        prm_words=hwmap.pack_params(b, m, s),
        expected={(dst_base + i) & 0xFFFF: int(v) for i, v in enumerate(y)},
    )


def fc_layer(n, src_base, dst_base, wgt_base, param_base, act, w, b) -> Layer:
    logits = golden.fc_layer(act[None], w, b)[0]
    return Layer(
        fc=True,
        relu=False,
        src_base=src_base,
        dst_base=dst_base,
        h=act.shape[0],
        w=act.shape[1],
        c_in=act.shape[2],
        c_out=w.shape[0],
        wgt_base=wgt_base,
        param_base=param_base,
        src_bytes=act.reshape(-1),
        wgt_words=hwmap.pack_b(w.T, n=n),
        prm_words=hwmap.pack_params(b),
        expected={(dst_base + i) & 0xFFFF: int(v) for i, v in enumerate(logits)},
    )


def n_of(dut) -> int:
    return len(dut.i_wgt_rdata) // 8


async def setup(dut) -> None:
    for sig in (dut.i_start, dut.i_src_rdata, dut.i_wgt_rdata, dut.i_prm_rdata):
        sig.value = 0
    await start_clock_and_reset(dut)


@cocotb.test(skip=TB_N != hwmap.N or SVA_VIOLATION != "")
async def test_network_layers(dut):
    """conv1, conv2 and fc with the exported memory images, inputs from the golden model."""
    await setup(dut)
    params = golden.QuantParams.load()
    mem = hwmap.build_memory_image(params)
    with np.load(Path(golden.__file__).parent / "artifacts" / "quick_subset.npz") as f:
        q = f["q"][:1]
    acts = golden.infer(params, q, keep=True)
    inputs = {"conv1": q[0][..., None], "conv2": acts["pool1"][0], "fc": acts["pool2"][0]}
    for name in ("conv1", "conv2", "fc"):
        d = mem.descriptors[mem.layout[name]["index"]]
        e = mem.layout[name]
        wgt = mem.wgt[e["wgt_base"] : e["wgt_base"] + e["wgt_words"]]
        prm = mem.param[e["param_base"] : e["param_base"] + e["param_words"]]
        act = inputs[name]
        if name == "fc":
            want = {i: int(v) for i, v in enumerate(acts["logits"][0])}
        else:
            want = {i: int(v) for i, v in enumerate(acts[name][0].reshape(-1))}
        layer = Layer(
            fc=name == "fc",
            relu=bool(d.relu_en),
            src_base=0,
            dst_base=0,
            h=d.h_in,
            w=d.w_in,
            c_in=d.c_in,
            c_out=d.c_out,
            wgt_base=e["wgt_base"],
            param_base=e["param_base"],
            src_bytes=act.reshape(-1),
            wgt_words=wgt,
            prm_words=prm,
            expected=want,
        )
        await run_layer(dut, layer)
        dut._log.info("%s: %d outputs match the golden model", name, len(want))


def rand_conv(rng, n) -> Layer:
    h, w, c_in, c_out = (
        rng.randint(3, 8),
        rng.randint(3, 8),
        rng.randint(1, 5),
        rng.randint(1, 2 * n + 3),
    )
    act = np.array([rng.randint(-128, 127) for _ in range(h * w * c_in)], dtype=np.int8)
    wt = np.array([rng.randint(-127, 127) for _ in range(c_out * 9 * c_in)], dtype=np.int8)
    b = np.array([rng.randint(-20000, 20000) for _ in range(c_out)], dtype=np.int32)
    m = np.array([rng.randint(golden.M_MIN, golden.M_MAX) for _ in range(c_out)], dtype=np.uint16)
    s = np.array([rng.randint(12, 24) for _ in range(c_out)], dtype=np.uint8)
    return conv_layer(
        n,
        rng.randrange(0, 3000),
        rng.randrange(0, 3000),
        rng.randrange(0, 200),
        rng.randrange(0, PARAM_DEPTH - c_out),
        act.reshape(h, w, c_in),
        wt.reshape(c_out, 3, 3, c_in),
        b,
        m,
        s,
        relu=rng.random() < 0.6,
    )


def rand_fc(rng, n) -> Layer:
    h, w, c_in, c_out = (
        rng.randint(1, 5),
        rng.randint(1, 5),
        rng.randint(1, 8),
        rng.randint(1, 2 * n + 3),
    )
    act = np.array([rng.randint(-128, 127) for _ in range(h * w * c_in)], dtype=np.int8)
    wt = np.array([rng.randint(-127, 127) for _ in range(c_out * h * w * c_in)], dtype=np.int8)
    b = np.array([rng.randint(-200000, 200000) for _ in range(c_out)], dtype=np.int32)
    return fc_layer(
        n,
        rng.randrange(0, 3000),
        rng.randrange(0, 3000),
        rng.randrange(0, 200),
        rng.randrange(0, PARAM_DEPTH - c_out),
        act.reshape(h, w, c_in),
        wt.reshape(c_out, h * w * c_in),
        b,
    )


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_random_layers(dut):
    """Back-to-back random CONV and FC layers, ragged tiles, random bases, ReLU on/off."""
    rng = seeded_rng(dut, "layers")
    n = n_of(dut)
    await setup(dut)
    for i in range(16):
        layer = rand_conv(rng, n) if i % 3 != 2 else rand_fc(rng, n)
        await run_layer(dut, layer)


@cocotb.test(skip=SVA_VIOLATION != "start_while_busy")
async def sva_violation_start_while_busy(dut):
    """A second i_start while a layer is running; only run by test_engine_sva_fires."""
    rng = seeded_rng(dut, "violation")
    await setup(dut)
    layer = rand_conv(rng, n_of(dut))
    cocotb.start_soon(serve(dut, Buffers(layer)))
    await FallingEdge(dut.clk)
    dut.i_h.value, dut.i_w.value, dut.i_c_in.value, dut.i_c_out.value = 5, 5, 2, 3
    dut.i_start.value = 1
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    for _ in range(5):
        await FallingEdge(dut.clk)
    dut.i_start.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.i_start.value = 0


CONFIGS = [
    ("icarus", 8, 128),
    ("verilator", 8, 128),
    ("verilator", 8, 16),
    ("icarus", 3, 16),
]


def build(sim: str) -> tuple[list[Path], list[str]]:
    if sim == "verilator":
        return SOURCES + SVA_SOURCES, ["--assert"]
    return SOURCES, []


@pytest.mark.parametrize(("sim", "n", "k_tile"), CONFIGS)
def test_gemm_engine(sim: str, n: int, k_tile: int) -> None:
    sources, args = build(sim)
    run_cocotb(
        sim=sim,
        toplevel="gemm_engine",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={"N": n, "K_TILE": k_tile, "WGT_DEPTH": WGT_DEPTH, "PARAM_DEPTH": PARAM_DEPTH},
        extra_build_args=args,
        extra_env={"TB_N": str(n)},
    )


def test_engine_sva_fires() -> None:
    sources, args = build("verilator")
    log = SIM_BUILD_DIR / "gemm_engine_sva_violation.log"
    with pytest.raises((SystemExit, RuntimeError)):
        run_cocotb(
            sim="verilator",
            toplevel="gemm_engine",
            sources=sources,
            test_module=Path(__file__).stem,
            parameters={"N": 8, "K_TILE": 128, "WGT_DEPTH": WGT_DEPTH, "PARAM_DEPTH": PARAM_DEPTH},
            extra_build_args=args,
            testcase="sva_violation_start_while_busy",
            extra_env={"TB_N": "8", "SVA_VIOLATION": "start_while_busy"},
            log_file=log,
            build_tag="sva_violation",
        )
    failed = [line for line in log.read_text().splitlines() if "Assertion failed" in line]
    assert failed and "a_start_only_when_idle" in failed[0], failed[:1]
