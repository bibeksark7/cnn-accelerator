"""axil_ram: the SoC RAM (spec §13.5) through its AXI4-Lite port.

  test_init_image     every word reads back as the $readmemh image (word 0 first, little-endian)
  test_random_access  random byte, halfword and word writes (any WSTRB, including 0) and reads
                      against a byte-array model; first and last words included; every response
                      OKAY; address bits [1:0] ignored

Verilator runs bind testbench/sva/axil_slave_port_bind.sv (--assert).
"""

from __future__ import annotations

import random
from pathlib import Path

import cocotb
import pytest

from common.axil import AxilMaster
from common.runner import RTL_DIR, SIM_BUILD_DIR, SIMULATORS, SVA_DIR, run_cocotb, sv_string
from common.sim import seeded_rng, start_clock_and_reset

BYTES = 2048
INIT_SEED = 7


def init_words() -> list[int]:
    rng = random.Random(INIT_SEED)
    return [rng.getrandbits(32) for _ in range(BYTES // 4)]


def init_file() -> Path:
    path = SIM_BUILD_DIR / "axil_ram_init.hex"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{w:08x}\n" for w in init_words()))
    return path


@cocotb.test()
async def test_init_image(dut):
    rng = seeded_rng(dut, "ram_init")
    master = AxilMaster(dut, rng)
    await start_clock_and_reset(dut)
    for i, want in enumerate(init_words()):
        got = await master.read_ok(4 * i)
        assert got == want, f"word {i}: {got:#010x}, want {want:#010x}"


@cocotb.test()
async def test_random_access(dut):
    rng = seeded_rng(dut, "ram_random")
    master = AxilMaster(dut, rng)
    await start_clock_and_reset(dut)
    model = bytearray(b"".join(w.to_bytes(4, "little") for w in init_words()))
    for _ in range(600):
        word = rng.choice([0, BYTES // 4 - 1, rng.randrange(BYTES // 4)])
        addr = 4 * word + rng.getrandbits(2)
        if rng.random() < 0.55:
            data = rng.getrandbits(32)
            strb = rng.choice([0x1, 0x2, 0x4, 0x8, 0x3, 0xC, 0xF, 0xF, 0x0, rng.getrandbits(4)])
            await master.write_ok(addr, data, strb)
            for b in range(4):
                if strb >> b & 1:
                    model[4 * word + b] = (data >> (8 * b)) & 0xFF
        else:
            got = await master.read_ok(addr)
            want = int.from_bytes(model[4 * word : 4 * word + 4], "little")
            assert got == want, f"word {word}: {got:#010x}, want {want:#010x}"


@pytest.mark.parametrize("sim", SIMULATORS)
def test_axil_ram(sim: str) -> None:
    sources = [RTL_DIR / "mem" / "sram_1r1w.sv", RTL_DIR / "axi" / "axil_slave_port.sv"]
    sources.append(RTL_DIR / "axi" / "axil_ram.sv")
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
        toplevel="axil_ram",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={"BYTES": BYTES, "INIT_FILE": sv_string(init_file())},
        extra_build_args=args,
    )
