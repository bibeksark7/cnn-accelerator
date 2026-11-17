"""Valid/ready stream source and sink with one sampling rule (see docs/bug_log.md BUG-003).

Rule: control and payload are driven after a falling edge; valid, ready and payload are then
sampled in ReadOnly of that same time step. Those are exactly the values the next rising edge
uses, so a transfer is counted iff valid and ready are both high there.

A source holds its payload and valid stable until the transfer happens (AXI-style rule).
"""

from __future__ import annotations

import random
from collections.abc import Callable, Sequence
from typing import Any

from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


async def drive_stream(
    clk,
    valid,
    ready,
    items: Sequence[Any],
    set_payload: Callable[[Any], None],
    rng: random.Random,
    idle_prob: float = 0.0,
    guard_cycles: int = 100_000,
) -> None:
    """Send `items` in order. `set_payload(item)` writes the payload signals."""
    i = 0
    presenting = False
    for _ in range(guard_cycles):
        if i == len(items):
            break
        await FallingEdge(clk)
        if not presenting:
            if rng.random() < idle_prob:
                valid.value = 0
            else:
                set_payload(items[i])
                valid.value = 1
                presenting = True
        await ReadOnly()
        if presenting and int(ready.value):
            i += 1
            presenting = False
        await RisingEdge(clk)
    else:
        raise TimeoutError(f"source sent {i}/{len(items)} items before the guard expired")
    await FallingEdge(clk)
    valid.value = 0


async def collect_stream(
    clk,
    valid,
    ready,
    count: int,
    get_payload: Callable[[], Any],
    rng: random.Random,
    ready_prob: float = 1.0,
    guard_cycles: int = 100_000,
) -> list[Any]:
    """Receive `count` items; `get_payload()` reads the payload (called in ReadOnly)."""
    out: list[Any] = []
    for _ in range(guard_cycles):
        if len(out) == count:
            break
        await FallingEdge(clk)
        ready.value = int(rng.random() < ready_prob)
        await ReadOnly()
        if int(valid.value) and int(ready.value):
            out.append(get_payload())
        await RisingEdge(clk)
    else:
        raise TimeoutError(f"sink got {len(out)}/{count} items before the guard expired")
    await FallingEdge(clk)
    ready.value = 0
    return out
