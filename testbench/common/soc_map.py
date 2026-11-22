"""The SoC address map (spec §13.3, §13.4, §13.6) for tests and firmware generators."""

from __future__ import annotations

RAM_BASE = 0x0000_0000
ACCEL_BASE = 0x1000_0000  # CSR window (spec §10.2 offsets)
ACCEL_BUF = 0x1040_0000  # buffer window
GPIO_BASE = 0x2000_0000

# Offsets inside the accelerator's region (what accel_axil_slave sees).
CSR_OFF = 0x00_0000
BUF_OFF = 0x40_0000

# GPIO register offsets (spec §13.6).
GPIO_LEDR, GPIO_HEX, GPIO_SW, GPIO_KEY, GPIO_KEY_EVT, GPIO_MAILBOX = 0x0, 0x4, 0x8, 0xC, 0x10, 0x14
HEX_BLANK_CODES = 0x2108_4210


def buf_offset(sel: int, word: int, half: int = 0) -> int:
    """Offset of one 32-bit half of buffer word `word` in buffer `sel` (spec §13.4)."""
    return BUF_OFF | (sel << 19) | ((word & 0xFFFF) << 3) | (half << 2)
