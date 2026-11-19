"""perf_counters: cycle-by-cycle comparison with a Python model of spec §10.2 (D-027, D-028).

Random busy, MAC-active and request patterns, layer start/done events, and clears. The model
includes the input register (D-024): busy, MAC-active and request events are added one cycle
after they happen, the layer counters are not delayed, and a clear also drops the events of its
own cycle. A narrow
build (PERF_W = 8) drives every counter into saturation; the default width checks the full
counters without saturation.
"""

from __future__ import annotations

from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset

SOURCES = [RTL_DIR / "ctrl" / "perf_counters.sv"]


class Model:
    def __init__(self, width: int, depth: int):
        self.max = (1 << width) - 1
        self.depth = depth
        self.clear()

    def clear(self):
        self.tot = self.mac = self.rd = self.wr = 0
        self.layer = [0] * self.depth
        self.lay, self.running = 0, False
        self.pipe = (0, 0, 0, 0)  # (busy, mac, rd, wr) of the previous cycle

    def sat(self, v):
        return min(v, self.max)

    def step(self, clear, busy, mac, rd, wr, start, done, idx):
        if clear:
            self.clear()
            return
        (busy, mac, rd, wr), self.pipe = self.pipe, (busy, mac, rd, wr)
        if busy:
            self.tot = self.sat(self.tot + 1)
            self.mac = self.sat(self.mac + mac)
            self.rd = self.sat(self.rd + bin(rd).count("1"))
            self.wr = self.sat(self.wr + bin(wr).count("1"))
        lay_next = self.sat(self.lay + 1)
        if self.running and done:
            self.layer[idx] = lay_next
        if start:
            self.lay, self.running = 1, True
        elif self.running:
            self.lay = lay_next
        if self.running and done and not start:
            self.running = False


@cocotb.test()
async def test_random_events(dut):
    rng = seeded_rng(dut, "perf")
    width = len(dut.o_cyc_total)
    depth = len(dut.o_layer_cyc) // width
    rd_n, wr_n = len(dut.i_rd), len(dut.i_wr)
    m = Model(width, depth)
    for s in (dut.i_clear, dut.i_busy, dut.i_mac_active, dut.i_rd, dut.i_wr):
        s.value = 0
    dut.i_layer_start.value = dut.i_layer_done.value = dut.i_layer_idx.value = 0
    await start_clock_and_reset(dut)
    running, idx, saturated, p_done = False, 0, set(), 0.02
    for cycle in range(6000):
        await FallingEdge(dut.clk)
        clear = rng.random() < 0.0005
        busy = rng.random() < 0.9
        mac = int(rng.random() < 0.5)
        rd, wr = rng.getrandbits(rd_n), rng.getrandbits(wr_n)
        start = done = 0
        if not running and rng.random() < 0.05:
            start, running, idx = 1, True, rng.randrange(depth)
            p_done = rng.choice([0.05, 0.002])  # short layers, and long ones that saturate
        elif running and rng.random() < p_done:
            done, running = 1, False
        if clear:
            running = False
        dut.i_clear.value, dut.i_busy.value, dut.i_mac_active.value = int(clear), int(busy), mac
        dut.i_rd.value, dut.i_wr.value = rd, wr
        dut.i_layer_start.value, dut.i_layer_done.value, dut.i_layer_idx.value = start, done, idx
        await RisingEdge(dut.clk)
        m.step(clear, busy, mac, rd, wr, start, done, idx)
        await ReadOnly()
        got = (
            int(dut.o_cyc_total.value),
            int(dut.o_cyc_mac.value),
            int(dut.o_buf_rd.value),
            int(dut.o_buf_wr.value),
        )
        want = (m.tot, m.mac, m.rd, m.wr)
        assert got == want, f"cycle {cycle}: (total, mac, rd, wr) {got} != {want}"
        word = int(dut.o_layer_cyc.value)
        layers = [(word >> (i * width)) & m.max for i in range(depth)]
        assert layers == m.layer, f"cycle {cycle}: layer counters {layers} != {m.layer}"
        saturated |= {n for n, v in zip("tmrw", want, strict=True) if v == m.max}
        saturated |= {"l"} if m.max in m.layer else set()
    dut._log.info("counters seen saturated: %s", sorted(saturated))
    if width <= 8:
        assert saturated >= set("tmrwl"), f"saturation not reached for {set('tmrwl') - saturated}"


@pytest.mark.parametrize(("sim", "width"), [("icarus", 8), ("icarus", 32), ("verilator", 8)])
def test_perf_counters(sim: str, width: int) -> None:
    run_cocotb(
        sim=sim,
        toplevel="perf_counters",
        sources=SOURCES,
        test_module=Path(__file__).stem,
        parameters={"PERF_W": width, "DESC_DEPTH": 8},
    )
