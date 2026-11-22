"""soc_top: the RISC-V SoC (spec §13) running firmware on Verilator, with every accel_top
assertion and the AXI4-Lite assertions (interconnect and every slave) bound.

Every test watches the CPU's bus: any SLVERR or DECERR response fails it (PicoRV32 ignores
responses, so an error would otherwise pass silently; D-040), and so does a CPU trap.

  smoke   (firmware/apps/smoke) boot: an initialized variable and .bss have their initial values;
          the accelerator's ID; one run of preloaded IMG slot 0 started and polled by firmware:
          RESULT and all 10 logits (read back from RAM) equal the golden model's; GPIO SW and HEX0
          seen by firmware / driven by it. Then a reset
          after the firmware has changed its variables: it boots and passes again (crt0.S
          restores .data and .bss, D-042).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

from common import firmware
from common.bits import to_signed
from common.runner import REPO_ROOT, RTL_DIR, SVA_DIR, run_cocotb, sv_string
from common.sim import start_clock_and_reset
from model import golden
from system.test_accel_top import SVA_SOURCES

ARTIFACTS = Path(golden.__file__).parent / "artifacts"
MEM_DIR = ARTIFACTS / "mem"
TB_APP = os.environ.get("TB_APP", "")
TB_SYMBOLS = os.environ.get("TB_SYMBOLS", "")  # JSON file: the app's symbol addresses
MB_PASS = 0x600D_0000
MB_FAIL_MASK, MB_FAIL = 0xFFF0_0000, 0xBAD0_0000
OKAY = 0


def quick_subset() -> dict[str, np.ndarray]:
    with np.load(ARTIFACTS / "quick_subset.npz") as f:
        return {k: f[k] for k in f}


def symbols() -> dict[str, int]:
    return json.loads(Path(TB_SYMBOLS).read_text())


def ram_word(dut, addr: int) -> int:
    return int(dut.u_axil_ram.u_sram_be.mem[addr >> 2].value)


def ram_words(dut, addr: int, n: int) -> list[int]:
    return [ram_word(dut, addr + 4 * i) for i in range(n)]


class BusMonitor:
    """Watches the CPU side of the interconnect: counts transactions, records error responses."""

    def __init__(self, dut):
        self.dut = dut
        self.errors: list[str] = []
        self.writes = 0
        self.reads = 0

    async def run(self) -> None:
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            if int(d.rst.value):
                continue
            if int(d.cpu_bvalid.value) and int(d.cpu_bready.value):
                self.writes += 1
                if int(d.cpu_bresp.value) != OKAY:
                    self.errors.append(f"write resp {int(d.cpu_bresp.value)}")
            if int(d.cpu_rvalid.value) and int(d.cpu_rready.value):
                self.reads += 1
                if int(d.cpu_rresp.value) != OKAY:
                    self.errors.append(f"read resp {int(d.cpu_rresp.value)}")


async def start(dut) -> BusMonitor:
    dut.i_sw.value = 0
    dut.i_key_level.value = 0
    dut.i_key_press.value = 0
    await start_clock_and_reset(dut)
    mon = BusMonitor(dut)
    cocotb.start_soon(mon.run())
    return mon


async def wait_mailbox(dut, mon: BusMonitor, done: int, guard: int, what: str) -> int:
    """Wait until MAILBOX == done; fails on a FAIL code, a trap or a bus error response."""
    for n in range(guard):
        await RisingEdge(dut.clk)
        if n % 64:
            continue
        await ReadOnly()
        mb = int(dut.o_mailbox.value)
        assert not int(dut.o_trap.value), f"CPU trapped ({what}), mailbox {mb:#010x}"
        assert not mon.errors, f"bus error responses ({what}): {mon.errors[:5]}"
        assert mb & MB_FAIL_MASK != MB_FAIL, f"firmware check failed ({what}): {mb:#010x}"
        if mb == done:
            return n
    raise TimeoutError(f"{what}: mailbox {int(dut.o_mailbox.value):#010x} after {guard} cycles")


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
    ]


def run_app(app: str) -> None:
    fw = firmware.build(app)
    sym_file = fw.out / "symbols.json"
    sym_file.write_text(json.dumps(fw.symbols()))
    run_cocotb(
        sim="verilator",
        toplevel="soc_top",
        sources=sources(),
        test_module=Path(__file__).stem,
        parameters={
            "RAM_INIT": sv_string(fw.hex),
            "IMG_INIT": sv_string(MEM_DIR / "img.hex"),
            "WGT_INIT": sv_string(MEM_DIR / "wgt.hex"),
            "PARAM_INIT": sv_string(MEM_DIR / "param.hex"),
            "DESC_INIT": sv_string(MEM_DIR / "desc.hex"),
        },
        extra_build_args=["--assert"],
        extra_env={"TB_APP": app, "TB_SYMBOLS": str(sym_file)},
        build_tag=app,
    )


@pytest.mark.parametrize("app", ["smoke"])
def test_soc(app: str) -> None:
    run_app(app)
