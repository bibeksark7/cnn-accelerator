"""gemm_engine: whole CONV / FC layers vs the golden model, through Python buffer models.

The buffer models answer the engine's read ports with exactly the 1-cycle latency of spec §5 and
record every write. A layer passes when every expected output address is written exactly once
with the golden value and nothing else is written.

Tests:
  network layers   conv1, conv2, fc with the exported weight/param images (N = 8); logs busy
                   cycles, MAC-active cycles and effective MAC utilization per layer
  random conv/fc   random shapes (ragged C_out, M not a multiple of N), bases, ReLU on/off,
                   full int8 activations; small K_TILE builds force K chunking
  no-work layers   C_out = 0, no output pixels, K = 0: done with no writes
  reset mid-layer  reset during A load, stream, the drain's parameter prefetch, row wait and
                   element feed, and the post-processing flush; then about 20 resets at random
                   cycles of a layer; each followed by a clean layer that must be exactly right
  FSM coverage     every reachable transition of the sequencer (qstate_q) and drain (dstate_q)
                   FSMs is hit; known-unreachable branches are listed with the reason. Checked
                   by test_fsm_transition_coverage inside full runs and again by the pytest
                   wrapper from fsm_coverage.json (skipped when a test filter is set)
Verilator runs bind the shared unit contract (unit_if_sva), the engine implementation
assertions and the array assertions; test_engine_sva_fires proves selected ones are live.

Push CI (CI=true) skips the network layers on Icarus; they run on Verilator (TB_NETWORK).
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.coverage import cover, cover_vr_links, is_verilator, start_handshake_monitor
from common.runner import RTL_DIR, SVA_DIR, run_cocotb, run_sva_violation
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
    SVA_DIR / "unit_if_sva.sv",
    SVA_DIR / "gemm_engine_impl_sva.sv",
    SVA_DIR / "gemm_engine_bind.sv",
    SVA_DIR / "valid_ready_sva.sv",
    SVA_DIR / "gemm_engine_vr_bind.sv",
    SVA_DIR / "postproc_vr_bind.sv",
    SVA_DIR / "agen_a_vr_bind.sv",
]
TB_N = int(os.environ.get("TB_N", "8"))
TB_NETWORK = os.environ.get("TB_NETWORK", "1") == "1"
SVA_VIOLATION = os.environ.get("SVA_VIOLATION", "")
TB_K_TILE = int(os.environ.get("TB_K_TILE", "128"))  # the build's K_TILE (functional coverage)
WGT_DEPTH, PARAM_DEPTH = 1024, 64

# FSM state encodings, in the order of gemm_engine's qstate_t and dstate_t enums
# (scripts/check_fsm_names.py checks they match the RTL).
Q_NAMES = [
    "IDLE",
    "SETUP",
    "TILE",
    "CLEAR",
    "STAGE",
    "LOAD",
    "STREAM",
    "CMD",
    "DRAIN",
    "NEXT",
    "DONE",
]
D_NAMES = ["IDLE", "PRM", "PULSE", "ROW", "ELEM", "FLUSH"]
# Observed transitions across all tests of one simulation: (from, to) and reset-driven (from).
COVERAGE: dict[str, set] = {"q": set(), "d": set(), "q_rst": set(), "d_rst": set()}


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
        self.busy_cycles = 0
        self.mac_cycles = 0


async def serve(dut, buf: Buffers) -> None:
    """Synchronous-read buffers: a request seen by rising edge E returns data after E."""
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        buf.busy_cycles += int(dut.o_busy.value)
        buf.mac_cycles += int(dut.o_mac_active.value)
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


def cover_layer(layer: Layer, n: int) -> None:
    """Functional coverage of a layer's shape (D-034)."""
    if layer.fc:
        m_rows, k = 1, layer.h * layer.w * layer.c_in
    else:
        m_rows = max(layer.h - 2, 0) * max(layer.w - 2, 0)
        k = 9 * layer.c_in
        cover("ReLU", "on" if layer.relu else "off")
    cover("layer type", "FC" if layer.fc else "CONV")
    work = m_rows > 0 and k > 0 and layer.c_out > 0
    if not work:
        cover("layers without work", "C_out = 0" if layer.c_out == 0 else "M = 0 or K = 0")
        return
    cover("row tiles (M)", "last tile full" if m_rows % n == 0 else "last tile partial")
    cover("column tiles (Ncols)", "last tile full" if layer.c_out % n == 0 else "last tile partial")
    cover("column tile count", "1" if layer.c_out <= n else "more than 1")
    if k == 1:
        cover("K", "K = 1")
    elif k <= TB_K_TILE:
        cover("K", "1 < K <= K_TILE")
    else:
        cover("K", "K > K_TILE")
    cover("K chunks", "1" if k <= TB_K_TILE else "more than 1")


