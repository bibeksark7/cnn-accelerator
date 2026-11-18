"""buf_port_mux: only the one-hot owner's requests reach the buffer ports.

Runs through a harness (testbench/hdl/buf_port_mux_tb.sv) that adds the clock the ownership
assertions are sampled on. Icarus runs also send requests from non-owners and check they are
ignored; Verilator runs bind the assertions, keep traffic legal, and test_mux_sva_fires shows
each assertion is live.
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly

from common.bits import pack
from common.runner import RTL_DIR, SVA_DIR, run_cocotb, run_sva_violation
from common.sim import seeded_rng, start_clock_and_reset

HDL_DIR = Path(__file__).resolve().parents[1] / "hdl"
SOURCES = [RTL_DIR / "mem" / "buf_port_mux.sv", HDL_DIR / "buf_port_mux_tb.sv"]
SVA_SOURCES = [SVA_DIR / "buf_port_mux_sva.sv", HDL_DIR / "buf_port_mux_tb_bind.sv"]
LEGAL_ONLY = os.environ.get("TB_LEGAL_ONLY", "0") == "1"
SVA_VIOLATION = os.environ.get("SVA_VIOLATION", "")


def dims(dut) -> tuple[int, int, int]:
    k = len(dut.i_owner)
    return k, len(dut.i_raddr) // k, len(dut.i_wdata) // k


def drive(dut, owner, re, raddr, we, waddr, wdata, aw, width) -> None:
    dut.i_owner.value = owner
    dut.i_re.value = pack(re, 1) & ((1 << len(re)) - 1)
    dut.i_raddr.value = sum(a << (i * aw) for i, a in enumerate(raddr))
    dut.i_we.value = pack(we, 1) & ((1 << len(we)) - 1)
    dut.i_waddr.value = sum(a << (i * aw) for i, a in enumerate(waddr))
    dut.i_wdata.value = sum(d << (i * width) for i, d in enumerate(wdata))


@cocotb.test(skip=SVA_VIOLATION != "")
async def test_random_ownership(dut):
    rng = seeded_rng(dut, "mux")
    k, aw, width = dims(dut)
    dut.i_owner.value = dut.i_re.value = dut.i_we.value = 0
    await start_clock_and_reset(dut)
    for cycle in range(3000):
        await FallingEdge(dut.clk)
        owner_idx = rng.randrange(-1, k)  # -1: no owner
        owner = 0 if owner_idx < 0 else 1 << owner_idx
        re = [rng.randint(0, 1) for _ in range(k)]
        we = [rng.randint(0, 1) for _ in range(k)]
        if LEGAL_ONLY:  # only the owner may request
            re = [r if i == owner_idx else 0 for i, r in enumerate(re)]
            we = [w if i == owner_idx else 0 for i, w in enumerate(we)]
        raddr = [rng.getrandbits(aw) for _ in range(k)]
        waddr = [rng.getrandbits(aw) for _ in range(k)]
        wdata = [rng.getrandbits(width) for _ in range(k)]
        drive(dut, owner, re, raddr, we, waddr, wdata, aw, width)
        await ReadOnly()
        if owner_idx < 0:
            want = (0, 0, 0, 0, 0)
        else:
            o = owner_idx
            want = (re[o], raddr[o], we[o], waddr[o], wdata[o])
        got = (
            int(dut.o_re.value),
            int(dut.o_raddr.value),
            int(dut.o_we.value),
            int(dut.o_waddr.value),
            int(dut.o_wdata.value),
        )
        assert got == want, f"cycle {cycle}: owner {owner_idx}: got {got}, want {want}"


async def violation(dut, owner: int, re: int, we: int) -> None:
    dut.i_owner.value = dut.i_re.value = dut.i_we.value = 0
    await start_clock_and_reset(dut)
    await FallingEdge(dut.clk)
    dut.i_owner.value, dut.i_re.value, dut.i_we.value = owner, re, we
    for _ in range(3):
        await FallingEdge(dut.clk)


@cocotb.test(skip=SVA_VIOLATION != "two_owners")
async def sva_violation_two_owners(dut):
    await violation(dut, owner=0b011, re=0, we=0)


@cocotb.test(skip=SVA_VIOLATION != "non_owner_read")
async def sva_violation_non_owner_read(dut):
    await violation(dut, owner=0b001, re=0b010, we=0)


@cocotb.test(skip=SVA_VIOLATION != "non_owner_write")
async def sva_violation_non_owner_write(dut):
    await violation(dut, owner=0b001, re=0, we=0b100)


CONFIGS = [  # (simulator, NUM_OWNERS, WIDTH, AW)
    ("icarus", 3, 8, 13),
    ("icarus", 4, 64, 10),
    ("verilator", 3, 8, 13),
    ("verilator", 2, 64, 6),
]


def build(sim: str) -> tuple[list[Path], list[str], dict[str, str]]:
    if sim == "verilator":
        return SOURCES + SVA_SOURCES, ["--assert"], {"TB_LEGAL_ONLY": "1"}
    return SOURCES, [], {"TB_LEGAL_ONLY": "0"}


@pytest.mark.parametrize(("sim", "owners", "width", "aw"), CONFIGS)
def test_buf_port_mux(sim: str, owners: int, width: int, aw: int) -> None:
    sources, args, env = build(sim)
    run_cocotb(
        sim=sim,
        toplevel="buf_port_mux_tb",
        sources=sources,
        test_module=Path(__file__).stem,
        parameters={"NUM_OWNERS": owners, "WIDTH": width, "AW": aw},
        extra_build_args=args,
        extra_env=env,
    )


@pytest.mark.parametrize(
    ("violation", "assertion"),
    [
        ("two_owners", "a_owner_onehot0"),
        ("non_owner_read", "a_only_owner_reads"),
        ("non_owner_write", "a_only_owner_writes"),
    ],
)
def test_mux_sva_fires(violation: str, assertion: str) -> None:
    sources, args, env = build("verilator")
    run_sva_violation(
        toplevel="buf_port_mux_tb",
        sources=sources,
        test_module=Path(__file__).stem,
        violation=violation,
        assertion=assertion,
        parameters={"NUM_OWNERS": 3, "WIDTH": 8, "AW": 13},
        extra_build_args=args,
        extra_env=env,
    )
