"""testbench/sva/fsm_legal_bind.sv must match the RTL: for every bind, the state register's
enum has exactly N_STATES members and is W bits wide, so the assertion's legal range is the
enum's (a stale N_STATES would either miss illegal states or flag legal ones)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
BIND = ROOT / "testbench" / "sva" / "fsm_legal_bind.sv"
BIND_RE = re.compile(
    r"bind\s+(\w+)\s+fsm_legal_sva\s*#\(\s*\.W\s*\((\d+)\)\s*,\s*\.N_STATES\s*\((\d+)\)\s*\)"
    r"\s*\w+\s*\((.*?)\);",
    re.S,
)


def binds() -> list[tuple[str, int, int, str]]:
    out = []
    for module, w, n, ports in BIND_RE.findall(BIND.read_text()):
        state = re.search(r"\.state\s*\(\s*(\w+)\s*\)", ports).group(1)
        out.append((module, int(w), int(n), state))
    return out


def enum_of(module: str, signal: str) -> tuple[int, int]:
    """(width, member count) of the enum type of `signal` in rtl/**/<module>.sv."""
    text = next(ROOT.joinpath("rtl").rglob(f"{module}.sv")).read_text()
    text = re.sub(r"//.*", "", text)
    type_name = re.search(rf"(\w+)\s+{signal}\s*;", text).group(1)
    enum = re.search(
        rf"typedef\s+enum\s+logic\s*\[(\d+):0\]\s*\{{([^{{}}]*)\}}\s*{type_name}\s*;", text
    )
    members = [m.strip() for m in enum.group(2).split(",") if m.strip()]
    return int(enum.group(1)) + 1, len(members)


def test_every_unused_encoding_fsm_is_bound():
    assert len(binds()) == 7, binds()


@pytest.mark.parametrize(("module", "w", "n", "state"), binds())
def test_n_states_matches_enum(module: str, w: int, n: int, state: str) -> None:
    width, count = enum_of(module, state)
    assert (w, n) == (width, count), (
        f"{module}.{state}: bind W={w} N_STATES={n}, enum {width} bits, {count} states"
    )