async def run_layer(dut, layer: Layer, timeout: int = 400_000) -> Buffers:
    cover_layer(layer, n_of(dut))
    buf = Buffers(layer)
    server = cocotb.start_soon(serve(dut, buf))
    await start_layer(dut, layer)
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


async def fsm_monitor(dut) -> None:
    """Record every sequencer/drain FSM transition; reset-driven ones are kept separately."""
    prev = None
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        try:
            cur = (int(dut.qstate_q.value), int(dut.dstate_q.value), int(dut.rst.value))
        except ValueError:  # X/Z before the first reset
            prev = None
            continue
        if prev is not None:
            pq, pd, _ = prev
            # rst is driven at falling edges, so its value now is the value the last edge saw.
            if cur[2]:
                COVERAGE["q_rst"].add(Q_NAMES[pq])
                COVERAGE["d_rst"].add(D_NAMES[pd])
            else:
                COVERAGE["q"].add((Q_NAMES[pq], Q_NAMES[cur[0]]))
                COVERAGE["d"].add((D_NAMES[pd], D_NAMES[cur[1]]))
        prev = cur


async def setup(dut) -> None:
    for sig in (dut.i_start, dut.i_src_rdata, dut.i_wgt_rdata, dut.i_prm_rdata):
        sig.value = 0
    cocotb.start_soon(fsm_monitor(dut))
    if cocotb.SIM_NAME.lower().startswith("verilator"):  # per-cycle monitors: fast simulator only
        a = dut.u_systolic_array
        start_handshake_monitor(dut.clk, a.o_row_valid, a.i_row_ready, "array rows -> row register")
        pp = dut.u_postproc
        start_handshake_monitor(dut.clk, pp.i_valid, pp.o_ready, "row register -> postproc")
        start_handshake_monitor(dut.clk, pp.o_valid, pp.i_ready, "postproc -> write port")
    await start_clock_and_reset(dut)


async def pulse_reset(dut, cycles: int = 2) -> None:
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    for _ in range(cycles):
        await FallingEdge(dut.clk)
    dut.rst.value = 0


@cocotb.test(skip=TB_N != hwmap.N or not TB_NETWORK or SVA_VIOLATION != "")
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
        buf = await run_layer(dut, layer)
        m_rows = 1 if layer.fc else (d.h_in - 2) * (d.w_in - 2)
        k_len = d.h_in * d.w_in * d.c_in if layer.fc else 9 * d.c_in
        useful = m_rows * k_len * d.c_out
        n = n_of(dut)
        dut._log.info(
            "%s: %d outputs match the golden model; busy %d cycles, MAC-active %d (%.1f%%), "
            "effective MAC utilization %.2f%% (%d useful MACs / (%d cycles x %d MACs))",
            name, len(want), buf.busy_cycles, buf.mac_cycles,
            100.0 * buf.mac_cycles / buf.busy_cycles,
            100.0 * useful / (buf.busy_cycles * n * n), useful, buf.busy_cycles, n * n,
        )  # fmt: skip


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


