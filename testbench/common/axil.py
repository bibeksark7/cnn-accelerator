"""AXI4-Lite master for cocotb tests (spec §13.3).

Same sampling rule as common/handshake.py (docs/bug_log.md BUG-003): signals are driven after a
falling edge, and valid, ready and payload are sampled in ReadOnly of that time step, so a
handshake counts exactly when the next rising edge sees valid && ready.

The master checks the slave's obligations on the response channels as it goes: BVALID / RVALID
held, with response and data unchanged, until accepted, and a write response only after both AW
and W were accepted. AW and W are sent with independent random delays (either order, or the same
cycle), and BREADY / RREADY with random delays, including ready before valid.

Every sampled signal goes through common.sim.resolved, so an X or Z on a handshake or payload
fails with the signal's name and value instead of a conversion error.

Latencies are never assumed; `guard` only catches hangs.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

import cocotb
from cocotb.triggers import FallingEdge, Lock, ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

from common.sim import resolved

OKAY, EXOKAY, SLVERR, DECERR = 0, 1, 2, 3
RESP_NAMES = {OKAY: "OKAY", EXOKAY: "EXOKAY", SLVERR: "SLVERR", DECERR: "DECERR"}


@dataclass
class Timing:
    """Random delays (in cycles) a master inserts; all zeros gives back-to-back traffic."""

    max_skew: int = 3  # AW / W / AR start delay
    max_ready_delay: int = 3  # BREADY / RREADY delay after VALID
    ready_early: float = 0.3  # chance of raising BREADY / RREADY before VALID


class AxilMaster:
    """Drives one AXI4-Lite slave interface of `dut`.

    Signal names are `<pin_in><chan>` for the signals the master drives (e.g. `i_awvalid`) and
    `<pin_out><chan>` for the ones it samples (e.g. `o_awready`).
    """

    def __init__(
        self,
        dut,
        rng: random.Random,
        pin_in: str = "i_",
        pin_out: str = "o_",
        timing: Timing | None = None,
        guard: int = 200_000,
    ):
        self.dut, self.rng, self.guard = dut, rng, guard
        self.timing = timing or Timing()
        self._in, self._out = pin_in, pin_out
        self.clk = dut.clk
        for name in ("awvalid", "awaddr", "wvalid", "wdata", "wstrb", "bready"):
            self.drv(name).value = 0
        for name in ("arvalid", "araddr", "rready"):
            self.drv(name).value = 0
        self.wlock, self.rlock = Lock(), Lock()

    def drv(self, name: str):
        return getattr(self.dut, f"{self._in}{name}")

    def mon(self, name: str):
        return getattr(self.dut, f"{self._out}{name}")

    def _delay(self, limit: int) -> int:
        return self.rng.randint(0, limit) if limit else 0

    async def _send(self, chan: str, payload: dict[str, int], delay: int) -> float:
        """Present one transfer on AW, W or AR after `delay` cycles; returns the handshake time."""
        for _ in range(delay):
            await FallingEdge(self.clk)
        await FallingEdge(self.clk)
        for k, v in payload.items():
            self.drv(k).value = v
        self.drv(f"{chan}valid").value = 1
        for _ in range(self.guard):
            await ReadOnly()
            if resolved(self.mon(f"{chan}ready"), f"AXI {chan.upper()}READY"):
                t = get_sim_time(unit="ns")
                await RisingEdge(self.clk)
                await FallingEdge(self.clk)
                self.drv(f"{chan}valid").value = 0
                return t
            await FallingEdge(self.clk)
        raise TimeoutError(f"AXI {chan.upper()} never accepted")

    async def _recv(self, chan: str, fields: tuple[str, ...]) -> tuple[dict[str, int], float]:
        """Accept one transfer on B or R; checks VALID and payload held until READY."""
        ready = self.drv(f"{chan}ready")
        delay = self._delay(self.timing.max_ready_delay)
        early = self.rng.random() < self.timing.ready_early
        seen = None
        waited = 0
        for _ in range(self.guard):
            await FallingEdge(self.clk)
            ready.value = int(early or (seen is not None and waited >= delay))
            await ReadOnly()
            valid = resolved(self.mon(f"{chan}valid"), f"AXI {chan.upper()}VALID")
            if seen is not None:
                assert valid, f"{chan.upper()}VALID dropped before {chan.upper()}READY"
                now = {f: resolved(self.mon(f), f"AXI {f.upper()}") for f in fields}
                assert now == seen, f"{chan.upper()} payload changed while waiting: {seen} -> {now}"
                waited += 1
            elif valid:
                seen = {f: resolved(self.mon(f), f"AXI {f.upper()}") for f in fields}
            if valid and int(ready.value):
                t = get_sim_time(unit="ns")
                await RisingEdge(self.clk)
                await FallingEdge(self.clk)
                ready.value = 0
                return seen, t
        raise TimeoutError(f"no AXI {chan.upper()} response")

    async def write(self, addr: int, data: int, strb: int = 0xF) -> int:
        """One write; returns BRESP."""
        async with self.wlock:
            tm = self.timing
            aw = cocotb.start_soon(self._send("aw", {"awaddr": addr}, self._delay(tm.max_skew)))
            w = cocotb.start_soon(
                self._send(
                    "w", {"wdata": data & 0xFFFF_FFFF, "wstrb": strb}, self._delay(tm.max_skew)
                )
            )
            (b, t_b) = await self._recv("b", ("bresp",))
            t_aw, t_w = await aw, await w
            assert t_b > max(t_aw, t_w), "B before both AW and W were accepted"
            return b["bresp"]

    async def read(self, addr: int) -> tuple[int, int]:
        """One read; returns (RDATA, RRESP)."""
        async with self.rlock:
            ar = cocotb.start_soon(
                self._send("ar", {"araddr": addr}, self._delay(self.timing.max_skew))
            )
            (r, t_r) = await self._recv("r", ("rdata", "rresp"))
            t_ar = await ar
            assert t_r > t_ar, "R before AR was accepted"
            return r["rdata"], r["rresp"]

    async def write_ok(self, addr: int, data: int, strb: int = 0xF) -> None:
        resp = await self.write(addr, data, strb)
        assert resp == OKAY, f"write {addr:#010x}: {RESP_NAMES[resp]}"

    async def read_ok(self, addr: int) -> int:
        data, resp = await self.read(addr)
        assert resp == OKAY, f"read {addr:#010x}: {RESP_NAMES[resp]}"
        return data
