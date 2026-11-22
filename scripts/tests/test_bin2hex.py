"""firmware/tools/bin2hex.py: flat binary -> $readmemh image (32-bit little-endian words,
zero-padded to the RAM size; an image larger than the RAM is rejected)."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bin2hex", ROOT / "firmware" / "tools" / "bin2hex.py")
bin2hex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bin2hex)


def test_little_endian_words_and_padding():
    text = bin2hex.convert(bytes([0x78, 0x56, 0x34, 0x12, 0xAA]), 16)
    assert text.splitlines() == ["12345678", "000000aa", "00000000", "00000000"]


def test_exact_fit():
    assert len(bin2hex.convert(bytes(64), 64).splitlines()) == 16


def test_too_large():
    with pytest.raises(ValueError, match="RAM is 8"):
        bin2hex.convert(bytes(9), 8)


def test_cli(tmp_path: Path):
    src, dst = tmp_path / "a.bin", tmp_path / "a.hex"
    src.write_bytes(b"\x01\x00\x00\x00")
    assert bin2hex.main(["bin2hex", str(src), str(dst), "0x8"]) == 0
    assert dst.read_text() == "00000001\n00000000\n"
    assert bin2hex.main(["bin2hex", str(src), str(dst), "2"]) == 1
