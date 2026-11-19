"""systolic_array (spec §11.2): tile results vs NumPy, driven only through the interface handshakes.

No test assumes a latency: steps are streamed (with random gaps), i_drain is pulsed, and rows are
collected with random backpressure until o_row_last is accepted. The same test is meant to run
unchanged on the weight-stationary array (Phase 7).
"""

import os
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.bits import pack, to_signed, unpack
from common.coverage import cover, start_handshake_monitor
from common.runner import RTL_DIR, SIM_BUILD_DIR, SIMULATORS, SVA_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset, wait_until

DATA_W, ACC_W = 8, 32
SOURCES = [RTL_DIR / "core" / "mac_cell.sv", RTL_DIR / "core" / "systolic_array.sv"]
SVA_SOURCES = [
    SVA_DIR / "systolic_array_if_sva.sv",
    SVA_DIR / "systolic_array_os_sva.sv",
    SVA_DIR / "systolic_array_bind.sv",
]
SVA_VIOLATION = os.environ.get("SVA_VIOLATION", "")


def n_of(dut) -> int:
    return len(dut.i_a) // DATA_W


def idle(dut) -> None:
    dut.i_clear.value = 0
    dut.i_valid.value = 0
    dut.i_a.value = 0
    dut.i_b.value = 0
    dut.i_drain.value = 0
    dut.i_row_ready.value = 0


async def clear_when_idle(dut) -> None:
    """Wait for o_idle (generous hang guard), then pulse i_clear for one cycle."""
    await wait_until(dut, lambda: int(dut.o_idle.value) == 1, 500, "o_idle before clear")
    await FallingEdge(dut.clk)
    dut.i_clear.value = 1
    await FallingEdge(dut.clk)
    dut.i_clear.value = 0


async def stream_steps(dut, a: np.ndarray, b: np.ndarray, rng, gap_prob: float) -> None:
    """Present the K reduction steps (column k of A, row k of B) with random gaps."""
    k = 0
    while k < a.shape[1]:
        if rng.random() < gap_prob:
            dut.i_valid.value = 0
        else:
            dut.i_valid.value = 1
            dut.i_a.value = pack(a[:, k], DATA_W)
            dut.i_b.value = pack(b[k, :], DATA_W)
            k += 1
        await FallingEdge(dut.clk)
    dut.i_valid.value = 0


async def drain_rows(dut, rng, ready_prob: float, guard: int) -> np.ndarray:
    """Pulse i_drain and collect the N result rows through the row handshake."""
    n = n_of(dut)
    for _ in range(rng.choice([0, 0, 1, 3])):  # optional gap before the drain pulse
        await FallingEdge(dut.clk)
    dut.i_drain.value = 1
    await FallingEdge(dut.clk)
    dut.i_drain.value = 0

    # Handshake sampling: ready is set after a falling edge, and valid/ready/data are sampled in
    # that same time step, i.e. the values the next rising edge will see. A transfer happens at
    # that rising edge iff both are high.
    rows: list[list[int]] = []
    for _ in range(guard):  # generous hang guard, not a latency
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


def cover_tile(k: int, n: int, gap_prob: float) -> None:
    """Functional coverage of one tile (D-034)."""
    if k in (0, 1, n, 128):
        cover("K", {0: "0 (drain only)", 1: "1", n: "N", 128: "128 (K_TILE)"}[k])
    else:
        cover("K", "2 .. N-1" if k < n else "N+1 .. 127")
    if k:
        cover("steps", "with gaps" if gap_prob > 0 else "back to back")


async def run_tile(dut, a: np.ndarray, b: np.ndarray, rng, gap_prob: float, ready_prob: float):
    """Clear, stream K steps, drain, and return the N x N result read through the handshake."""
    cover_tile(a.shape[1], n_of(dut), gap_prob)
    rows = start_handshake_monitor(dut.clk, dut.o_row_valid, dut.i_row_ready, "result rows")
    await clear_when_idle(dut)
    await stream_steps(dut, a, b, rng, gap_prob)
    try:
        return await drain_rows(dut, rng, ready_prob, 100 * n_of(dut) + 4 * a.shape[1] + 100)
    finally:
        rows.cancel()


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
async def test_idle_then_clear_discards_partial_sums(dut):
    """Steps streamed without a drain, then: wait for o_idle, clear, drain -> all zeros.

    o_idle (spec §11.2: no step in flight) must not rise while any step is still being
    accumulated; a clear issued as soon as o_idle rises must leave every accumulator at 0.
    """
    rng = seeded_rng(dut, "idle_clear")
    n = n_of(dut)
    idle(dut)
    await start_clock_and_reset(dut)
    for k_len in (1, 2, n, 2 * n + 1):
        a, b = rand_int8(rng, (n, k_len)), rand_int8(rng, (k_len, n))
        await clear_when_idle(dut)
        await stream_steps(dut, a, b, rng, gap_prob=0.0)
        await clear_when_idle(dut)  # clears as early as o_idle allows
        got = await drain_rows(dut, rng, 1.0, 100 * n + 100)
        np.testing.assert_array_equal(got, np.zeros((n, n)), err_msg=f"K={k_len}")


