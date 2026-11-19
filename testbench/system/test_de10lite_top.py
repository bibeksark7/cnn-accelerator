"""de10lite_top: the board top as the board sees it (pins only), on Verilator with short reset
and debounce settings (POR_CYCLES = 16, DEBOUNCE_W = 3).

Power-up is modelled by depositing 0 into reset_gen's registers (the MAX 10 power-up state).
For several images: SW[3:0] selects it, a bouncing KEY[0] press starts it; while busy LEDR[0] is
on and HEX0 shows '-'; a press while busy is ignored; when done LEDR[1] is on, HEX0 shows the
golden class, HEX1 the true label, HEX5..HEX2 CYC_TOTAL >> 4 in hex (from
testbench/reports/perf_counters.json). KEY[1] resets the display (HEX0 blank, LEDR off).
"""

from __future__ import annotations

import json
from pathlib import Path

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, with_timeout

from common.runner import RTL_DIR, run_cocotb, sv_string
from common.sim import CLK_PERIOD_NS, seeded_rng
from model import golden

MEM_DIR = Path(golden.__file__).parent / "artifacts" / "mem"
REPORTS = Path(__file__).resolve().parents[1] / "reports"
CYC_SHIFT = 4
# Lit segments (bit 0 = a ... bit 6 = g) of 0..F; the board pattern is active low, dp off.
LIT = [
    0x3F,
    0x06,
    0x5B,
    0x4F,
    0x66,
    0x6D,
    0x7D,
    0x07,
    0x7F,
    0x6F,
    0x77,
    0x7C,
    0x39,
    0x5E,
    0x79,
    0x71,
]
SEG = {d: 0x80 | (~on & 0x7F) for d, on in enumerate(LIT)}
SEG.update({"blank": 0xFF, "-": 0x80 | (~0x40 & 0x7F)})


def char_of(seg: int):
    for k, v in SEG.items():
        if v == seg:
            return k
    return f"?{seg:#04x}"


async def cycles(dut, n: int) -> None:
    for _ in range(n):
        await FallingEdge(dut.MAX10_CLK1_50)


async def press(dut, key: int, rng) -> None:
    """A bouncing press and release of KEY[key] (active low)."""
    other = 1 - key
    bounces = [(0, 2), (1, 1), (0, 3), (1, 2), (0, 40), (1, 2), (0, 1), (1, 40)]
    for level, hold in bounces:
        await FallingEdge(dut.MAX10_CLK1_50)
        dut.KEY.value = (level << key) | (1 << other)
        await cycles(dut, hold + rng.randint(0, 1))


async def wait_led(dut, bit: int, value: int, limit: int) -> None:
    for _ in range(limit):
        await FallingEdge(dut.MAX10_CLK1_50)
        await ReadOnly()
        if (int(dut.LEDR.value) >> bit) & 1 == value:
            return
    raise TimeoutError(f"LEDR[{bit}] never became {value}")


@cocotb.test()
async def test_board_demo(dut):
    rng = seeded_rng(dut, "board")
    demo = json.loads((MEM_DIR / "demo.json").read_text())
    cyc = json.loads((REPORTS / "perf_counters.json").read_text())["counters"]["cyc_total"]["max"]
    rg = dut.u_reset_gen
    for sig in (rg.por_cnt_q, rg.rst1_q, rg.rst2_q):  # power-up state
        sig.value = 0
    dut.KEY.value = 0b11
    dut.SW.value = 0
    cocotb.start_soon(Clock(dut.MAX10_CLK1_50, CLK_PERIOD_NS, unit="ns").start())
    await cycles(dut, 40)
    await ReadOnly()
    assert int(dut.LEDR.value) == 0 and int(dut.HEX0.value) == SEG["blank"], "after power-up"
    for sel in (0, 7, 13, 3):
        await FallingEdge(dut.MAX10_CLK1_50)
        dut.SW.value = sel | (rng.getrandbits(6) << 4)  # SW[9:4] are ignored
        await cycles(dut, 5)
        await press(dut, 0, rng)
        await wait_led(dut, 0, 1, 200)  # returns in the ReadOnly phase
        assert char_of(int(dut.HEX0.value)) == "-", "HEX0 while busy"
        if sel == 13:
            await press(dut, 0, rng)  # ignored: busy
        await with_timeout(wait_led(dut, 0, 0, 100_000), 5000, "us")
        await cycles(dut, 2)
        await ReadOnly()
        leds = int(dut.LEDR.value)
        assert leds & 0b111 == 0b010 and not leds >> 9, f"image {sel}: LEDR {leds:#05x}"
        shown = [char_of(int(getattr(dut, f"HEX{i}").value)) for i in range(6)]
        want_cyc = min(cyc >> CYC_SHIFT, 0xFFFF)
        want = [demo["golden_class"][sel], demo["label"][sel]]
        want += [(want_cyc >> (4 * i)) & 0xF for i in range(4)]
        assert shown == want, f"image {sel}: HEX0..5 {shown}, want {want}"
        await cycles(dut, 3 * (1 << 3))
        await ReadOnly()
        assert not int(dut.LEDR.value) & 1, f"image {sel}: a second run started"
        dut._log.info("image %d: HEX0 %s, HEX1 %s, HEX5..2 %04x", sel, shown[0], shown[1], want_cyc)
    await press(dut, 1, rng)  # reset
    await cycles(dut, 10)
    await ReadOnly()
    assert int(dut.LEDR.value) == 0 and int(dut.HEX0.value) == SEG["blank"], "after KEY[1]"


@pytest.mark.parametrize("sim", ["verilator"])
def test_de10lite_top(sim: str) -> None:
    params: dict[str, object] = {
        f"{k}_INIT": sv_string(MEM_DIR / f"{k.lower()}.hex")
        for k in ("IMG", "WGT", "PARAM", "DESC", "LABEL")
    }
    params.update(POR_CYCLES=16, DEBOUNCE_W=3, CYC_SHIFT=CYC_SHIFT)
    run_cocotb(
        sim=sim,
        toplevel="de10lite_top",
        sources=sorted(RTL_DIR.rglob("*.sv")),
        test_module=Path(__file__).stem,
        parameters=params,
    )
