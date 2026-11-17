"""agen_pool: 2x2 / stride-2 window-scan addresses vs a direct Python formula.

Checks every (address, first, last, destination, end) under random backpressure, floor behaviour
for odd sizes, degenerate shapes with no output, and, for the real pool layers, that max-pooling
golden activations through the generated addresses equals golden.maxpool2.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset, wait_until
from model import golden, net

SOURCE = RTL_DIR / "addr" / "agen_pool.sv"


def expected(src: int, dst: int, h: int, w: int, c: int) -> list[tuple]:
    """Direct formula: (addr, first, last, dst, end) for every read, c fastest."""
    ho, wo = h // 2, w // 2
    out = []
    idx = 0
    for oy in range(ho):
        for ox in range(wo):
            for ch in range(c):
                for p, (dy, dx) in enumerate(((0, 0), (0, 1), (1, 0), (1, 1))):
                    addr = (src + ((2 * oy + dy) * w + 2 * ox + dx) * c + ch) & 0xFFFF
                    out.append((addr, int(p == 0), int(p == 3), (dst + idx) & 0xFFFF, 0))
                idx += 1
    if out:
        out[-1] = (*out[-1][:4], 1)
    return out


async def run_pool(dut, src, dst, h, w, c, rng, ready_prob=1.0) -> list[tuple]:
    await FallingEdge(dut.clk)
    dut.i_start.value = 1
    dut.i_src_base.value, dut.i_dst_base.value = src, dst
    dut.i_h.value, dut.i_w.value, dut.i_c.value = h, w, c
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    got = []
    want_len = len(expected(src, dst, h, w, c))
    for _ in range(20 * (want_len + w) + 200):  # hang guard, not a latency
        await FallingEdge(dut.clk)
        dut.i_ready.value = int(rng.random() < ready_prob)
        await ReadOnly()
        if int(dut.o_valid.value) and int(dut.i_ready.value):
            got.append(
                (
                    int(dut.o_addr.value),
                    int(dut.o_first.value),
                    int(dut.o_last.value),
                    int(dut.o_dst.value),
                    int(dut.o_end.value),
                )
            )
        if not int(dut.o_busy.value) and len(got) == want_len:
            break
        await RisingEdge(dut.clk)
    else:
        raise TimeoutError(f"pool scan did not finish ({len(got)}/{want_len})")
    await FallingEdge(dut.clk)
    dut.i_ready.value = 0
    await wait_until(dut, lambda: int(dut.o_busy.value) == 0, 100, "o_busy low")
    return got


async def setup(dut) -> None:
    dut.i_start.value = 0
    dut.i_ready.value = 0
    await start_clock_and_reset(dut)


@cocotb.test()
async def test_network_pools_match_golden(dut):
    rng = seeded_rng(dut, "network")
    await setup(dut)
    params = golden.QuantParams.load()
    with np.load(Path(golden.__file__).parent / "artifacts" / "quick_subset.npz") as f:
        q = f["q"][:1]
    acts = golden.infer(params, q, keep=True)
    for name, act_in, want_out in (
        ("pool1", acts["conv1"], acts["pool1"]),
        ("pool2", acts["conv2"], acts["pool2"]),
    ):
        s = net.LAYER_BY_NAME[name]
        got = await run_pool(dut, 0, 0, s.h_in, s.w_in, s.c_in, rng, ready_prob=0.7)
        assert got == expected(0, 0, s.h_in, s.w_in, s.c_in), name
        flat_in = act_in[0].reshape(-1)
        out = np.full(s.out_elems, -999, dtype=np.int64)
        best = None
        for addr, first, last, dst, _end in got:
            best = int(flat_in[addr]) if first else max(best, int(flat_in[addr]))
            if last:
                out[dst] = best
        np.testing.assert_array_equal(out, want_out[0].reshape(-1), err_msg=name)


@cocotb.test()
async def test_random_shapes(dut):
    rng = seeded_rng(dut, "random")
    await setup(dut)
    for _ in range(30):
        h, w, c = rng.randint(2, 9), rng.randint(2, 9), rng.randint(1, 4)
        src, dst = rng.randrange(0, 60000), rng.randrange(0, 60000)
        got = await run_pool(dut, src, dst, h, w, c, rng, rng.choice([1.0, 0.5, 0.2]))
        assert got == expected(src, dst, h, w, c), (h, w, c)


@cocotb.test()
async def test_shapes_without_output(dut):
    """H or W below 2, or C = 0: no addresses, and o_busy returns low."""
    rng = seeded_rng(dut, "empty")
    await setup(dut)
    for h, w, c in ((1, 5, 2), (5, 1, 2), (4, 4, 0), (0, 0, 0)):
        assert await run_pool(dut, 7, 9, h, w, c, rng) == []


@pytest.mark.parametrize("sim", SIMULATORS)
def test_agen_pool(sim: str) -> None:
    run_cocotb(sim=sim, toplevel="agen_pool", sources=[SOURCE], test_module=Path(__file__).stem)


def test_agen_pool_has_no_multipliers() -> None:
    out = subprocess.run(
        ["yosys", "-q", "-p", f"read_verilog -sv {SOURCE}; hierarchy -top agen_pool; proc; opt; "
         "tee -q -o /dev/stdout stat"],
        capture_output=True, text=True, check=True,
    ).stdout  # fmt: skip
    assert "cells" in out
    assert "$mul" not in out
