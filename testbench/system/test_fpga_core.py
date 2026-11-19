"""fpga_core bring-up: the FPGA demo's core (controller, CSR and memory-port register stages,
accel_top, label ROM) with the init files the board build uses, on Verilator with every
accel_top assertion bound (the register stages are accel_top's bus masters here).

  test_bring_up    through the host side: ID and CONFIG; DESC, WGT and PARAM read back equal to
                   desc.hex, wgt.hex and param.hex; image 0 of img.hex in the IMG buffer
  test_demo_runs   all 16 preloaded images started like the board does (i_img_sel + a start
                   press): RESULT = the golden class, o_label = the true label, every LOGIT equal
                   to the golden model's, CYC_TOTAL equal to testbench/reports/perf_counters.json;
                   a press while busy is ignored (exactly one run per accepted press)
"""

from __future__ import annotations

import json
from pathlib import Path

import cocotb
import numpy as np
import pytest
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, with_timeout

from common import accel_bus as ab
from common.bits import to_signed
from common.runner import RTL_DIR, run_cocotb, sv_string
from common.sim import start_clock_and_reset
from model import golden

MEM_DIR = Path(golden.__file__).parent / "artifacts" / "mem"
REPORTS = Path(__file__).resolve().parents[1] / "reports"
RTL_SOURCES = sorted(p for p in RTL_DIR.rglob("*.sv") if p.name != "de10lite_top.sv")


def hex_words(name: str) -> list[int]:
    return [int(x, 16) for x in (MEM_DIR / name).read_text().split()]


class Host:
    """Host side of fpga_core: csr_slice / mem_slice front protocol (request valid/ready,
    read data on a later one-cycle rvalid pulse)."""

    def __init__(self, dut):
        self.dut = dut
        for s in ("csr_valid", "csr_we", "csr_addr", "csr_wdata"):
            getattr(dut, f"i_host_{s}").value = 0
        for s in ("mem_valid", "mem_we", "mem_sel", "mem_addr", "mem_wdata"):
            getattr(dut, f"i_host_{s}").value = 0

    async def _request(self, port: str, fields: dict, read: bool, guard: int = 10_000) -> int:
        dut = self.dut
        await FallingEdge(dut.clk)
        getattr(dut, f"i_host_{port}_valid").value = 1
        for k, v in fields.items():
            getattr(dut, f"i_host_{port}_{k}").value = v
        for _ in range(guard):
            await ReadOnly()
            ok = int(getattr(dut, f"o_host_{port}_ready").value)
            await FallingEdge(dut.clk)
            if ok:
                break
        else:
            raise TimeoutError(f"{port} request never accepted")
        getattr(dut, f"i_host_{port}_valid").value = 0
        if not read:
            return 0
        for _ in range(guard):
            await ReadOnly()
            if int(getattr(dut, f"o_host_{port}_rvalid").value):
                data = int(getattr(dut, f"o_host_{port}_rdata").value)
                await FallingEdge(dut.clk)
                return data
            await FallingEdge(dut.clk)
        raise TimeoutError(f"no {port} read response")

    async def csr_read(self, addr: int) -> int:
        return await self._request("csr", {"we": 0, "addr": addr, "wdata": 0}, True)

    async def mem_read(self, sel: int, addr: int) -> int:
        return await self._request("mem", {"we": 0, "sel": sel, "addr": addr, "wdata": 0}, True)


async def setup(dut) -> Host:
    dut.i_start.value = 0
    dut.i_img_sel.value = 0
    host = Host(dut)
    await start_clock_and_reset(dut)
    return host


