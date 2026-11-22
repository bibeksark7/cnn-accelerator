#!/usr/bin/env python3
"""Flat firmware binary -> $readmemh image of 32-bit little-endian words (docs/decisions.md D-042).

Usage: bin2hex.py <in.bin> <out.hex> <ram_bytes>
The image is zero-padded to the whole RAM, so no RAM word is left undefined. Fails if the binary
is larger than the RAM.
"""

from __future__ import annotations

import sys
from pathlib import Path


def convert(data: bytes, ram_bytes: int) -> str:
    if ram_bytes % 4:
        raise ValueError("RAM size must be a multiple of 4")
    if len(data) > ram_bytes:
        raise ValueError(f"image is {len(data)} bytes, RAM is {ram_bytes}")
    data = data + bytes(ram_bytes - len(data))
    words = (int.from_bytes(data[i : i + 4], "little") for i in range(0, ram_bytes, 4))
    return "".join(f"{w:08x}\n" for w in words)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst, ram = Path(argv[1]), Path(argv[2]), int(argv[3], 0)
    try:
        dst.write_text(convert(src.read_bytes(), ram))
    except ValueError as e:
        print(f"bin2hex: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
