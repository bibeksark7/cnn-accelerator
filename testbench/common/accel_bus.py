"""Masters for the accelerator's CSR bus (spec §10.1) and memory port (spec §10.3).

Same sampling rule as common/handshake.py (docs/bug_log.md BUG-003): requests are driven after a
falling edge; valid, ready and read data are sampled in ReadOnly of that time step, so a request
counts as accepted exactly when the next rising edge sees valid && ready. Latencies are never
assumed: the masters wait for ready / rvalid, with a hang guard only.
"""

from __future__ import annotations

from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from common.coverage import cover

# CSR byte offsets (spec §10.2).
ID, CONFIG, CTRL, STATUS, IMG_SEL, RESULT = 0x000, 0x004, 0x010, 0x014, 0x018, 0x01C
CYC_TOTAL, CYC_MAC, BUF_RD, BUF_WR = 0x020, 0x024, 0x028, 0x02C
LAYER_CYC, LOGIT, DESC = 0x040, 0x080, 0x100
BUSY, DONE, ERROR = 1, 2, 4
# Memory port buffer selects (spec §10.3).
SEL_IMG, SEL_ACT0, SEL_ACT1, SEL_WGT, SEL_PARAM = 0, 1, 2, 3, 4


class CsrMaster:
    def __init__(self, dut, guard: int = 10_000):
        self.dut, self.guard = dut, guard
        dut.i_csr_valid.value = 0
        dut.i_csr_we.value = 0
        dut.i_csr_addr.value = 0
        dut.i_csr_wdata.value = 0

    async def _xfer(self, we: int, addr: int, data: int) -> tuple[int, int]:
        """One request; returns (read data, cycles until accepted)."""
        dut = self.dut
        await FallingEdge(dut.clk)
        dut.i_csr_valid.value = 1
        dut.i_csr_we.value = we
        dut.i_csr_addr.value = addr
        dut.i_csr_wdata.value = data
        for n in range(self.guard):
            await ReadOnly()
            if int(dut.o_csr_ready.value):
                cover("CSR bus", "accepted at once" if n == 0 else "waited (descriptor read)")
                rdata = int(dut.o_csr_rdata.value)
                await RisingEdge(dut.clk)
                await FallingEdge(dut.clk)
                dut.i_csr_valid.value = 0
                return rdata, n
            await FallingEdge(dut.clk)
        raise TimeoutError(f"CSR {'write' if we else 'read'} at {addr:#x} never accepted")

    async def write(self, addr: int, data: int) -> None:
        await self._xfer(1, addr, data & 0xFFFF_FFFF)

    async def read(self, addr: int) -> int:
        return (await self._xfer(0, addr, 0))[0]

    async def read_with_wait(self, addr: int) -> tuple[int, int]:
        return await self._xfer(0, addr, 0)


class MemMaster:
    def __init__(self, dut, guard: int = 10_000):
        self.dut, self.guard = dut, guard
        dut.i_mem_valid.value = 0
        dut.i_mem_we.value = 0
        dut.i_mem_sel.value = 0
        dut.i_mem_addr.value = 0
        dut.i_mem_wdata.value = 0

    async def _request(self, we: int, sel: int, addr: int, data: int) -> None:
        dut = self.dut
        await FallingEdge(dut.clk)
        dut.i_mem_valid.value = 1
        dut.i_mem_we.value = we
        dut.i_mem_sel.value = sel
        dut.i_mem_addr.value = addr
        dut.i_mem_wdata.value = data
        for n in range(self.guard):
            await ReadOnly()
            if int(dut.o_mem_ready.value):
                cover("memory port", "accepted at once" if n == 0 else "waited")
                await RisingEdge(dut.clk)
                await FallingEdge(dut.clk)
                dut.i_mem_valid.value = 0
                return
            await FallingEdge(dut.clk)
        raise TimeoutError(f"memory-port request sel {sel} addr {addr:#x} never accepted")

    async def write(self, sel: int, addr: int, data: int) -> None:
        await self._request(1, sel, addr, data)

    async def read(self, sel: int, addr: int) -> int:
        """Read one word; waits for the single o_mem_rvalid pulse."""
        dut = self.dut
        await self._request(0, sel, addr, 0)
        # The request was accepted at the last rising edge; rvalid may already be high.
        for _ in range(self.guard):
            await ReadOnly()
            if int(dut.o_mem_rvalid.value):
                data = int(dut.o_mem_rdata.value)
                await FallingEdge(dut.clk)
                return data
            await FallingEdge(dut.clk)
        raise TimeoutError(f"no o_mem_rvalid for sel {sel} addr {addr:#x}")

    async def write_block(self, sel: int, base: int, words) -> None:
        """Write consecutive words, one request per cycle (the port accepts writes back to back)."""
        dut = self.dut
        await FallingEdge(dut.clk)
        for i, w in enumerate(words):
            dut.i_mem_valid.value = 1
            dut.i_mem_we.value = 1
            dut.i_mem_sel.value = sel
            dut.i_mem_addr.value = base + i
            dut.i_mem_wdata.value = int(w)
            for _ in range(self.guard):
                await ReadOnly()
                accepted = int(dut.o_mem_ready.value)
                await FallingEdge(dut.clk)
                if accepted:
                    break
            else:
                raise TimeoutError("memory-port write never accepted")
        dut.i_mem_valid.value = 0