def deep_fc(rng, n) -> Layer:
    """FC with K = 5 * 5 * 8 = 200 (more than one K chunk for K_TILE <= 128)."""
    h, w, c_in, c_out = 5, 5, 8, n + 2
    act = np.array([rng.randint(-128, 127) for _ in range(h * w * c_in)], dtype=np.int8)
    wt = np.array([rng.randint(-127, 127) for _ in range(c_out * h * w * c_in)], dtype=np.int8)
    b = np.array([rng.randint(-200000, 200000) for _ in range(c_out)], dtype=np.int32)
    return fc_layer(n, 17, 33, 5, 3, act.reshape(h, w, c_in), wt.reshape(c_out, -1), b)


def tiny_fc(rng, n) -> Layer:
    """FC with K = 1 (a 1 x 1 x 1 input): one reduction step per output tile."""
    c_out = n + 1
    act = np.array([[[rng.randint(-128, 127)]]], dtype=np.int8)
    wt = np.array([[rng.randint(-127, 127)] for _ in range(c_out)], dtype=np.int8)
    b = np.array([rng.randint(-200000, 200000) for _ in range(c_out)], dtype=np.int32)
    return fc_layer(n, 5, 9, 11, 4, act, wt, b)


def deep_conv(rng, n) -> Layer:
    """CONV with K = 9 * 16 = 144 (more than one K chunk for K_TILE <= 128)."""
    h, w, c_in, c_out = 6, 5, 16, n + 1
    act = np.array([rng.randint(-128, 127) for _ in range(h * w * c_in)], dtype=np.int8)
    wt = np.array([rng.randint(-127, 127) for _ in range(c_out * 9 * c_in)], dtype=np.int8)
    b = np.array([rng.randint(-20000, 20000) for _ in range(c_out)], dtype=np.int32)
    m = np.array([rng.randint(golden.M_MIN, golden.M_MAX) for _ in range(c_out)], dtype=np.uint16)
    s = np.array([rng.randint(14, 24) for _ in range(c_out)], dtype=np.uint8)
    return conv_layer(
        n, 40, 900, 7, 2, act.reshape(h, w, c_in), wt.reshape(c_out, 3, 3, c_in), b, m, s, True
    )


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_random_layers(dut):
    """Back-to-back random CONV and FC layers, ragged tiles, random bases, ReLU on/off, plus a
    CONV and an FC that always need several K chunks, and an FC with K = 1."""
    rng = seeded_rng(dut, "layers")
    n = n_of(dut)
    await setup(dut)
    for i in range(16):
        layer = rand_conv(rng, n) if i % 3 != 2 else rand_fc(rng, n)
        await run_layer(dut, layer)
    # K > K_TILE for every configuration (K_TILE <= 128): an FC with K = 200 and a CONV with
    # K = 144, so K chunking is covered even when the network layers are skipped.
    for layer in (deep_fc(rng, n), deep_conv(rng, n), tiny_fc(rng, n)):
        await run_layer(dut, layer)


def empty_layer(fc: bool, h: int, w: int, c_in: int, c_out: int) -> Layer:
    """A layer with no work: the engine must finish without writing anything."""
    return Layer(
        fc=fc,
        relu=False,
        src_base=100,
        dst_base=200,
        h=h,
        w=w,
        c_in=c_in,
        c_out=c_out,
        wgt_base=0,
        param_base=0,
        src_bytes=np.zeros(0, dtype=np.int8),
        wgt_words=np.zeros(0, dtype=np.uint64),
        prm_words=np.zeros(0, dtype=np.uint64),
        expected={},
    )


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_layers_without_work(dut):
    """C_out = 0, no output pixels (H or W < 3), K = 0 (C_in = 0): done, no writes."""
    await setup(dut)
    for fc, h, w, c_in, c_out in (
        (False, 6, 6, 2, 0),
        (True, 3, 3, 2, 0),
        (False, 2, 6, 2, 3),
        (False, 6, 2, 2, 3),
        (False, 6, 6, 0, 3),
        (True, 3, 3, 0, 4),
    ):
        await run_layer(dut, empty_layer(fc, h, w, c_in, c_out), timeout=2000)