@cocotb.test()
async def test_bring_up(dut):
    host = await setup(dut)
    assert await host.csr_read(ab.ID) == 0x434E4E31
    assert await host.csr_read(ab.CONFIG) == 8 | 8 << 8 | 32 << 16 | 8 << 24
    desc = hex_words("desc.hex")
    got = [await host.csr_read(ab.DESC + 4 * w) for w in range(len(desc))]
    assert got == desc, "DESC differs from desc.hex"
    for name, sel in (("wgt.hex", ab.SEL_WGT), ("param.hex", ab.SEL_PARAM)):
        want = hex_words(name)
        got = [await host.mem_read(sel, a) for a in range(len(want))]
        bad = [a for a in range(len(want)) if got[a] != want[a]]
        assert not bad, f"{name}: {len(bad)} words differ, e.g. {bad[:5]}"
        dut._log.info("%s: %d words read back equal", name, len(want))
    img = hex_words("img.hex")[:784]
    got = [await host.mem_read(ab.SEL_IMG, a) for a in range(784)]
    assert got == img, "image 0 differs from img.hex"


async def wait_run(dut) -> None:
    await with_timeout(RisingEdge(dut.o_busy), 100, "us")
    await with_timeout(FallingEdge(dut.o_busy), 5000, "us")


@cocotb.test()
async def test_demo_runs(dut):
    host = await setup(dut)
    demo = json.loads((MEM_DIR / "demo.json").read_text())
    with np.load(MEM_DIR.parent / "quick_subset.npz") as f:
        logits = f["logits"]
    perf = json.loads((REPORTS / "perf_counters.json").read_text())
    want_cycles = perf["counters"]["cyc_total"]["max"]
    assert perf["counters"]["cyc_total"]["min"] == want_cycles
    for sel in range(16):
        await FallingEdge(dut.clk)
        dut.i_img_sel.value = sel
        dut.i_start.value = 1
        await FallingEdge(dut.clk)
        dut.i_start.value = 0
        run = cocotb.start_soon(wait_run(dut))
        if sel == 5:  # a press during the run is ignored
            await RisingEdge(dut.o_busy)
            for _ in range(20):
                await FallingEdge(dut.clk)
            dut.i_img_sel.value, dut.i_start.value = 9, 1
            await FallingEdge(dut.clk)
            dut.i_start.value = 0
        await run
        for _ in range(3):
            await FallingEdge(dut.clk)
        await ReadOnly()
        assert not int(dut.o_busy.value), f"image {sel}: a second run started"
        assert int(dut.o_done.value) and not int(dut.o_error.value), f"image {sel}: status"
        assert int(dut.o_run_sel.value) == sel, f"image {sel}: run_sel {int(dut.o_run_sel.value)}"
        assert int(dut.o_result.value) == demo["golden_class"][sel], f"image {sel}: RESULT"
        assert int(dut.o_label.value) == demo["label"][sel], f"image {sel}: label"
        got = [to_signed(await host.csr_read(ab.LOGIT + 4 * i), 32) for i in range(10)]
        want = [int(v) for v in logits[demo["quick_subset_positions"][sel]]]
        assert got == want, f"image {sel}: logits {got}, want {want}"
        cycles = await host.csr_read(ab.CYC_TOTAL)
        assert cycles == want_cycles == int(dut.o_cyc_total.value), f"image {sel}: CYC_TOTAL"
        if sel == 0:
            dut._log.info("image 0: RESULT %d (golden %d), CYC_TOTAL %d",
                          int(dut.o_result.value), demo["golden_class"][0], cycles)  # fmt: skip
    dut._log.info("16 demo images: RESULT, label, logits and CYC_TOTAL as expected")


def init_params() -> dict[str, object]:
    return {
        f"{k}_INIT": sv_string(MEM_DIR / f"{k.lower()}.hex")
        for k in ("IMG", "WGT", "PARAM", "DESC", "LABEL")
    }


@pytest.mark.parametrize("sim", ["verilator"])
def test_fpga_core(sim: str) -> None:
    import test_accel_top as t  # every accel_top assertion, bound inside fpga_core

    run_cocotb(
        sim=sim,
        toplevel="fpga_core",
        sources=RTL_SOURCES + t.SVA_SOURCES,
        test_module=Path(__file__).stem,
        parameters=init_params(),
        extra_build_args=["--assert"],
    )