def random_tile_count() -> int:
    """More random tiles on Verilator, where simulation is fast."""
    return 60 if cocotb.SIM_NAME.lower().startswith("verilator") else 12


@cocotb.test()
async def test_random_tiles_with_gaps_and_backpressure(dut):
    """Back-to-back random tiles; random step gaps and row backpressure; K up to 128."""
    rng = seeded_rng(dut, "random")
    n = n_of(dut)
    idle(dut)
    await start_clock_and_reset(dut)
    tiles = random_tile_count()
    dut._log.info("random tiles: %d on %s", tiles, cocotb.SIM_NAME)
    for t in range(tiles):
        k_len = rng.choice([1, 2, 3, n - 1 or 1, n, n + 1, 17, 64, 128])
        a, b = rand_int8(rng, (n, k_len)), rand_int8(rng, (k_len, n))
        gap = rng.choice([0.0, 0.2, 0.6])
        ready = rng.choice([1.0, 0.5, 0.2])
        got = await run_tile(dut, a, b, rng, gap, ready)
        np.testing.assert_array_equal(got, expected(a, b), err_msg=f"tile {t}, K={k_len}")


# ---------------------------------------------------------------- deliberate violations
# Each runs only under test_sva_assertions_fire (selected by SVA_VIOLATION) and breaks exactly one
# producer obligation of the interface SVA.


@cocotb.test(skip=SVA_VIOLATION != "clear_with_valid")
async def sva_violation_clear_with_valid(dut):
    """i_clear and i_valid in the same cycle."""
    idle(dut)
    await start_clock_and_reset(dut)
    await FallingEdge(dut.clk)
    dut.i_clear.value = 1
    dut.i_valid.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    idle(dut)


@cocotb.test(skip=SVA_VIOLATION != "clear_not_idle")
async def sva_violation_clear_not_idle(dut):
    """i_clear one cycle after a step, while the step is still in flight (o_idle low)."""
    idle(dut)
    await start_clock_and_reset(dut)
    await FallingEdge(dut.clk)
    dut.i_valid.value = 1
    await FallingEdge(dut.clk)
    dut.i_valid.value = 0
    dut.i_clear.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    idle(dut)


@cocotb.test(skip=SVA_VIOLATION != "valid_in_drain")
async def sva_violation_valid_in_drain(dut):
    """A reduction step presented inside the drain window."""
    idle(dut)
    await start_clock_and_reset(dut)
    await FallingEdge(dut.clk)
    dut.i_drain.value = 1
    await FallingEdge(dut.clk)
    dut.i_drain.value = 0
    dut.i_valid.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    idle(dut)


def build_config(sim: str) -> tuple[list[Path], list[str]]:
    """Verilator runs compile the SVA files with assertions enabled; Icarus cannot."""
    if sim == "verilator":
        return SOURCES + SVA_SOURCES, ["--assert"]
    return SOURCES, []


@pytest.mark.parametrize(
    ("sim", "n"),
    [(s, 8) for s in SIMULATORS] + [("verilator", 3), ("icarus", 3), ("icarus", 1)],
)
def test_systolic_array(sim: str, n: int) -> None:
    sources, build_args = build_config(sim)
    run_cocotb(
        sim=sim,
        toplevel="systolic_array",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={"N": n, "DATA_W": DATA_W, "ACC_W": ACC_W},
        extra_build_args=build_args,
    )


@pytest.mark.parametrize(
    ("violation", "assertion"),
    [
        ("clear_with_valid", "a_clear_not_with_valid"),
        ("clear_not_idle", "a_clear_only_when_idle"),
        ("valid_in_drain", "a_drain_window_quiet"),
    ],
)
def test_sva_assertions_fire(violation: str, assertion: str) -> None:
    """Each producer obligation is live: violating it fails the run with that assertion."""
    sources, build_args = build_config("verilator")
    log = SIM_BUILD_DIR / f"systolic_array_sva_violation_{violation}.log"
    # The runner reports a failed simulation as SystemExit, or RuntimeError when logging to a file.
    with pytest.raises((SystemExit, RuntimeError)):
        run_cocotb(
            sim="verilator",
            toplevel="systolic_array",
            sources=sources,
            test_module=Path(__file__).stem,
            parameters={"N": 8, "DATA_W": DATA_W, "ACC_W": ACC_W},
            extra_build_args=build_args,
            testcase=f"sva_violation_{violation}",
            extra_env={"SVA_VIOLATION": violation},
            log_file=log,
            build_tag="sva_violation",
        )
    failed = [line for line in log.read_text().splitlines() if "Assertion failed" in line]
    assert failed, f"no assertion fired; see {log}"
    assert assertion in failed[0], f"first failing assertion was not {assertion}: {failed[0]}"
