"""Two's-complement packing helpers for driving and reading packed RTL vectors.

All signal assignments in the testbench use non-negative integers produced here, so behaviour
never depends on how the simulator interface treats negative Python ints.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence


def to_unsigned(value: int, width: int) -> int:
    """Two's-complement encode `value` into `width` bits; raises if it does not fit."""
    lo, hi = -(1 << (width - 1)), (1 << width) - 1
    if not lo <= value <= hi:
        raise ValueError(f"{value} does not fit in {width} bits")
    return value & ((1 << width) - 1)


def to_signed(value: int, width: int) -> int:
    """Interpret the low `width` bits of `value` as a two's-complement number."""
    value &= (1 << width) - 1
    return value - (1 << width) if value >> (width - 1) else value


def pack(values: Iterable[int], width: int) -> int:
    """Element 0 in the least significant `width` bits (matches `[i*W +: W]` slicing in RTL)."""
    word = 0
    for i, v in enumerate(values):
        word |= to_unsigned(int(v), width) << (i * width)
    return word


def unpack(word: int, width: int, count: int, signed: bool = True) -> list[int]:
    mask = (1 << width) - 1
    fields = [(word >> (i * width)) & mask for i in range(count)]
    return [to_signed(f, width) for f in fields] if signed else fields


def pack_matrix(rows: Sequence[Sequence[int]], width: int) -> int:
    """Row-major packing: element (r, c) at index r * ncols + c."""
    return pack([v for row in rows for v in row], width)
