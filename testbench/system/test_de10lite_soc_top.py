"""de10lite_soc_top: the SoC at the DE10-Lite pins (spec §13.7), on Verilator with the smoke
firmware (firmware/apps/smoke) and short reset and debounce settings (POR_CYCLES = 16,
DEBOUNCE_W = 3), every SoC assertion bound.

  test_board_pins  after power-up the firmware boots and runs preloaded image 0: LEDR[1] lights,
                   HEX0 shows the golden class (segments active low), HEX5..HEX1 blank, LEDR[9]
                   (trap) off; SW[9:0] reach the firmware through the synchronizers; a bouncing
                   KEY[0] press sets KEY_EVT once its debounced level is stable, and the KEY
                   register follows the held key; KEY[1] resets the SoC and the firmware runs again
"""

from __future__ import annotations

import json
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly

from common import firmware
from common.runner import run_cocotb, sv_string
from common.sim import CLK_PERIOD_NS, seeded_rng
from system.test_de10lite_top import SEG, char_of, cycles, press
from system.test_soc import MEM_DIR, TB_SYMBOLS, quick_subset, sources

MB_PASS = 0x600D_0000


def ram_word(dut, addr: int) -> int:
    return int(dut.u_soc_top.u_axil_ram.u_sram_1r1w.mem[addr >> 2].value)


async def wait_pass(dut, limit: int) -> None:
    for n in range(limit):
        await cycles(dut, 256)
        await ReadOnly()
        if int(dut.u_soc_top.o_mailbox.value) == MB_PASS:
            return
        if n % 64 == 0:
            await FallingEdge(dut.MAX10_CLK1_50)
    raise TimeoutError("firmware never reported PASS")


@cocotb.test()
async def test_board_pins(dut):
    rng = seeded_rng(dut, "soc_board")
    syms = json.loads(Path(TB_SYMBOLS).read_text())
    demo = json.loads((MEM_DIR / "demo.json").read_text())
    qs = quick_subset()
    rg = dut.u_reset_gen
    for sig in (rg.por_cnt_q, rg.rst1_q, rg.rst2_q):  # power-up state
        sig.value = 0
    dut.KEY.value = 0b11
    dut.SW.value = 0x2A5
    cocotb.start_soon(Clock(dut.MAX10_CLK1_50, CLK_PERIOD_NS, unit="ns").start())
    for boot in (1, 2):
        await wait_pass(dut, 2000)
        await FallingEdge(dut.MAX10_CLK1_50)
        await ReadOnly()
        result = demo["golden_class"][0]
        assert int(dut.LEDR.value) == 0b10, f"boot {boot}: LEDR {int(dut.LEDR.value):#05x}"
        shown = [char_of(int(getattr(dut, f"HEX{i}").value)) for i in range(6)]
        assert shown == [result, *["blank"] * 5], f"boot {boot}: HEX {shown}"
        assert int(dut.HEX0.value) == SEG[result]
        sw = ram_word(dut, syms["results"] + 4)
        assert sw == 0x2A5, f"SW seen by the firmware {sw:#x}"
        assert ram_word(dut, syms["results"] + 12) == int(
            qs["pred"][demo["quick_subset_positions"][0]]
        )
        gpio = dut.u_soc_top.u_axil_gpio
        assert int(gpio.key_evt_q.value) == 0
        # A bouncing KEY[0] press: KEY_EVT set once, the KEY register follows the held key.
        await FallingEdge(dut.MAX10_CLK1_50)
        await press(dut, 0, rng)
        await cycles(dut, 20)
        await ReadOnly()
        assert int(gpio.key_evt_q.value) == 1, "KEY[0] press did not reach KEY_EVT"
        assert int(gpio.i_key_level.value) == 0, "KEY level not released"
        if boot == 1:
            # KEY[1]: reset; the firmware restarts (MAILBOX and LEDs clear) and passes again.
            await FallingEdge(dut.MAX10_CLK1_50)
            dut.KEY.value = 0b01
            await cycles(dut, 10)
            await ReadOnly()
            assert int(dut.LEDR.value) == 0, "LEDs not cleared by KEY[1]"
            await FallingEdge(dut.MAX10_CLK1_50)
            dut.KEY.value = 0b11


def test_de10lite_soc_top() -> None:
    fw = firmware.build("smoke")
    sym_file = fw.out / "symbols.json"
    sym_file.write_text(json.dumps(fw.symbols()))
    run_cocotb(
        sim="verilator",
        toplevel="de10lite_soc_top",
        sources=sources(),
        test_module=Path(__file__).stem,
        parameters={
            "RAM_INIT": sv_string(fw.hex),
            "IMG_INIT": sv_string(MEM_DIR / "img.hex"),
            "WGT_INIT": sv_string(MEM_DIR / "wgt.hex"),
            "PARAM_INIT": sv_string(MEM_DIR / "param.hex"),
            "DESC_INIT": sv_string(MEM_DIR / "desc.hex"),
            "POR_CYCLES": 16,
            "DEBOUNCE_W": 3,
        },
        extra_build_args=["--assert"],
        extra_env={"TB_SYMBOLS": str(sym_file)},
    )
