"""layer_seq: descriptor walk, unit starts, registered fields, IMG offset, ownership, §9 errors.

The descriptor table is a Python 1-cycle-latency RAM model, and the three units are Python
models: a start pulse makes a unit busy for a random number of cycles, then it pulses done. An
expected-behaviour model written from spec §9 and D-028 gives, for a table and IMG_SEL, the
units that must start (in order), the configuration each must see, the buffer owners while it
runs, and the final status. Checked on every run:
  - each unit start: the unit, every configuration field (o_src_base includes
    IMG_SEL * IMG_SIZE for a CONV, POOL or FC with src = IMG), and the owner vectors;
  - configuration and owners do not change while a unit is busy, and the owners change only
    when every unit is idle in that cycle and the one before;
  - o_layer_start / o_layer_done pair up with the unit's start and done;
  - final BUSY / DONE / ERROR and the layer index; o_clear only on an accepted START.
Tests: the network's table for every IMG_SEL; random valid tables; every §9 error (reserved op;
dst = IMG, dst = LOGIT or src = dst for CONV/POOL; src = LOGIT for CONV/POOL/FC; dst != LOGIT for
FC; src != LOGIT for ARGMAX; missing last) followed by a clean run; START ignored while busy or
while a memory-port read is pending; reset mid-run.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from pathlib import Path

import cocotb
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.runner import RTL_DIR, run_cocotb
from common.sim import seeded_rng, start_clock_and_reset, wait_until
from model import hwmap
from model.hwmap import BUF_ACT0, BUF_ACT1, BUF_IMG, BUF_LOGIT, OP_ARGMAX, OP_CONV, OP_FC, OP_POOL
from model.hwmap import Descriptor as D

SOURCES = [RTL_DIR / "ctrl" / "layer_seq.sv"]
IMG_SIZE = 784
MEM, GEMM, POOL = 1, 2, 4  # owner bits
UNITS = ("gemm", "pool", "argmax")
FIELDS = (
    "op", "relu_en", "requant_en", "src", "dst", "src_base", "dst_base", "h", "w", "c_in",
    "c_out", "wgt_base", "param_base",
)  # fmt: skip
OWNERS = ("img", "act0", "act1", "wgt", "prm")


@dataclass
class Expected:
    starts: list[tuple[str, dict, dict]]  # (unit, configuration, owners) per started layer
    error: bool
    layer: int  # STATUS layer index at the end


def descriptor_error(d: D) -> bool:
    """Spec §9 descriptor errors (all but a missing `last`)."""
    if d.op > OP_ARGMAX:
        return True
    if d.op == OP_ARGMAX:  # reads LOGIT; dst is ignored
        return d.src != BUF_LOGIT
    if d.src == BUF_LOGIT:  # only ARGMAX reads LOGIT
        return True
    if d.op == OP_FC:  # writes the LOGIT registers
        return d.dst != BUF_LOGIT
    return d.dst in (BUF_IMG, BUF_LOGIT) or d.src == d.dst  # CONV, POOL write a byte buffer


def expected_run(table: list[D], img_sel: int, depth: int) -> Expected:
    """What the sequencer must do for `table` (spec §9, D-028)."""
    starts = []
    for i, d in enumerate(table[:depth]):
        if descriptor_error(d):
            return Expected(starts, True, i)
        unit = {OP_CONV: "gemm", OP_FC: "gemm", OP_POOL: "pool", OP_ARGMAX: "argmax"}[d.op]
        src_base = d.src_base
        if d.op != OP_ARGMAX and d.src == BUF_IMG:  # the image offset: buffer-reading ops only
            src_base = (src_base + img_sel * IMG_SIZE) & 0xFFFF
        cfg = dict(
            op=d.op, relu_en=d.relu_en, requant_en=d.requant_en, src=d.src, dst=d.dst,
            src_base=src_base, dst_base=d.dst_base, h=d.h_in, w=d.w_in, c_in=d.c_in,
            c_out=d.c_out, wgt_base=d.wgt_base, param_base=d.param_base,
        )  # fmt: skip
        bit = {"gemm": GEMM, "pool": POOL, "argmax": 0}[unit]
        own = dict.fromkeys(OWNERS, 0)
        if unit != "argmax":
            names = {BUF_IMG: "img", BUF_ACT0: "act0", BUF_ACT1: "act1"}
            if d.src in names:
                own[names[d.src]] = bit
            if d.op in (OP_CONV, OP_POOL) and d.dst in names:
                own[names[d.dst]] = bit
        if unit == "gemm":
            own["wgt"] = own["prm"] = GEMM
        starts.append((unit, cfg, own))
        if d.last:
            return Expected(starts, False, i)
    return Expected(starts, True, depth - 1)


class Harness:
    """Descriptor RAM, fake units and the per-cycle checks."""

    def __init__(self, dut, rng):
        self.dut, self.rng = dut, rng
        self.depth = (1 << len(dut.o_desc_raddr)) // 4  # DESC_DEPTH (a power of two)
        self.mem = [0] * (4 * self.depth)
        self.busy = dict.fromkeys(UNITS, 0)  # remaining busy cycles
        self.started: list[tuple[str, dict, dict]] = []
        self.layer_events: list[str] = []
        self.clears = 0
        self.max_delay = 12

    def load(self, table: list[D]) -> None:
        self.mem = [0] * (4 * self.depth)
        for i, d in enumerate(table[: self.depth]):
            self.mem[4 * i : 4 * i + 4] = d.encode()

    def sample(self, prefix: str, names) -> dict:
        return {n: int(getattr(self.dut, f"{prefix}{n}").value) for n in names}

    async def run(self):
        dut = self.dut
        prev_own, prev_busy, cfg_now = None, False, None
        while True:
            await FallingEdge(dut.clk)
            for u in UNITS:  # done pulses in the last busy cycle
                getattr(dut, f"i_{u}_done").value = int(self.busy[u] == 1)
            await ReadOnly()
            if int(dut.rst.value):  # the units are reset with the sequencer; checks restart
                self.busy = dict.fromkeys(UNITS, 0)
                prev_own = None
                await RisingEdge(dut.clk)
                continue
            any_busy = any(self.busy.values())
            own = self.sample("o_own_", OWNERS)
            if prev_own is not None and own != prev_own:
                assert not any_busy and not prev_busy, f"owners changed while a unit ran: {own}"
            if any_busy:
                cfg = self.sample("o_", FIELDS)
                assert cfg == cfg_now, f"configuration changed while busy: {cfg} vs {cfg_now}"
                assert own == prev_own, "owners changed while busy"
            prev_own, prev_busy = own, any_busy
            starts = [u for u in UNITS if int(getattr(dut, f"o_{u}_start").value)]
            assert len(starts) <= 1, f"several units started: {starts}"
            if starts:
                assert not any_busy, f"{starts[0]} started while a unit was busy"
                cfg_now = self.sample("o_", FIELDS)
                self.started.append((starts[0], cfg_now, own))
            if int(dut.o_layer_start.value):
                assert starts, "o_layer_start without a unit start"
                self.layer_events.append("start")
            if int(dut.o_layer_done.value):
                assert any(self.busy[u] == 1 for u in UNITS), "o_layer_done without unit done"
                self.layer_events.append("done")
            self.clears += int(dut.o_clear.value)
            re, ra = int(dut.o_desc_re.value), int(dut.o_desc_raddr.value)
            await RisingEdge(dut.clk)
            for u in UNITS:
                if self.busy[u]:
                    self.busy[u] -= 1
            if starts:
                self.busy[starts[0]] = self.rng.randint(1, self.max_delay)
            if re:
                dut.i_desc_rdata.value = self.mem[ra]


async def setup(dut, rng) -> Harness:
    for s in ("i_start", "i_mem_pending", "i_img_sel", "i_desc_rdata"):
        getattr(dut, s).value = 0
    for u in UNITS:
        getattr(dut, f"i_{u}_done").value = 0
    h = Harness(dut, rng)
    await start_clock_and_reset(dut)
    cocotb.start_soon(h.run())
    return h


async def pulse_start(dut) -> None:
    await FallingEdge(dut.clk)
    dut.i_start.value = 1
    await FallingEdge(dut.clk)
    dut.i_start.value = 0


async def run_table(dut, h: Harness, table: list[D], img_sel: int, what: str) -> Expected:
    want = expected_run(table, img_sel, h.depth)
    h.load(table)
    h.started.clear()
    h.layer_events.clear()
    clears = h.clears
    await FallingEdge(dut.clk)
    dut.i_img_sel.value = img_sel
    await pulse_start(dut)
    await ReadOnly()
    assert int(dut.o_busy.value) == 1, f"{what}: not busy after START"
    await wait_until(dut, lambda: int(dut.o_busy.value) == 0, 20_000, f"{what}: end of run")
    status = (int(dut.o_done.value), int(dut.o_error.value), int(dut.o_layer.value))
    assert status == (1, int(want.error), want.layer), (
        f"{what}: (done, error, layer) {status}, want {(1, int(want.error), want.layer)}"
    )
    assert h.clears == clears + 1, f"{what}: {h.clears - clears} clear pulses"
    assert len(h.started) == len(want.starts), (
        f"{what}: {len(h.started)} units started, want {len(want.starts)}"
    )
    for i, (got, exp) in enumerate(zip(h.started, want.starts, strict=True)):
        assert got == exp, f"{what}: layer {i}: got {got}, want {exp}"
    assert h.layer_events == ["start", "done"] * len(want.starts), f"{what}: {h.layer_events}"
    own = h.sample("o_own_", OWNERS)
    assert own == {"img": MEM, "act0": MEM, "act1": MEM, "wgt": MEM, "prm": MEM}, own
    return want


def network_table() -> list[D]:
    path = Path(hwmap.__file__).parent / "artifacts" / "mem" / "desc.hex"
    words = [int(x, 16) for x in path.read_text().split()]
    return [D.decode(words[4 * i : 4 * i + 4]) for i in range(len(words) // 4)]


@cocotb.test()
async def test_network_table_every_image(dut):
    """The exported table, for every IMG_SEL: six layers, IMG offset = IMG_SEL * 784."""
    h = await setup(dut, seeded_rng(dut, "seq_net"))
    table = network_table()
    for sel in range(16):
        want = await run_table(dut, h, table, sel, f"IMG_SEL {sel}")
        assert want.starts[0][1]["src_base"] == sel * IMG_SIZE
        if h.depth >= len(table):
            units = [u for u, _, _ in want.starts]
            assert units == ["gemm", "pool", "gemm", "pool", "gemm", "argmax"], units
            assert not want.error


def rand_desc(rng, last: int) -> D:
    op = rng.choice([OP_CONV, OP_POOL, OP_FC, OP_ARGMAX])
    if op == OP_ARGMAX:
        src, dst = BUF_LOGIT, rng.randrange(4)  # dst is ignored by ARGMAX
    elif op == OP_FC:  # FC writes the LOGIT registers; only ARGMAX may read them
        src, dst = rng.choice([BUF_IMG, BUF_ACT0, BUF_ACT1]), BUF_LOGIT
    else:  # CONV and POOL: neither src nor dst may be LOGIT
        src = rng.choice([BUF_IMG, BUF_ACT0, BUF_ACT1])
        dst = rng.choice([b for b in (BUF_ACT0, BUF_ACT1) if b != src])
    return D(
        op=op, relu_en=rng.randint(0, 1), requant_en=rng.randint(0, 1), last=last, src=src,
        dst=dst, src_base=rng.getrandbits(16), dst_base=rng.getrandbits(16),
        h_in=rng.getrandbits(8), w_in=rng.getrandbits(8), c_in=rng.getrandbits(8),
        c_out=rng.getrandbits(8), wgt_base=rng.getrandbits(16), param_base=rng.getrandbits(8),
    )  # fmt: skip


@cocotb.test()
async def test_random_valid_tables(dut):
    """Random valid tables of 1 .. DESC_DEPTH layers, random IMG_SEL and unit run times."""
    rng = seeded_rng(dut, "seq_rand")
    h = await setup(dut, rng)
    for t in range(40):
        n = rng.randint(1, h.depth)
        table = [rand_desc(rng, int(i == n - 1)) for i in range(n)]
        table += [rand_desc(rng, 0) for _ in range(h.depth - n)]  # never reached
        h.max_delay = rng.choice([1, 3, 40])
        want = await run_table(dut, h, table, rng.randrange(16), f"table {t}")
        assert not want.error


@cocotb.test()
async def test_every_error(dut):
    """Each §9 error ends the run at that layer without starting it; a clean run follows."""
    rng = seeded_rng(dut, "seq_err")
    h = await setup(dut, rng)
    good = [rand_desc(rng, 0) for _ in range(h.depth)]
    cases = []
    for op in (4, 5, 6, 7):
        cases.append((f"reserved op {op}", replace(good[2], op=op)))
    for op in (OP_CONV, OP_POOL):
        for src, dst in [(s, d) for s in range(4) for d in range(4)]:
            if src != BUF_LOGIT and dst in (BUF_ACT0, BUF_ACT1) and src != dst:
                continue  # the legal combinations
            cases.append(
                (
                    f"op {op} with src = {src}, dst = {dst}",
                    replace(good[2], op=op, src=src, dst=dst),
                )
            )
    for src, dst in [(s, d) for s in range(4) for d in range(4)]:
        if src != BUF_LOGIT and dst == BUF_LOGIT:
            continue  # the legal combinations
        cases.append(
            (f"FC with src = {src}, dst = {dst}", replace(good[2], op=OP_FC, src=src, dst=dst))
        )
    for src in (BUF_IMG, BUF_ACT0, BUF_ACT1):  # ARGMAX with src != LOGIT, for any dst
        for dst in range(4):
            cases.append(
                (
                    f"ARGMAX with src = {src}, dst = {dst}",
                    replace(good[2], op=OP_ARGMAX, src=src, dst=dst),
                )
            )
    named = {"ARGMAX with src = 0, dst = 3", "ARGMAX with src = 1, dst = 3"}
    named |= {"FC with src = 0, dst = 1", "FC with src = 1, dst = 2", "FC with src = 2, dst = 1"}
    assert named <= {what for what, _ in cases}, "the new §9 rules' named cases are missing"
    for what, bad in cases:
        assert descriptor_error(bad), f"test bug: {what} is not an error in the model"
        table = [*good[:2], bad, *good[3:]]
        want = await run_table(dut, h, table, rng.randrange(16), what)
        assert want.error and want.layer == 2 and len(want.starts) == 2, what
        clean = [*good[:2], replace(good[2], last=1), *good[3:]]
        want = await run_table(dut, h, clean, rng.randrange(16), f"clean run after {what}")
        assert not want.error
    # ARGMAX with src = LOGIT may name any dst (ignored), including src = dst: not an error.
    for dst in range(4):
        ok = replace(good[0], op=OP_ARGMAX, src=BUF_LOGIT, dst=dst, last=1)
        assert not (await run_table(dut, h, [ok], 0, f"argmax dst = {dst}")).error
    # FC from every byte buffer into LOGIT: legal; from IMG it gets the image offset.
    for src in (BUF_IMG, BUF_ACT0, BUF_ACT1):
        ok = replace(good[0], op=OP_FC, src=src, dst=BUF_LOGIT, last=1)
        want = await run_table(dut, h, [ok], 7, f"FC src = {src}")
        assert not want.error
        offset = 7 * IMG_SIZE if src == BUF_IMG else 0
        assert want.starts[0][1]["src_base"] == (ok.src_base + offset) & 0xFFFF
    # Missing last: DESC_DEPTH layers run, then ERROR at the last index.
    want = await run_table(dut, h, good, 5, "no descriptor with last = 1")
    assert want.error and len(want.starts) == h.depth and want.layer == h.depth - 1


@cocotb.test()
async def test_start_ignored_and_reset(dut):
    """START while busy or with a memory-port read pending is ignored; reset aborts a run."""
    rng = seeded_rng(dut, "seq_start")
    h = await setup(dut, rng)
    h.max_delay = 30
    table = network_table()
    # Memory-port read pending: START is ignored entirely.
    clears = h.clears
    await FallingEdge(dut.clk)
    dut.i_mem_pending.value = 1
    await pulse_start(dut)
    dut.i_mem_pending.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.o_busy.value) == 0 and h.clears == clears, "START accepted with a read pending"
    # START pulses during a run change nothing (run_table checks the whole sequence).
    h.load(table)

    ignored = []  # START pulses issued while the sequencer was busy

    async def extra_starts():
        await wait_until(dut, lambda: int(dut.o_busy.value) == 1, 100, "busy")
        for _ in range(10):
            for _ in range(rng.randint(1, 30)):
                await FallingEdge(dut.clk)
            dut.i_start.value = 1
            await ReadOnly()
            ignored.append(int(dut.o_busy.value))
            await FallingEdge(dut.clk)
            dut.i_start.value = 0

    extra = cocotb.start_soon(extra_starts())
    await run_table(dut, h, table, 3, "network with START pulses while busy")
    extra.cancel()  # stop injecting pulses before the next runs
    await FallingEdge(dut.clk)
    dut.i_start.value = 0
    assert sum(ignored) >= 3, f"too few START pulses landed while busy: {ignored}"
    # Reset in the middle of a run: idle, DONE and ERROR clear, the memory port owns every buffer.
    for stop_after in (1, 3, 5, 9, 20, 60):
        h.load(table)
        await pulse_start(dut)
        for _ in range(stop_after):
            await FallingEdge(dut.clk)
        dut.rst.value = 1
        await FallingEdge(dut.clk)
        dut.rst.value = 0
        await ReadOnly()
        status = (int(dut.o_busy.value), int(dut.o_done.value), int(dut.o_error.value))
        assert status == (0, 0, 0), f"after reset at cycle {stop_after}: {status}"
        assert h.sample("o_own_", OWNERS) == dict.fromkeys(OWNERS, MEM)
        await run_table(dut, h, table, rng.randrange(16), f"clean run after reset {stop_after}")


@pytest.mark.parametrize(("sim", "depth"), [("icarus", 8), ("icarus", 4), ("verilator", 8)])
def test_layer_seq(sim: str, depth: int) -> None:
    run_cocotb(
        sim=sim,
        toplevel="layer_seq",
        sources=SOURCES,
        test_module=Path(__file__).stem,
        parameters={"DESC_DEPTH": depth, "IMG_SIZE": IMG_SIZE},
    )
