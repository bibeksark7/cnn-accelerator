"""hex7seg: every code against an independent segment table (active low, decimal point off)."""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import Timer

from common.runner import RTL_DIR, SIMULATORS, run_cocotb

# Lit segments per character, as letters a..g (Terasic order: bit 0 = a ... bit 6 = g).
LIT = {
    0: "abcdef", 1: "bc", 2: "abdeg", 3: "abcdg", 4: "bcfg", 5: "acdfg", 6: "acdefg", 7: "abc",
    8: "abcdefg", 9: "abcdfg", 10: "abcefg", 11: "cdefg", 12: "adef", 13: "bcdeg", 14: "adefg",
    15: "aefg", 16: "", 17: "g", 18: "adefg",
}  # fmt: skip


def expected(code: int) -> int:
    lit = LIT.get(code, "")
    on = sum(1 << "abcdefg".index(c) for c in lit)
    return 0x80 | (~on & 0x7F)  # active low; bit 7 (decimal point) off = 1


@cocotb.test()
async def test_every_code(dut):
    for code in range(32):
        dut.i_code.value = code
        await Timer(1, "ns")
        got = int(dut.o_seg.value)
        assert got == expected(code), f"code {code}: {got:#04x}, want {expected(code):#04x}"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_hex7seg(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="hex7seg",
        sources=[RTL_DIR / "top" / "hex7seg.sv"],
        test_module=Path(__file__).stem,
    )
