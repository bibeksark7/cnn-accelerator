"""soc_top: the RISC-V SoC (spec §13) running firmware on Verilator, with every accel_top
assertion and the AXI4-Lite assertions (interconnect and every slave) bound.

Every test checks the CPU's bus with testbench/sva/soc_bus_sva.sv: any SLVERR or DECERR response
fails it (PicoRV32 ignores responses, so an error would otherwise pass silently; D-040), and so
does a CPU trap. Python wakes only on MAILBOX changes, so the firmware runs at simulator speed.

  smoke   (firmware/apps/smoke) boot: an initialized variable and .bss have their initial values;
          the accelerator's ID; one run of preloaded IMG slot 0 started and polled by firmware:
          RESULT and all 10 logits (read back from RAM) equal the golden model's; GPIO SW and HEX0
          seen by firmware / driven by it. Then a reset
          after the firmware has changed its variables: it boots and passes again (crt0.S
          restores .data and .bss, D-042).
  quick   (firmware/apps/quick) the 50 quick-subset images, embedded in the firmware, uploaded
          through the buffer window and run by firmware: for every image STATUS is DONE without
          ERROR, RESULT and all 10 logits equal the golden model's, CYC_TOTAL equals
          testbench/reports/perf_counters.json, and the firmware-timed upload and end-to-end
          times are longer than CYC_TOTAL (they include it, spec 13.9)
  bench   (firmware/apps/bench, BENCH_IMAGES images) the software CNN and the accelerator on the
          same images: both sets of logits equal the golden model's; the cycle counts of spec
          13.9 are written to TB_RESULTS (JSON) when set (scripts/soc_speedup.py)
  demo    (firmware/apps/demo, the board demo of spec 13.8) idle: HEX1 shows the label of image
          SW[3:0], the rest blank, LEDs off; a KEY[0] press: LEDR[0] while working, then LEDR[1]
          only (no ERROR, software and accelerator logits equal), HEX0 = the golden class, HEX1
          = the label, HEX5..HEX2 = the speedup in decimal (equal to the firmware's measured
          software / end-to-end cycles); SW[9] switches HEX5..HEX2 to CYC_TOTAL >> 4 in hex; a
          press during the run is ignored (exactly one run)

test_soc_bus_check_fires: firmware that stores to an unmapped address (apps/buserr) and firmware
that executes ebreak (apps/trap) each fail the run through soc_bus_sva's a_no_write_error /
a_no_trap, so the bus check is live.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import ClockCycles, FallingEdge, First, ReadOnly, Timer
from cocotb.utils import get_sim_time

from common import firmware
from common.bits import to_signed
from common.runner import REPO_ROOT, RTL_DIR, SVA_DIR, run_cocotb, run_sva_violation, sv_string
from common.sim import CLK_PERIOD_NS, start_clock_and_reset
from model import golden
from system.test_accel_top import SVA_SOURCES

ARTIFACTS = Path(golden.__file__).parent / "artifacts"
MEM_DIR = ARTIFACTS / "mem"
TB_APP = os.environ.get("TB_APP", "")
TB_SYMBOLS = os.environ.get("TB_SYMBOLS", "")  # JSON file: the app's symbol addresses
TB_RESULTS = os.environ.get("TB_RESULTS", "")  # bench: JSON output for scripts/soc_speedup.py
BENCH_IMAGES = int(os.environ.get("BENCH_IMAGES", "1"))
REPORTS = Path(__file__).resolve().parents[1] / "reports"
MB_PASS = 0x600D_0000
MB_FAIL_MASK, MB_FAIL = 0xFFF0_0000, 0xBAD0_0000


def quick_subset() -> dict[str, np.ndarray]:
    with np.load(ARTIFACTS / "quick_subset.npz") as f:
        return {k: f[k] for k in f}


def symbols() -> dict[str, int]:
    return json.loads(Path(TB_SYMBOLS).read_text())


def ram_word(dut, addr: int) -> int:
    return int(dut.u_axil_ram.u_sram_1r1w.mem[addr >> 2].value)


def ram_words(dut, addr: int, n: int) -> list[int]:
    return [ram_word(dut, addr + 4 * i) for i in range(n)]


class BusMonitor:
    """The CPU's transaction counts, from soc_bus_sva (which also fails the run on any error
    response or trap)."""

    def __init__(self, dut):
        self.sva = dut.u_soc_bus_sva

    @property
    def writes(self) -> int:
        return int(self.sva.writes_q.value)

    @property
    def reads(self) -> int:
        return int(self.sva.reads_q.value)


async def start(dut) -> BusMonitor:
    dut.i_sw.value = 0
    dut.i_key_level.value = 0
    dut.i_key_press.value = 0
    await start_clock_and_reset(dut)
    return BusMonitor(dut)


async def wait_mailbox(dut, mon: BusMonitor | None, done: int | None, guard: int, what: str) -> int:
    """Wait until MAILBOX == done, or any done code (0x600D_xxxx) if done is None (woken only by
    MAILBOX changes); fails on a FAIL code. Bus error responses and traps fail the run through
    soc_bus_sva. Returns the cycles waited."""
    del mon
    t0 = get_sim_time(unit="ns")
    deadline = t0 + guard * CLK_PERIOD_NS
    await FallingEdge(dut.clk)  # leave any ReadOnly phase the caller is in
    while True:
        await ReadOnly()
        mb = int(dut.o_mailbox.value)
        assert mb & MB_FAIL_MASK != MB_FAIL, f"firmware check failed ({what}): {mb:#010x}"
        if mb == done or (done is None and mb & 0xFFFF_0000 == MB_PASS):
            return round((get_sim_time(unit="ns") - t0) / CLK_PERIOD_NS)
        left = deadline - get_sim_time(unit="ns")
        if left <= 0:
            raise TimeoutError(f"{what}: mailbox {mb:#010x} after {guard} cycles")
        await First(dut.o_mailbox.value_change, Timer(left, unit="ns"))


@cocotb.test(skip=TB_APP != "smoke")
async def smoke(dut):
    mon = await start(dut)
    dut.i_sw.value = 0x2A5
    syms = symbols()
    qs = quick_subset()
    demo = json.loads((MEM_DIR / "demo.json").read_text())
    pos = demo["quick_subset_positions"][0]
    want = [int(x) for x in qs["logits"][pos]]
    for boot in (1, 2):
        cycles = await wait_mailbox(dut, mon, MB_PASS, 400_000, f"boot {boot}")
        base = syms["results"]
        magic, sw, status, result, e2e, cyc_total = ram_words(dut, base, 6)
        logits = [to_signed(w, 32) for w in ram_words(dut, base + 24, 10)]
        assert magic == MB_PASS
        assert sw == 0x2A5, f"SW read {sw:#x}"
        assert logits == want, f"boot {boot}: logits {logits}, golden {want}"
        assert result == int(qs["pred"][pos]) == demo["golden_class"][0]
        assert status & 0x6 == 0x2, f"STATUS {status:#x}"
        assert 0 < cyc_total < e2e, (cyc_total, e2e)
        assert int(dut.o_hex_code.value) & 0x1F == result
        dut._log.info(
            "boot %d: PASS after %d cycles; CYC_TOTAL %d, firmware-timed run %d cycles; "
            "%d bus writes, %d reads",
            boot,
            cycles,
            cyc_total,
            e2e,
            mon.writes,
            mon.reads,
        )
        # Reset after the firmware changed its .data and .bss: it must boot and pass again.
        await FallingEdge(dut.clk)
        dut.rst.value = 1
        await ClockCycles(dut.clk, 3)
        await FallingEdge(dut.clk)
        dut.rst.value = 0
        await ReadOnly()
        assert int(dut.o_mailbox.value) == 0, "MAILBOX not reset"


def golden_cycles() -> int:
    perf = json.loads((REPORTS / "perf_counters.json").read_text())
    cyc = perf["counters"]["cyc_total"]
    assert cyc["min"] == cyc["max"]
    return cyc["max"]


QUICK_ENTRY = 15  # words: status, result, upload, e2e, cyc_total, logits[10]


@cocotb.test(skip=TB_APP != "quick")
async def quick(dut):
    mon = await start(dut)
    qs = quick_subset()
    n = len(qs["q"])
    cycles = await wait_mailbox(dut, mon, MB_PASS | n, 20_000_000, "quick subset")
    base = symbols()["results"]
    magic, count = ram_words(dut, base, 2)
    assert (magic, count) == (MB_PASS | n, n)
    want_cyc = golden_cycles()
    for i in range(n):
        w = ram_words(dut, base + 8 + 4 * QUICK_ENTRY * i, QUICK_ENTRY)
        status, result, upload, e2e, cyc_total = w[:5]
        logits = [to_signed(x, 32) for x in w[5:]]
        want = [int(x) for x in qs["logits"][i]]
        assert status & 0x6 == 0x2, f"image {i}: STATUS {status:#x}"
        assert logits == want, f"image {i}: logits {logits}, golden {want}"
        assert result == int(qs["pred"][i]), f"image {i}: RESULT {result}"
        assert cyc_total == want_cyc, f"image {i}: CYC_TOTAL {cyc_total}, want {want_cyc}"
        assert e2e > cyc_total and upload > 784, (i, upload, e2e)
    dut._log.info(
        "quick: %d images bit-exact in %d cycles; image 0 upload %d, end to end %d cycles",
        n,
        cycles,
        *ram_words(dut, base + 8 + 8, 2),
    )


BENCH_ENTRY = 28  # words: sw, sw_instret, upload, e2e, cyc_total, sw_class, accel_class, status,
#                    sw logits[10], accelerator logits[10]


@cocotb.test(skip=TB_APP != "bench")
async def bench(dut):
    mon = await start(dut)
    qs = quick_subset()
    n = BENCH_IMAGES
    cycles = await wait_mailbox(dut, mon, None, 200_000_000, "bench")
    base = symbols()["results"]
    count = ram_words(dut, base, 2)[1]
    assert count == n, f"the firmware ran {count} images, the test expects BENCH_IMAGES = {n}"
    assert ram_words(dut, base, 2) == [MB_PASS | n, n]
    rows = []
    for i in range(n):
        w = ram_words(dut, base + 8 + 4 * BENCH_ENTRY * i, BENCH_ENTRY)
        sw, sw_instret, upload, e2e, cyc_total, sw_class, accel_class, status = w[:8]
        sw_logits = [to_signed(x, 32) for x in w[8:18]]
        accel_logits = [to_signed(x, 32) for x in w[18:28]]
        want = [int(x) for x in qs["logits"][i]]
        assert status & 0x6 == 0x2, f"image {i}: STATUS {status:#x}"
        assert sw_logits == want, f"image {i}: software logits {sw_logits}, golden {want}"
        assert accel_logits == want, f"image {i}: accelerator logits {accel_logits}"
        assert sw_class == accel_class == int(qs["pred"][i])
        rows.append(
            {"image": i, "software": sw, "software_instret": sw_instret, "upload": upload,
             "end_to_end": e2e, "cyc_total": cyc_total}
        )  # fmt: skip
        dut._log.info(
            "image %d: software %d, upload %d, end to end %d, CYC_TOTAL %d cycles",
            i,
            sw,
            upload,
            e2e,
            cyc_total,
        )
    if TB_RESULTS:
        Path(TB_RESULTS).write_text(json.dumps({"images": rows, "sim_cycles": cycles}, indent=1))


@cocotb.test(skip=TB_APP not in ("buserr", "trap"))
async def sva_violation_soc_bus(dut):
    """Runs a firmware that breaks a soc_bus_sva rule; the assertion must stop the run."""
    await start(dut)
    await wait_mailbox(dut, None, MB_PASS, 100_000, TB_APP)


def hex_digits(dut) -> list[int]:
    v = int(dut.o_hex_code.value)
    return [(v >> (5 * d)) & 0x1F for d in range(6)]


async def wait_signal(dut, sig, pred, guard: int, what: str) -> None:
    """Wait (woken only by changes of `sig`) until pred() holds."""
    deadline = get_sim_time(unit="ns") + guard * CLK_PERIOD_NS
    await FallingEdge(dut.clk)
    while True:
        await ReadOnly()
        if pred():
            return
        left = deadline - get_sim_time(unit="ns")
        if left <= 0:
            raise TimeoutError(f"{what} after {guard} cycles")
        await First(sig.value_change, Timer(left, unit="ns"))


async def press(dut) -> None:
    """KEY[0] as the board delivers it: the debounced level, and a one-cycle press pulse."""
    await FallingEdge(dut.clk)
    dut.i_key_level.value = 1
    dut.i_key_press.value = 1
    await FallingEdge(dut.clk)
    dut.i_key_press.value = 0
    for _ in range(20):
        await FallingEdge(dut.clk)
    dut.i_key_level.value = 0


DEMO_STATE = 9  # words: runs, slot, result, status, mismatch, sw, e2e, cyc_total, speedup
BLANK = 16


@cocotb.test(skip=TB_APP != "demo")
async def demo(dut):
    await start(dut)
    demo_json = json.loads((MEM_DIR / "demo.json").read_text())
    labels, classes = demo_json["label"], demo_json["golden_class"]
    slot = 12
    dut.i_sw.value = slot
    await wait_signal(
        dut,
        dut.o_hex_code,
        lambda: hex_digits(dut) == [BLANK, labels[slot], *[BLANK] * 4],
        200_000,
        "idle display",
    )
    assert int(dut.o_ledr.value) == 0
    await press(dut)
    await wait_signal(dut, dut.o_ledr, lambda: int(dut.o_ledr.value) == 1, 200_000, "busy LED")
    await press(dut)  # during the run: ignored
    await wait_mailbox(dut, None, 1, 100_000_000, "demo run")
    await wait_signal(dut, dut.o_ledr, lambda: int(dut.o_ledr.value) == 2, 1000, "done LED")
    base = symbols()["demo"]
    runs, run_slot, result, status, mismatch, sw, e2e, cyc_total, speedup = ram_words(
        dut, base, DEMO_STATE
    )
    assert (runs, run_slot, mismatch) == (1, slot, 0), (runs, run_slot, mismatch)
    assert status & 0x6 == 0x2 and result == classes[slot]
    assert cyc_total == golden_cycles()
    assert speedup == min(sw // e2e, 9999) and speedup > 0
    want = [d if i == 0 or speedup >= 10**i else BLANK for i, d in
            enumerate(int(c) for c in f"{speedup:04d}"[::-1])]  # fmt: skip
    await wait_signal(
        dut,
        dut.o_hex_code,
        lambda: hex_digits(dut) == [result, labels[slot], *want],
        200_000,
        "result display",
    )
    dut._log.info("demo: image %d, class %d, speedup %d (software %d, end to end %d cycles)",
                  slot, result, speedup, sw, e2e)  # fmt: skip
    await FallingEdge(dut.clk)
    dut.i_sw.value = 0x200 | slot
    cyc = min(cyc_total >> 4, 0xFFFF)
    want_cyc = [result, labels[slot], *[(cyc >> (4 * i)) & 0xF for i in range(4)]]
    await wait_signal(
        dut, dut.o_hex_code, lambda: hex_digits(dut) == want_cyc, 200_000, "cycle display"
    )
    # The press during the run did not start a second one.
    await ClockCycles(dut.clk, 100_000)
    await ReadOnly()
    assert int(dut.o_mailbox.value) == 1 and int(dut.o_ledr.value) == 2, "a second run started"


def sources() -> list[Path]:
    return [
        *sorted(RTL_DIR.rglob("*.sv")),
        REPO_ROOT / "third_party" / "picorv32.vlt",
        REPO_ROOT / "third_party" / "picorv32" / "picorv32.v",
        *SVA_SOURCES,
        SVA_DIR / "axil_resp_order_sva.sv",
        SVA_DIR / "req_rsp_sva.sv",
        SVA_DIR / "axil_slave_port_bind.sv",
        SVA_DIR / "axil_interconnect_bind.sv",
        SVA_DIR / "soc_bus_sva.sv",
        SVA_DIR / "soc_bus_bind.sv",
    ]


def params(fw: firmware.Firmware) -> dict[str, object]:
    return {
        "RAM_INIT": sv_string(fw.hex),
        "IMG_INIT": sv_string(MEM_DIR / "img.hex"),
        "WGT_INIT": sv_string(MEM_DIR / "wgt.hex"),
        "PARAM_INIT": sv_string(MEM_DIR / "param.hex"),
        "DESC_INIT": sv_string(MEM_DIR / "desc.hex"),
    }


def run_app(
    app: str, make_vars: dict[str, str] | None = None, env: dict[str, str] | None = None
) -> None:
    fw = firmware.build(app, make_vars)
    sym_file = fw.out / "symbols.json"
    sym_file.write_text(json.dumps(fw.symbols()))
    run_cocotb(
        sim="verilator",
        toplevel="soc_top",
        sources=sources(),
        test_module=Path(__file__).stem,
        parameters=params(fw),
        extra_build_args=["--assert"],
        extra_env={"TB_APP": app, "TB_SYMBOLS": str(sym_file), **(env or {})},
        build_tag=app,
    )


@pytest.mark.parametrize("app", ["smoke", "quick", "demo"])
def test_soc(app: str) -> None:
    run_app(app)


def test_soc_bench() -> None:
    """The software CNN on one image (BENCH_IMAGES; scripts/soc_speedup.py runs more)."""
    n = os.environ.get("BENCH_IMAGES", "1")
    run_app("bench", {"BENCH_IMAGES": n}, {"BENCH_IMAGES": n, "TB_RESULTS": TB_RESULTS})


@pytest.mark.parametrize(
    ("app", "assertion"), [("buserr", "a_no_write_error"), ("trap", "a_no_trap")]
)
def test_soc_bus_check_fires(app: str, assertion: str) -> None:
    fw = firmware.build(app)
    run_sva_violation(
        toplevel="soc_top",
        sources=sources(),
        test_module=Path(__file__).stem,
        violation="soc_bus",
        assertion=assertion,
        parameters=params(fw),
        extra_env={"TB_APP": app},
    )
