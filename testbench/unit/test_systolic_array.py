"""systolic_array (spec §11.2): tile results vs NumPy, driven only through the interface handshakes.

No test assumes a latency: steps are streamed (with random gaps), i_drain is pulsed, and rows are
collected with random backpressure until o_row_last is accepted. The same test is meant to run
unchanged on the weight-stationary array (Phase 7).
"""

from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.bits import pack, to_signed, unpack
from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset, wait_until

DATA_W, ACC_W = 8, 32
SOURCES = [RTL_DIR / "core" / "mac_cell.sv", RTL_DIR / "core" / "systolic_array.sv"]


def n_of(dut) -> int:
    return len(dut.i_a) // DATA_W


def idle(dut) -> None:
    dut.i_clear.value = 0
    dut.i_valid.value = 0
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_drain.value = 0
    dut.i_row_ready.value = 0


async def run_tile(dut, a: np.ndarray, b: np.ndarray, rng, gap_prob: float, ready_prob: float):
    """Clear, stream K steps, drain, and return the N x N result read through the handshake."""
    n = n_of(dut)
    k_len = a.shape[1]
    await wait_until(dut, lambda: int(dut.o_idle.value) == 1, 200, "o_idle before clear")
    await FallingEdge(dut.clk)
    dut.i_clear.value = 1
    await FallingEdge(dut.clk)
    dut.i_clear.value = 0
    k = 0
    while k < k_len:
        if rng.random() < gap_prob:
            dut.i_valid.value = 0
        else:
            dut.i_valid.value = 1
            dut.i_a.value = pack(a[:, k], DATA_W)
            dut.i_b.value = pack(b[k, :], DATA_W)
            k += 1
        await FallingEdge(dut.clk)
    dut.i_valid.value = 0
    for _ in range(rng.choice([0, 0, 1, 3])):  # optional gap before the drain pulse
        await FallingEdge(dut.clk)
    dut.i_drain.value = 1
    await FallingEdge(dut.clk)
    dut.i_drain.value = 0

    # Handshake sampling: ready is set after a falling edge, and valid/ready/data are sampled in
    # that same time step, i.e. the values the next rising edge will see. A transfer happens at
    # that rising edge iff both are high.
    rows: list[list[int]] = []
    for _ in range(100 * n + 4 * k_len + 100):  # generous hang guard, not a latency
        dut.i_row_ready.value = int(rng.random() < ready_prob)
        await ReadOnly()
        fire = int(dut.o_row_valid.value) and int(dut.i_row_ready.value)
        if fire:
            rows.append(unpack(int(dut.o_row_data.value), ACC_W, n))
            last = int(dut.o_row_last.value)
            assert last == (len(rows) == n), f"o_row_last={last} on row {len(rows) - 1}"
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        if fire and last:
            break
    else:
        raise TimeoutError("result rows never completed")
    dut.i_row_ready.value = 0
    return np.array(rows, dtype=np.int64)


def expected(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    c = a.astype(np.int64) @ b.astype(np.int64)
    return np.vectorize(lambda v: to_signed(int(v), ACC_W))(c)


def rand_int8(rng, shape, extremes: float = 0.2) -> np.ndarray:
    vals = [
        rng.choice([-128, 127]) if rng.random() < extremes else rng.randint(-128, 127)
        for _ in range(int(np.prod(shape)))
    ]
    return np.array(vals, dtype=np.int64).reshape(shape)


@cocotb.test()
async def test_reset_and_idle(dut):
    idle(dut)
    await start_clock_and_reset(dut)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.o_idle.value) == 1
    assert int(dut.o_row_valid.value) == 0


@cocotb.test()
async def test_directed_edge_cases(dut):
    """All zeros, K = 1, int8 extremes (max-magnitude products), identity-like B."""
    rng = seeded_rng(dut, "directed")
    n = n_of(dut)
    idle(dut)
    await start_clock_and_reset(dut)
    cases = {
        "zeros": (np.zeros((n, 5), np.int64), np.zeros((5, n), np.int64)),
        "k1": (rand_int8(rng, (n, 1)), rand_int8(rng, (1, n))),
        "min_x_min": (np.full((n, 9), -128), np.full((9, n), -128)),
        "min_x_max": (np.full((n, 9), -128), np.full((9, n), 127)),
        "identity": (rand_int8(rng, (n, n)), np.eye(n, dtype=np.int64)),
    }
    for name, (a, b) in cases.items():
        got = await run_tile(dut, a, b, rng, gap_prob=0.0, ready_prob=1.0)
        np.testing.assert_array_equal(got, expected(a, b), err_msg=name)


@cocotb.test()
async def test_drain_without_steps_gives_zeros(dut):
    rng = seeded_rng(dut, "empty")
    n = n_of(dut)
    idle(dut)
    await start_clock_and_reset(dut)
    a, b = rand_int8(rng, (n, 4)), rand_int8(rng, (4, n))
    await run_tile(dut, a, b, rng, 0.0, 1.0)  # leave non-zero accumulators behind
    got = await run_tile(dut, np.zeros((n, 0), np.int64), np.zeros((0, n), np.int64), rng, 0, 1)
    np.testing.assert_array_equal(got, np.zeros((n, n)))


@cocotb.test()
async def test_random_tiles_with_gaps_and_backpressure(dut):
    """Back-to-back random tiles; random step gaps and row backpressure; K up to 128."""
    rng = seeded_rng(dut, "random")
    n = n_of(dut)
    idle(dut)
    await start_clock_and_reset(dut)
    for t in range(12):
        k_len = rng.choice([1, 2, 3, n - 1 or 1, n, n + 1, 17, 64, 128])
        a, b = rand_int8(rng, (n, k_len)), rand_int8(rng, (k_len, n))
        gap = rng.choice([0.0, 0.2, 0.6])
        ready = rng.choice([1.0, 0.5, 0.2])
        got = await run_tile(dut, a, b, rng, gap, ready)
        np.testing.assert_array_equal(got, expected(a, b), err_msg=f"tile {t}, K={k_len}")


@pytest.mark.parametrize(
    ("sim", "n"),
    [(s, 8) for s in SIMULATORS] + [("icarus", 3), ("icarus", 1)],
)
def test_systolic_array(sim: str, n: int) -> None:
    run_cocotb(
        sim=sim,
        toplevel="systolic_array",
        sources=SOURCES,
        test_module=Path(__file__).stem,
        parameters={"N": n, "DATA_W": DATA_W, "ACC_W": ACC_W},
    )