def in_q(name: str):
    return lambda dut: int(dut.qstate_q.value) == Q_NAMES.index(name)


def in_d(name: str):
    return lambda dut: int(dut.dstate_q.value) == D_NAMES.index(name)


RESET_POINTS = (
    ("A load", in_q("LOAD")),
    ("stream", in_q("STREAM")),
    ("drain: parameter prefetch", in_d("PRM")),
    ("drain: waiting for a row", in_d("ROW")),
    ("drain: feeding elements", in_d("ELEM")),
    ("post-processing flush", in_d("FLUSH")),
)
RANDOM_RESETS = 20


async def start_layer(dut, layer: Layer) -> None:
    """Drive a layer's configuration and pulse i_start (no checking)."""
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


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_reset_mid_layer_then_clean_layer(dut):
    """Reset while the engine is in each phase of a layer; the next layer must be exactly right."""
    rng = seeded_rng(dut, "reset")
    n = n_of(dut)
    await setup(dut)
    for where, reached in RESET_POINTS:
        layer = rand_conv(rng, n)
        server = cocotb.start_soon(serve(dut, Buffers(layer)))
        await start_layer(dut, layer)
        await wait_until(dut, lambda r=reached: r(dut), 100_000, f"engine in {where}")
        await pulse_reset(dut)
        server.cancel()
        await ReadOnly()
        assert int(dut.o_busy.value) == 0, f"busy after reset in {where}"
        await run_layer(dut, rand_conv(rng, n) if rng.random() < 0.7 else rand_fc(rng, n))
        dut._log.info("reset during %s, then a clean layer: ok", where)


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_random_cycle_resets(dut):
    """Reset at a random cycle inside a layer, about 20 times. Each layer first runs to completion
    (checked) to measure its length L; it is then restarted and reset after 1 .. L-1 cycles. The
    next layer's full run checks recovery."""
    rng = seeded_rng(dut, "random_resets")
    n = n_of(dut)
    await setup(dut)
    states = []
    for _ in range(RANDOM_RESETS):
        layer = rand_conv(rng, n) if rng.random() < 0.75 else rand_fc(rng, n)
        length = (await run_layer(dut, layer)).busy_cycles
        at = rng.randint(1, max(1, length - 1))
        server = cocotb.start_soon(serve(dut, Buffers(layer)))
        await start_layer(dut, layer)
        for _ in range(at):
            await FallingEdge(dut.clk)
        await ReadOnly()
        states.append(
            (at, length, Q_NAMES[int(dut.qstate_q.value)], D_NAMES[int(dut.dstate_q.value)])
        )
        await pulse_reset(dut)
        server.cancel()
        await ReadOnly()
        assert int(dut.o_busy.value) == 0, f"busy after reset at cycle {at}"
    await run_layer(dut, rand_conv(rng, n))
    dut._log.info("resets at (cycle, layer length, qstate, dstate): %s", states)


