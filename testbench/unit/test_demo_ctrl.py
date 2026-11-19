"""demo_ctrl: random start presses, busy periods and host traffic, against the intended behaviour:
a press while idle (not busy, no host request, no sequence running) sends exactly IMG_SEL = the
switches, then CTRL.START = 1, and latches o_run_sel; every other press is ignored; host requests
reach the CSR stage unchanged and only while the controller is idle; the stage sees each request
held until accepted.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly

from common.runner import RTL_DIR, SIMULATORS, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

IMG_SEL, CTRL = 0x018, 0x010


@cocotb.test()
async def test_random_presses_and_host(dut):
    rng = seeded_rng(dut, "demo_ctrl")
    for s in (dut.i_start, dut.i_img_sel, dut.i_busy, dut.i_host_valid, dut.i_host_we):
        s.value = 0
    dut.i_host_addr.value = dut.i_host_wdata.value = dut.i_ready.value = 0
    await start_clock_and_reset(dut)
    expect: list[tuple] = []  # controller writes still to come
    host_req = None
    run_sel = 0
    accepted_starts = ignored = host_done = 0
    for cycle in range(6000):
        await FallingEdge(dut.clk)
        start = int(rng.random() < 0.03)
        busy = int(rng.random() < 0.3)
        sel = rng.randrange(16)
        if host_req is None and rng.random() < 0.05:
            host_req = (rng.randint(0, 1), rng.getrandbits(12), rng.getrandbits(32))
        dut.i_start.value, dut.i_busy.value, dut.i_img_sel.value = start, busy, sel
        dut.i_host_valid.value = int(host_req is not None)
        if host_req is not None:
            dut.i_host_we.value, dut.i_host_addr.value, dut.i_host_wdata.value = host_req
        ready = int(rng.random() < 0.5)
        dut.i_ready.value = ready
        await ReadOnly()
        idle = not expect
        # What the stage sees this cycle.
        valid = int(dut.o_valid.value)
        req = (int(dut.o_we.value), int(dut.o_addr.value), int(dut.o_wdata.value))
        if expect:
            assert valid and req == expect[0], f"cycle {cycle}: {req}, want {expect[0]}"
            assert not int(dut.o_host_ready.value), "host accepted during the sequence"
            if ready:
                expect.pop(0)
        else:
            assert valid == int(host_req is not None), f"cycle {cycle}: stray request"
            if host_req is not None:
                assert req == host_req, f"cycle {cycle}: host request {req} != {host_req}"
                assert int(dut.o_host_ready.value) == ready
                if ready:
                    host_req, host_done = None, host_done + 1
        if start:
            if idle and not busy and dut.i_host_valid.value == 0:
                expect = [(1, IMG_SEL, sel), (1, CTRL, 1)]
                accepted_starts += 1
                run_sel = sel
            else:
                ignored += 1
    assert int(dut.o_run_sel.value) == run_sel
    assert accepted_starts > 20 and ignored > 20 and host_done > 50, (
        accepted_starts, ignored, host_done,
    )  # fmt: skip


@pytest.mark.parametrize("sim", SIMULATORS)
def test_demo_ctrl(sim: str) -> None:
    run_cocotb(
        sim=sim,
        toplevel="demo_ctrl",
        sources=[RTL_DIR / "top" / "demo_ctrl.sv"],
        test_module=Path(__file__).stem,
    )
