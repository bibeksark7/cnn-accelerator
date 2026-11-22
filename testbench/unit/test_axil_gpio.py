"""axil_gpio: board I/O registers (spec §13.6) through their AXI4-Lite port.

  test_reset_values   LEDR 0, HEX 0x2108_4210 (all blank), KEY_EVT 0, MAILBOX 0; outputs match
  test_registers      LEDR (9 bits), HEX (30 bits) and MAILBOX read back what was written and
                      drive their outputs; SW and KEY follow the inputs and ignore writes;
                      unmapped offsets read 0 and ignore writes; address bits [1:0] ignored;
                      every full-word access OKAY
  test_partial_write  a write with WSTRB != 4'b1111 to any register gets SLVERR and changes nothing
  test_key_event      KEY_EVT is set by a press pulse, kept until written 1 (a 0 write keeps it),
                      and a press in the same cycle as the clearing write leaves it set

Verilator runs bind testbench/sva/axil_slave_port_bind.sv (--assert).
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, RisingEdge

from common.axil import OKAY, SLVERR, AxilMaster, Timing
from common.runner import RTL_DIR, SIMULATORS, SVA_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

LEDR, HEX, SW, KEY, KEY_EVT, MAILBOX = 0x000, 0x004, 0x008, 0x00C, 0x010, 0x014
HEX_BLANK = 0x2108_4210


async def setup(dut, name: str, timing: Timing | None = None) -> AxilMaster:
    rng = seeded_rng(dut, name)
    master = AxilMaster(dut, rng, timing=timing)
    dut.i_sw.value = 0
    dut.i_key_level.value = 0
    dut.i_key_press.value = 0
    await start_clock_and_reset(dut)
    return master


@cocotb.test()
async def test_reset_values(dut):
    m = await setup(dut, "gpio_reset")
    for addr, want in ((LEDR, 0), (HEX, HEX_BLANK), (KEY_EVT, 0), (MAILBOX, 0)):
        assert await m.read_ok(addr) == want, f"{addr:#05x} after reset"
    assert int(dut.o_ledr.value) == 0
    assert int(dut.o_hex_code.value) == HEX_BLANK
    assert int(dut.o_mailbox.value) == 0


@cocotb.test()
async def test_registers(dut):
    m = await setup(dut, "gpio_regs")
    rng = m.rng
    for _ in range(40):
        v = rng.getrandbits(32)
        await m.write_ok(LEDR | rng.getrandbits(2), v)
        assert await m.read_ok(LEDR) == v & 0x1FF and int(dut.o_ledr.value) == v & 0x1FF
        await m.write_ok(HEX, v)
        assert await m.read_ok(HEX | 3) == v & 0x3FFF_FFFF
        assert int(dut.o_hex_code.value) == v & 0x3FFF_FFFF
        await m.write_ok(MAILBOX, v)
        assert await m.read_ok(MAILBOX) == v and int(dut.o_mailbox.value) == v
        sw, key = rng.getrandbits(10), rng.getrandbits(1)
        await FallingEdge(dut.clk)
        dut.i_sw.value, dut.i_key_level.value = sw, key
        await m.write_ok(SW, ~sw)  # read-only: ignored
        await m.write_ok(KEY, ~key)
        assert await m.read_ok(SW) == sw and await m.read_ok(KEY) == key
    for addr in (0x018, 0x01C, 0x100, 0xFFC):
        await m.write_ok(addr, 0xFFFF_FFFF)
        assert await m.read_ok(addr) == 0, f"unmapped {addr:#05x}"
    regs = {a: await m.read_ok(a) for a in (LEDR, HEX, MAILBOX)}
    for addr in (0x018, 0x100):
        await m.write_ok(addr, 0)
    assert {a: await m.read_ok(a) for a in regs} == regs, "an unmapped write changed a register"


@cocotb.test()
async def test_partial_write(dut):
    m = await setup(dut, "gpio_partial")
    await m.write_ok(LEDR, 0x0A5)
    await m.write_ok(HEX, 0x1234_5678)
    await m.write_ok(MAILBOX, 0xDEAD_BEEF)
    dut.i_key_press.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.i_key_press.value = 0
    before = {a: await m.read_ok(a) for a in (LEDR, HEX, KEY_EVT, MAILBOX)}
    for addr in (LEDR, HEX, KEY_EVT, MAILBOX, 0x018):
        for strb in (0x0, 0x1, 0x3, 0x7, 0xE, 0x8):
            resp = await m.write(addr, 0xFFFF_FFFF if addr != KEY_EVT else 1, strb)
            assert resp == SLVERR, f"{addr:#05x} strb {strb:#x}: resp {resp}"
    after = {a: await m.read_ok(a) for a in before}
    assert after == before, f"a partial write changed a register: {before} -> {after}"
    assert before[KEY_EVT] == 1


@cocotb.test()
async def test_key_event(dut):
    m = await setup(dut, "gpio_key", Timing(max_skew=0, max_ready_delay=0, ready_early=1.0))

    async def pulse():
        await FallingEdge(dut.clk)
        dut.i_key_press.value = 1
        await FallingEdge(dut.clk)
        dut.i_key_press.value = 0

    assert await m.read_ok(KEY_EVT) == 0
    await pulse()
    assert await m.read_ok(KEY_EVT) == 1
    await m.write_ok(KEY_EVT, 0)  # writing 0 does not clear
    assert await m.read_ok(KEY_EVT) == 1
    await m.write_ok(KEY_EVT, 1)
    assert await m.read_ok(KEY_EVT) == 0

    await pulse()
    assert await m.read_ok(KEY_EVT) == 1
    # A press in exactly the cycle the clearing write is performed.
    watcher = cocotb.start_soon(_press_when_request(dut))
    resp = await m.write(KEY_EVT, 1)
    await watcher
    assert resp == OKAY
    assert await m.read_ok(KEY_EVT) == 1, "a press in the clearing cycle was lost"
    await m.write_ok(KEY_EVT, 1)
    assert await m.read_ok(KEY_EVT) == 0


async def _press_when_request(dut) -> None:
    """Raise i_key_press for exactly the cycle in which the port presents a write request."""
    for _ in range(1000):
        await FallingEdge(dut.clk)
        port = dut.u_axil_slave_port
        if int(port.o_req_valid.value) and int(port.o_req_we.value):
            dut.i_key_press.value = 1
            await FallingEdge(dut.clk)
            dut.i_key_press.value = 0
            return
    raise TimeoutError("no write request")


@pytest.mark.parametrize("sim", SIMULATORS)
def test_axil_gpio(sim: str) -> None:
    sources = [RTL_DIR / "axi" / "axil_slave_port.sv", RTL_DIR / "axi" / "axil_gpio.sv"]
    args: list[str] = []
    if sim == "verilator":
        sources += [
            SVA_DIR / "valid_ready_sva.sv",
            SVA_DIR / "axil_resp_order_sva.sv",
            SVA_DIR / "req_rsp_sva.sv",
            SVA_DIR / "axil_slave_port_bind.sv",
        ]
        args = ["--assert"]
    run_cocotb(
        sim=sim,
        toplevel="axil_gpio",
        sources=sources,
        test_module=Path(__file__).stem,
        extra_build_args=args,
    )
