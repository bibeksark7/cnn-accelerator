"""sram_1r1w: 1-cycle synchronous read, read hold, concurrent read/write, $readmemh preload."""

import random
from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, SIM_BUILD_DIR, SIMULATORS, run_cocotb, sv_string
from common.sim import seeded_rng

WIDTH, DEPTH = 64, 256
INIT_SEED = 7


def init_contents() -> list[int]:
    rng = random.Random(INIT_SEED)
    return [rng.getrandbits(WIDTH) for _ in range(DEPTH)]


def write_init_file(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{w:016x}\n" for w in init_contents()))
    return path


async def start(dut) -> None:
    from cocotb.clock import Clock

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.i_we.value = 0
    dut.i_re.value = 0
    dut.i_waddr.value = 0
    dut.i_raddr.value = 0
    dut.i_wdata.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_preload_then_random_traffic(dut):
    """Read back the init file, then random reads/writes against a model.

    Reads and writes to *different* addresses may share a cycle; same-address read/write in one
    cycle is unspecified (spec: never done) and is not generated.
    """
    rng = seeded_rng(dut, "sram")
    await start(dut)
    model = init_contents()

    for addr in range(DEPTH):  # preload check, back-to-back reads
        dut.i_re.value, dut.i_raddr.value = 1, addr
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.o_rdata.value) == model[addr], f"init word {addr}"
        await FallingEdge(dut.clk)

    last_read = None
    for cycle in range(3000):
        we, re = rng.random() < 0.5, rng.random() < 0.6
        waddr, raddr = rng.randrange(DEPTH), rng.randrange(DEPTH)
        if we and re and waddr == raddr:
            re = False
        wdata = rng.getrandbits(WIDTH)
        dut.i_we.value, dut.i_waddr.value, dut.i_wdata.value = int(we), waddr, wdata
        dut.i_re.value, dut.i_raddr.value = int(re), raddr
        await RisingEdge(dut.clk)
        await ReadOnly()
        if re:
            last_read = model[raddr]  # value before this cycle's write
        if last_read is not None:
            assert int(dut.o_rdata.value) == last_read, f"cycle {cycle}: read data (or hold) wrong"
        if we:
            model[waddr] = wdata
        await FallingEdge(dut.clk)


@pytest.mark.parametrize("sim", SIMULATORS)
def test_sram_1r1w(sim: str) -> None:
    init = write_init_file(SIM_BUILD_DIR / "init" / f"sram_init_{WIDTH}x{DEPTH}.hex")
    run_cocotb(
        sim=sim,
        toplevel="sram_1r1w",
        sources=[RTL_DIR / "mem" / "sram_1r1w.sv"],
        test_module=Path(__file__).stem,
        parameters={"WIDTH": WIDTH, "DEPTH": DEPTH, "INIT_FILE": sv_string(init)},
    )