# Every transition the RTL can take (outside reset) must be hit by each simulation of this module;
# the branches below are the ones the RTL contains but cannot take, with the reason.
Q_REACHABLE = {
    ("IDLE", "IDLE"), ("IDLE", "SETUP"), ("SETUP", "SETUP"), ("SETUP", "TILE"),
    ("TILE", "CLEAR"), ("TILE", "DONE"), ("CLEAR", "STAGE"), ("STAGE", "LOAD"),
    ("LOAD", "LOAD"), ("LOAD", "STREAM"), ("STREAM", "STREAM"), ("STREAM", "CMD"),
    ("CMD", "STAGE"), ("CMD", "DRAIN"), ("DRAIN", "DRAIN"), ("DRAIN", "CLEAR"),
    ("DRAIN", "NEXT"), ("NEXT", "TILE"), ("DONE", "IDLE"),
}  # fmt: skip
Q_UNREACHABLE = {
    ("CLEAR", "CLEAR"): "the array is already idle when CLEAR is entered (after a completed drain)",
    ("STAGE", "STAGE"): "agen_a is always ready when STAGE is entered (single-cycle commands)",
    ("CMD", "CMD"): "agen_a is always ready after a stream (it has been idle since the stage)",
    ("NEXT", "NEXT"): "the N-cycle tile scan finishes before the drain does (>= 2N cycles)",
    ("default", "IDLE"): "illegal state encodings 11-15 are never entered",
}
D_REACHABLE = {
    ("IDLE", "IDLE"), ("IDLE", "PRM"), ("PRM", "PRM"), ("PRM", "PULSE"), ("PULSE", "ROW"),
    ("ROW", "ROW"), ("ROW", "ELEM"), ("ELEM", "ELEM"), ("ELEM", "ROW"), ("ELEM", "FLUSH"),
    ("FLUSH", "FLUSH"), ("FLUSH", "IDLE"),
}  # fmt: skip
D_UNREACHABLE = {
    ("ELEM", "hold"): "ELEM never waits on a valid element: postproc is never back-pressured "
    "(its output is always accepted), so pp_ready is always high; not visible as a transition",
    ("default", "IDLE"): "illegal state encodings 6-7 are never entered",
}
# Reset must have been applied in each phase of a layer (test_reset_mid_layer_then_clean_layer).
Q_RESET_FROM = {"LOAD", "STREAM", "DRAIN"}
D_RESET_FROM = {"PRM", "ROW", "ELEM", "FLUSH"}
# A test filter (COCOTB_TEST_FILTER, set by the runner's testcase=) runs a subset, so coverage
# cannot be complete. The coverage test is then not registered at all: cocotb runs a test that a
# filter selects even when it is marked skip.
TEST_FILTERED = bool(os.environ.get("COCOTB_TEST_FILTER") or os.environ.get("COCOTB_TESTCASE"))
COVERAGE_FILE = "fsm_coverage.json"


def coverage_gaps(cov: dict[str, set]) -> list[str]:
    """Everything wrong with observed coverage (empty when complete). Shared by the cocotb test
    and the pytest wrapper."""
    gaps = []
    for name, seen, reachable in (
        ("qstate", cov["q"], Q_REACHABLE),
        ("dstate", cov["d"], D_REACHABLE),
    ):
        if seen - reachable:
            gaps.append(f"{name}: unexpected transitions {sorted(seen - reachable)}")
        if reachable - seen:
            gaps.append(f"{name}: transitions never hit {sorted(reachable - seen)}")
    if not cov["q_rst"] >= Q_RESET_FROM:
        gaps.append(f"qstate reset only from {sorted(cov['q_rst'])}, need {sorted(Q_RESET_FROM)}")
    if not cov["d_rst"] >= D_RESET_FROM:
        gaps.append(f"dstate reset only from {sorted(cov['d_rst'])}, need {sorted(D_RESET_FROM)}")
    return gaps


def load_coverage(path: Path) -> dict[str, set]:
    raw = json.loads(path.read_text())
    return {k: {tuple(x) for x in v} if k in ("q", "d") else set(v) for k, v in raw.items()}


async def fsm_transition_coverage(dut):
    """Runs last: every reachable FSM transition was hit, and nothing unexpected happened."""
    for fsm in ("q", "d", "q_rst", "d_rst"):
        dut._log.info("observed %s transitions: %s", fsm, sorted(COVERAGE[fsm]))
    Path(COVERAGE_FILE).write_text(
        json.dumps(
            {k: sorted(map(list, v)) if k in ("q", "d") else sorted(v) for k, v in COVERAGE.items()}
        )
    )
    gaps = coverage_gaps(COVERAGE)
    assert not gaps, "; ".join(gaps)
    dut._log.info(
        "FSM coverage complete: %d/%d qstate, %d/%d dstate transitions; unreachable: %s; %s",
        len(Q_REACHABLE), len(Q_REACHABLE), len(D_REACHABLE), len(D_REACHABLE),
        sorted(Q_UNREACHABLE), sorted(D_UNREACHABLE),
    )  # fmt: skip


