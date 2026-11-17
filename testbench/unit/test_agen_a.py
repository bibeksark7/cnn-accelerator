"""agen_a: im2col (CONV) and linear (FC) A-operand addresses vs a direct Python formula.

Each test drives the exact command sequence the GEMM engine issues (stage every K chunk of every
column tile of every row tile) and checks every emitted (bank, kpos, address), the row masks, K,
and that the stream respects backpressure. For the real conv layers the addresses are also used to
gather golden-model activations, which must equal golden.im2col.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset, wait_until
from model import golden, hwmap, net

CMD_STAGE, CMD_NEXT_CHUNK, CMD_REWIND_K, CMD_NEXT_TILE = 0, 1, 2, 3
SOURCE = RTL_DIR / "addr" / "agen_a.sv"


@dataclass(frozen=True)
class Layer:
    fc: bool
    base: int
    h: int
    w: int
    c: int
    ncols: int  # output columns (C_out): sets the number of column tiles

    @property
    def m(self) -> int:
        if self.k == 0:
            return 0  # K = 0 (C = 0, or an empty FC input): nothing to stage, no tiles
        return 1 if self.fc else max(self.h - 2, 0) * max(self.w - 2, 0)

    @property
    def k(self) -> int:
        return self.h * self.w * self.c if self.fc else 9 * self.c

    def addr(self, m: int, k: int) -> int:
        """Direct formula (with multiplications) for the source address of A[m][k]."""
        if self.fc:
            return (self.base + k) & 0xFFFF
        wo = self.w - 2
        oy, ox = divmod(m, wo)
        ky, rem = divmod(k, 3 * self.c)
        kx, ci = divmod(rem, self.c)
        return (self.base + ((oy + ky) * self.w + (ox + kx)) * self.c + ci) & 0xFFFF


def n_of(dut) -> int:
    return len(dut.o_row_mask)


async def issue(dut, cmd: int, kc_len: int = 0) -> None:
    await wait_until(dut, lambda: int(dut.o_cmd_ready.value) == 1, 5000, "o_cmd_ready")
    await FallingEdge(dut.clk)
    dut.i_cmd_valid.value = 1
    dut.i_cmd.value = cmd
    dut.i_kc_len.value = kc_len
    await ReadOnly()
    assert int(dut.o_cmd_ready.value) == 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.i_cmd_valid.value = 0


async def collect_stage(dut, rng, ready_prob: float, guard: int) -> list[tuple[int, int, int]]:
    """Collect (bank, kpos, addr) until the transfer flagged o_last (handshake sampling rule)."""
    got = []
    for _ in range(guard):
        await FallingEdge(dut.clk)
        dut.i_ready.value = int(rng.random() < ready_prob)
        await ReadOnly()
        if int(dut.o_valid.value) and int(dut.i_ready.value):
            got.append((int(dut.o_bank.value), int(dut.o_kpos.value), int(dut.o_addr.value)))
            if int(dut.o_last.value):
                await RisingEdge(dut.clk)
                await FallingEdge(dut.clk)
                dut.i_ready.value = 0
                return got
        await RisingEdge(dut.clk)
    raise TimeoutError("stage never produced o_last")


async def run_layer(dut, layer: Layer, k_tile: int, rng, ready_prob: float = 1.0) -> list:
    """Drive one layer like the engine does; return every stage's address list."""
    n = n_of(dut)
    await FallingEdge(dut.clk)
    dut.i_init.value = 1
    dut.i_fc.value = int(layer.fc)
    dut.i_base.value = layer.base
    dut.i_h.value, dut.i_w.value, dut.i_c.value = layer.h, layer.w, layer.c
    await FallingEdge(dut.clk)
    dut.i_init.value = 0
    await wait_until(dut, lambda: int(dut.o_cmd_ready.value) == 1, 5000, "setup")
    assert int(dut.o_k_len.value) == layer.k, f"K {int(dut.o_k_len.value)} != {layer.k}"

    chunks = [(k0, min(k_tile, layer.k - k0)) for k0 in range(0, layer.k, k_tile)]
    ncol_tiles = -(-layer.ncols // n)
    ntiles = -(-layer.m // n)
    stages = []
    for mt in range(ntiles + 1):
        await FallingEdge(dut.clk)  # leave any read-only phase, then sample the stable status
        await ReadOnly()
        want_mask = sum(1 << i for i in range(n) if mt * n + i < layer.m)
        assert int(dut.o_row_mask.value) == want_mask, f"tile {mt} mask"
        assert int(dut.o_tile_valid.value) == (mt < ntiles), f"tile {mt} valid"
        if mt == ntiles:
            break
        for nt in range(ncol_tiles):
            for ci, (k0, kc) in enumerate(chunks):
                await issue(dut, CMD_STAGE, kc)
                got = await collect_stage(dut, rng, ready_prob, 50 * n * kc + 200)
                want = [
                    (i, kp, layer.addr(mt * n + i, k0 + kp))
                    for i in range(n)
                    if mt * n + i < layer.m
                    for kp in range(kc)
                ]
                assert got == want, f"tile {mt} col {nt} chunk {ci}: first diff " + str(
                    next((g, w) for g, w in zip(got, want, strict=False) if g != w)
                    if any(g != w for g, w in zip(got, want, strict=False))
                    else f"lengths {len(got)} vs {len(want)}"
                )
                stages.append(((mt, k0, kc), got))
                if ci < len(chunks) - 1:
                    await issue(dut, CMD_NEXT_CHUNK)
                elif nt < ncol_tiles - 1:
                    await issue(dut, CMD_REWIND_K)
                else:
                    await issue(dut, CMD_NEXT_TILE)
        await wait_until(dut, lambda: int(dut.o_cmd_ready.value) == 1, 5000, "scan")
    return stages


async def setup(dut) -> None:
    dut.i_init.value = 0
    dut.i_cmd_valid.value = 0
    dut.i_ready.value = 0
    await start_clock_and_reset(dut)


@cocotb.test()
async def test_network_layers_match_golden_im2col(dut):
    """conv1, conv2 and fc with the network's shapes and K_TILE = 128; data gathered through the
    generated addresses must equal golden.im2col (conv) or the flattened activation (fc)."""
    rng = seeded_rng(dut, "network")
    await setup(dut)
    params = golden.QuantParams.load()
    with np.load(Path(golden.__file__).parent / "artifacts" / "quick_subset.npz") as f:
        q = f["q"][:1]
    acts = golden.infer(params, q, keep=True)
    inputs = {"conv1": q[..., None], "conv2": acts["pool1"], "fc": acts["pool2"]}
    for name in ("conv1", "conv2", "fc"):
        shape = net.LAYER_BY_NAME[name]
        layer = Layer(name == "fc", 0, shape.h_in, shape.w_in, shape.c_in, shape.c_out)
        stages = await run_layer(dut, layer, hwmap.K_TILE, rng, ready_prob=0.7)
        flat = inputs[name][0].reshape(-1).astype(np.int64)
        a = np.zeros((layer.m, layer.k), dtype=np.int64)
        for (mt, k0, _kc), got in stages:
            for bank, kpos, addr in got:
                a[mt * n_of(dut) + bank, k0 + kpos] = flat[addr]
        want = flat[None, :] if layer.fc else golden.im2col(inputs[name])[0].astype(np.int64)
        np.testing.assert_array_equal(a, want, err_msg=name)


@cocotb.test()
async def test_random_shapes_small_chunks(dut):
    """Random shapes, non-zero bases, chunk sizes that split kernel rows, several column tiles."""
    rng = seeded_rng(dut, "random")
    await setup(dut)
    n = n_of(dut)
    for _ in range(25):
        fc = rng.random() < 0.3
        layer = Layer(
            fc,
            rng.randrange(0, 4000),
            rng.randint(3, 9),
            rng.randint(3, 9),
            rng.randint(1, 5),
            rng.randint(1, 3 * n),
        )
        k_tile = rng.choice([1, 2, 5, 7, 16, 128])
        await run_layer(dut, layer, k_tile, rng, ready_prob=rng.choice([1.0, 0.6, 0.25]))


@cocotb.test()
async def test_edge_shapes(dut):
    """Single output pixel, single output row/column, C = 1, and shapes with no output."""
    rng = seeded_rng(dut, "edges")
    await setup(dut)
    for h, w, c in ((3, 3, 1), (3, 9, 2), (9, 3, 3), (4, 4, 1), (2, 5, 1), (5, 2, 1), (3, 3, 0)):
        await run_layer(dut, Layer(False, 100, h, w, c, 4), 4, rng)


@pytest.mark.parametrize(("sim", "n"), [(s, 8) for s in SIMULATORS] + [("icarus", 3)])
def test_agen_a(sim: str, n: int) -> None:
    run_cocotb(
        sim=sim,
        toplevel="agen_a",
        sources=[SOURCE],
        test_module=Path(__file__).stem,
        parameters={"N": n},
    )


def test_agen_a_has_no_multipliers() -> None:
    """The generator is built from counters and adders only (no $mul cells after proc/opt)."""
    out = subprocess.run(
        ["yosys", "-q", "-p", f"read_verilog -sv {SOURCE}; hierarchy -top agen_a; proc; opt; "
         "tee -q -o /dev/stdout stat"],
        capture_output=True, text=True, check=True,
    ).stdout  # fmt: skip
    assert "cells" in out
    assert "$mul" not in out
