"""pool_unit: 2x2 / stride-2 signed max pool vs golden.maxpool2, through a buffer model.

The buffer model answers source reads with the 1-cycle latency of spec §5 and records writes.
A run passes when every output address is written exactly once with the golden value and
nothing else is written. Shapes with no output must finish without writes. Verilator runs bind
the shared unit contract (testbench/sva/unit_if_sva.sv); test_pool_sva_fires shows the
sequencer-side assertions are live.
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.bits import to_signed, to_unsigned
from common.runner import RTL_DIR, SIMULATORS, SVA_DIR, run_cocotb, run_sva_violation
from common.sim import seeded_rng, start_clock_and_reset, wait_until
from model import golden, net

SOURCES = [RTL_DIR / "addr" / "agen_pool.sv", RTL_DIR / "post" / "pool_unit.sv"]
SVA_SOURCES = [SVA_DIR / "unit_if_sva.sv", SVA_DIR / "pool_unit_bind.sv"]
SVA_VIOLATION = os.environ.get("SVA_VIOLATION", "")


async def serve(dut, src: dict[int, int], writes: dict[int, int], dup: list[int]) -> None:
    """Synchronous-read source buffer (data right after the accepting edge) and a write log."""
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        read = int(dut.o_src_addr.value) if int(dut.o_src_re.value) else None
        if int(dut.o_dst_we.value):
            a = int(dut.o_dst_addr.value)
            if a in writes:
                dup.append(a)
            writes[a] = to_signed(int(dut.o_dst_wdata.value), 8)
        await RisingEdge(dut.clk)
        if read is not None:
            dut.i_src_rdata.value = to_unsigned(src.get(read, 0), 8)


async def run_pool(dut, act: np.ndarray, src_base: int, dst_base: int) -> None:
    """Pool one HWC tensor and check every output against golden.maxpool2."""
    h, w, c = act.shape
    src = {(src_base + i) & 0xFFFF: int(v) for i, v in enumerate(act.reshape(-1))}
    if h >= 2 and w >= 2 and c >= 1:
        want_flat = golden.maxpool2(act[None])[0].reshape(-1)
    else:
        want_flat = np.zeros(0)
    want = {(dst_base + i) & 0xFFFF: int(v) for i, v in enumerate(want_flat)}
    writes: dict[int, int] = {}
    dup: list[int] = []
    server = cocotb.start_soon(serve(dut, src, writes, dup))
    await FallingEdge(dut.clk)
    dut.i_src_base.value, dut.i_dst_base.value = src_base, dst_base
    dut.i_h.value, dut.i_w.value, dut.i_c.value = h, w, c
    dut.i_start.value = 1
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    await wait_until(dut, lambda: int(dut.o_done.value) == 1, 20 * (h * w * c + w) + 500, "o_done")
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    server.cancel()
    assert int(dut.o_busy.value) == 0
    assert not dup, f"written twice: {dup[:8]}"
    extra, missing = sorted(set(writes) - set(want)), sorted(set(want) - set(writes))
    assert not extra and not missing, f"extra writes {extra[:8]}, missing {missing[:8]}"
    wrong = [(a, writes[a], v) for a, v in want.items() if writes[a] != v]
    assert not wrong, f"{len(wrong)} wrong outputs, e.g. (addr, got, want) {wrong[:5]}"


async def setup(dut) -> None:
    dut.i_start.value = 0
    dut.i_src_rdata.value = 0
    await start_clock_and_reset(dut)


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_network_pools(dut):
    """pool1 and pool2 on golden conv outputs equal the golden pool outputs."""
    await setup(dut)
    params = golden.QuantParams.load()
    with np.load(Path(golden.__file__).parent / "artifacts" / "quick_subset.npz") as f:
        q = f["q"][:2]
    acts = golden.infer(params, q, keep=True)
    for i in range(2):
        for name, act in (("pool1", acts["conv1"][i]), ("pool2", acts["conv2"][i])):
            await run_pool(dut, act, 0, 0)
            dut._log.info(
                "image %d %s: %d outputs match", i, name, net.LAYER_BY_NAME[name].out_elems
            )


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_random_signed_shapes(dut):
    """Random shapes (odd sizes floor), bases and the full int8 range (negative maxima)."""
    rng = seeded_rng(dut, "pool")
    await setup(dut)
    for _ in range(30):
        h, w, c = rng.randint(2, 9), rng.randint(2, 9), rng.randint(1, 5)
        act = np.array(
            [rng.choice([-128, 127, rng.randint(-128, 127)]) for _ in range(h * w * c)],
            dtype=np.int8,
        ).reshape(h, w, c)
        if rng.random() < 0.3:
            act = (act.astype(np.int16) // 2 - 64).clip(-128, -1).astype(np.int8)  # all negative
        await run_pool(dut, act, rng.randrange(0, 60000), rng.randrange(0, 60000))


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_shapes_without_output(dut):
    """H or W below 2, or C = 0: done without any write."""
    await setup(dut)
    for h, w, c in ((1, 5, 2), (5, 1, 2), (4, 4, 0)):
        await run_pool(dut, np.zeros((h, w, c), dtype=np.int8), 10, 20)


async def start_busy_pool(dut) -> None:
    """Start a 6x6x2 pool and wait a few cycles (it is still busy)."""
    await setup(dut)
    cocotb.start_soon(serve(dut, {}, {}, []))
    await FallingEdge(dut.clk)
    dut.i_src_base.value, dut.i_dst_base.value = 0, 100
    dut.i_h.value, dut.i_w.value, dut.i_c.value = 6, 6, 2
    dut.i_start.value = 1
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    for _ in range(5):
        await FallingEdge(dut.clk)


@cocotb.test(skip=SVA_VIOLATION != "start_while_busy")
async def sva_violation_start_while_busy(dut):
    """A second i_start while pooling; only run by test_pool_sva_fires."""
    await start_busy_pool(dut)
    dut.i_start.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.i_start.value = 0


@cocotb.test(skip=SVA_VIOLATION != "cfg_change_while_busy")
async def sva_violation_cfg_change_while_busy(dut):
    """The shape changes while pooling; only run by test_pool_sva_fires."""
    await start_busy_pool(dut)
    dut.i_c.value = 3
    for _ in range(3):
        await FallingEdge(dut.clk)


def build(sim: str) -> tuple[list[Path], list[str]]:
    if sim == "verilator":
        return SOURCES + SVA_SOURCES, ["--assert"]
    return SOURCES, []


@pytest.mark.parametrize("sim", SIMULATORS)
def test_pool_unit(sim: str) -> None:
    sources, args = build(sim)
    run_cocotb(
        sim=sim,
        toplevel="pool_unit",
        sources=sources,
        test_module=Path(__file__).stem,
        extra_build_args=args,
    )


@pytest.mark.parametrize(
    ("violation", "assertion"),
    [
        ("start_while_busy", "a_start_only_when_idle"),
        ("cfg_change_while_busy", "a_cfg_stable_while_busy"),
    ],
)
def test_pool_sva_fires(violation: str, assertion: str) -> None:
    sources, args = build("verilator")
    run_sva_violation(
        toplevel="pool_unit",
        sources=sources,
        test_module=Path(__file__).stem,
        violation=violation,
        assertion=assertion,
        extra_build_args=args,
    )