if not TEST_FILTERED:
    test_fsm_transition_coverage = cocotb.test(fsm_transition_coverage)


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


@cocotb.test(skip=SVA_VIOLATION != "cfg_change_while_busy")
async def sva_violation_cfg_change_while_busy(dut):
    """The configuration changes while a layer is running; only run by test_engine_sva_fires."""
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
    dut.i_h.value = 6
    for _ in range(3):
        await FallingEdge(dut.clk)


# (simulator, N, K_TILE). K_TILE = 1 (one reduction step per chunk) checks the minimum bank depth.
CONFIGS = [
    ("icarus", 8, 128),
    ("verilator", 8, 128),
    ("verilator", 8, 16),
    ("icarus", 3, 16),
    ("verilator", 3, 1),
]


def build(sim: str) -> tuple[list[Path], list[str]]:
    if sim == "verilator":
        return SOURCES + SVA_SOURCES, ["--assert"]
    return SOURCES, []


def run_network_layers(sim: str) -> bool:
    """Push CI runs the slow network-layer test on Verilator only."""
    return not (os.environ.get("CI") == "true" and sim == "icarus")


@cocotb.test(skip=not is_verilator() or os.environ.get("SVA_VIOLATION", "") != "")
async def test_zz_handshake_stall_cover(dut):
    """Last test (Verilator): the bound valid_ready_sva monitors saw transfers and stalls."""
    cover_vr_links(
        {
            "array rows -> row register": dut.u_rows_vr_sva,
            "agen_a address stream": dut.u_agen_a.u_out_vr_sva,
            "row register -> postproc": dut.u_postproc.u_in_vr_sva,
            "postproc -> write port": dut.u_postproc.u_out_vr_sva,
        },
        {"array rows -> row register"},
    )
    # agen_a's stream never stalls here (the staging banks always accept; the agen_a unit test
    # covers its stalls), and the two postproc links cannot (a_pp_*_never_stalled).
    assert int(dut.u_postproc.u_in_vr_sva.stalls_q.value) == 0
    assert int(dut.u_postproc.u_out_vr_sva.stalls_q.value) == 0


@pytest.mark.parametrize(("sim", "n", "k_tile"), CONFIGS)
def test_gemm_engine(sim: str, n: int, k_tile: int) -> None:
    """Full run of every cocotb test, then the FSM coverage file it wrote is checked again."""
    sources, args = build(sim)
    started = time.time()
    results = run_cocotb(
        sim=sim,
        toplevel="gemm_engine",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={"N": n, "K_TILE": k_tile, "WGT_DEPTH": WGT_DEPTH, "PARAM_DEPTH": PARAM_DEPTH},
        extra_build_args=args,
        extra_env={
            "TB_N": str(n),
            "TB_K_TILE": str(k_tile),
            "TB_NETWORK": "1" if run_network_layers(sim) else "0",
        },
    )
    cov_file = results.parent / COVERAGE_FILE
    assert cov_file.exists(), f"{cov_file} missing: test_fsm_transition_coverage did not run"
    assert cov_file.stat().st_mtime >= started, f"{cov_file} is stale (not written by this run)"
    gaps = coverage_gaps(load_coverage(cov_file))
    assert not gaps, "; ".join(gaps)


@pytest.mark.parametrize(
    ("violation", "assertion"),
    [
        ("start_while_busy", "a_start_only_when_idle"),
        ("cfg_change_while_busy", "a_cfg_stable_while_busy"),
    ],
)
def test_engine_sva_fires(violation: str, assertion: str) -> None:
    """Each violation must fail the run, with its own assertion firing first."""
    sources, args = build("verilator")
    run_sva_violation(
        toplevel="gemm_engine",
        sources=sources,
        test_module=Path(__file__).stem,
        violation=violation,
        assertion=assertion,
        parameters={"N": 8, "K_TILE": 128, "WGT_DEPTH": WGT_DEPTH, "PARAM_DEPTH": PARAM_DEPTH},
        extra_build_args=args,
        extra_env={"TB_N": "8"},
    )
