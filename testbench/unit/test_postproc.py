"""postproc (spec §3, §3.1): bias, requantize, saturate, ReLU, FC bypass vs model/golden.py.

Results are checked element by element (via the tag) against golden.requantize, under random
input gaps and random output backpressure. Directed cases hit rounding ties, saturation at both
ends, ReLU clamping, S = 1 and 47, M at both ends, and int32 extremes of y = acc + bias.
"""

from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import ClockCycles

from common.bits import to_signed, to_unsigned
from common.coverage import cover, start_handshake_monitor
from common.handshake import collect_stream, drive_stream
from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset
from model import golden

ACC_W, TAG_W = 32, 16
I32_MIN, I32_MAX = -(2**31), 2**31 - 1


def expected(item: dict) -> dict:
    y = item["acc"] + item["bias"]
    assert I32_MIN <= y <= I32_MAX
    out = {"tag": item["tag"], "y": y}
    if item["rq"]:
        q = int(golden.requantize(np.array([y]), item["m"], item["s"])[0])
        out["q8"] = max(q, 0) if item["relu"] else q
    return out


def make_item(tag: int, y: int, m: int, s: int, rq: int, relu: int, rng) -> dict:
    """Split y into acc + bias with both in int32 range."""
    lo, hi = max(I32_MIN, y - I32_MAX), min(I32_MAX, y - I32_MIN)
    bias = rng.randint(lo, hi)
    return {"tag": tag, "acc": y - bias, "bias": bias, "m": m, "s": s, "rq": rq, "relu": relu}


def directed_items(rng) -> list[dict]:
    m_mid = 1 << 15
    ys_ms = [
        (5, m_mid, 16), (-5, m_mid, 16), (3, m_mid, 16), (-3, m_mid, 16),  # rounding ties
        (1, m_mid, 16), (-1, m_mid, 16),
        (256, m_mid, 15), (-256, m_mid, 15), (127, m_mid, 15), (-128, m_mid, 15),  # saturation
        (I32_MAX, golden.M_MAX, 1), (I32_MIN, golden.M_MAX, 1),  # largest products
        (I32_MAX, golden.M_MIN, 47), (I32_MIN, golden.M_MIN, 47),  # largest shift
        (0, golden.M_MAX, 1), (-1, golden.M_MAX, 47),
    ]  # fmt: skip
    items = []
    for y, m, s in ys_ms:
        for relu in (0, 1):
            items.append(make_item(len(items), y, m, s, 1, relu, rng))
    for y in (I32_MAX, I32_MIN, 0, -7):  # FC bypass: only y matters
        items.append(make_item(len(items), y, 0, 0, 0, 0, rng))
    return items


def random_items(rng, count: int, start_tag: int) -> list[dict]:
    items = []
    for i in range(count):
        # Mostly the network's range (exercises every output code), sometimes all of int32.
        full_range = rng.random() < 0.1
        y = rng.randint(I32_MIN, I32_MAX) if full_range else rng.randint(-200_000, 200_000)
        m = rng.randint(golden.M_MIN, golden.M_MAX)
        s = rng.randint(golden.S_MIN, golden.S_MAX) if rng.random() < 0.3 else rng.randint(14, 27)
        rq = int(rng.random() < 0.9)
        items.append(
            make_item(start_tag + i, y, m if rq else 0, s if rq else 0, rq, rng.randint(0, 1), rng)
        )
    return items


def set_payload(dut, item: dict) -> None:
    dut.i_acc.value = to_unsigned(item["acc"], ACC_W)
    dut.i_bias.value = to_unsigned(item["bias"], ACC_W)
    dut.i_m.value = item["m"]
    dut.i_s.value = item["s"]
    dut.i_requant_en.value = item["rq"]
    dut.i_relu_en.value = item["relu"]
    dut.i_tag.value = item["tag"]


def get_payload(dut) -> dict:
    return {
        "tag": int(dut.o_tag.value),
        "y": to_signed(int(dut.o_y.value), ACC_W),
        "q8": to_signed(int(dut.o_q8.value), 8),
    }


def cover_item(item: dict) -> None:
    """Functional coverage of one element's arithmetic (D-034)."""
    if not item["rq"]:
        cover("mode", "FC bypass")
        return
    cover("mode", "requantize")
    y, m, s = item["acc"] + item["bias"], item["m"], item["s"]
    r = (y * m + (1 << (s - 1))) >> s  # before saturation (Python >> is arithmetic)
    if r > 127:
        cover("saturation", "high")
    elif r < -128:
        cover("saturation", "low")
    else:
        cover("saturation", "in range")
    if (y * m) & ((1 << s) - 1) == 1 << (s - 1):
        cover("rounding", "exact tie, positive" if y > 0 else "exact tie, negative")
    if item["relu"]:
        cover("ReLU", "clamped" if r < 0 else "passed")


async def run_stream(dut, items, rng, idle_prob, ready_prob) -> None:
    for item in items:
        cover_item(item)
    sink = cocotb.start_soon(
        collect_stream(
            dut.clk, dut.o_valid, dut.i_ready, len(items), lambda: get_payload(dut), rng, ready_prob
        )
    )
    await drive_stream(
        dut.clk, dut.i_valid, dut.o_ready, items, lambda it: set_payload(dut, it), rng, idle_prob
    )
    got = await sink
    for item, out in zip(items, got, strict=True):
        want = expected(item)
        assert out["tag"] == want["tag"], f"order: got tag {out['tag']}, want {want['tag']}"
        assert out["y"] == want["y"], f"tag {item['tag']}: y {out['y']} != {want['y']} ({item})"
        if item["rq"]:
            assert out["q8"] == want["q8"], (
                f"tag {item['tag']}: q8 {out['q8']} != {want['q8']} ({item})"
            )


async def setup(dut) -> None:
    dut.i_valid.value = 0
    dut.i_ready.value = 0
    start_handshake_monitor(dut.clk, dut.i_valid, dut.o_ready, "input handshake")
    start_handshake_monitor(dut.clk, dut.o_valid, dut.i_ready, "output handshake")
    await start_clock_and_reset(dut)
    await ClockCycles(dut.clk, 1)


@cocotb.test()
async def test_directed(dut):
    rng = seeded_rng(dut, "directed")
    await setup(dut)
    await run_stream(dut, directed_items(rng), rng, idle_prob=0.0, ready_prob=1.0)


@cocotb.test()
async def test_random_with_gaps_and_backpressure(dut):
    rng = seeded_rng(dut, "random")
    await setup(dut)
    for ready_prob, idle_prob in ((1.0, 0.0), (0.5, 0.3), (0.15, 0.0), (1.0, 0.7)):
        await run_stream(dut, random_items(rng, 600, 0), rng, idle_prob, ready_prob)


@pytest.mark.parametrize("sim", SIMULATORS)
def test_postproc(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="postproc",
        sources=[RTL_DIR / "post" / "postproc.sv"],
        test_module=Path(__file__).stem,
        parameters={"ACC_W": ACC_W, "TAG_W": TAG_W},
    )
