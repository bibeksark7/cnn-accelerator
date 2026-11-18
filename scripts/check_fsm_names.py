#!/usr/bin/env python3
"""Check that testbench FSM state-name lists match the RTL enum declarations.

Testbenches decode FSM state registers by position (e.g. ``Q_NAMES[int(dut.qstate_q.value)]``),
so a list that drifts from the enum silently mislabels coverage. For each entry in CHECKS, the
enum's members, with its prefix removed, must equal the Python list exactly and in order. Enums
with explicit member values are rejected (the position would no longer be the encoding).

Usage: scripts/check_fsm_names.py      exit 0 when every list matches its enum.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (RTL file, enum type name, member prefix, Python file, list variable)
CHECKS = [
    ("rtl/core/gemm_engine.sv", "qstate_t", "Q_", "testbench/unit/test_gemm_engine.py", "Q_NAMES"),
    ("rtl/core/gemm_engine.sv", "dstate_t", "D_", "testbench/unit/test_gemm_engine.py", "D_NAMES"),
]

ENUM_RE = re.compile(
    r"typedef\s+enum\s+logic\s*\[[^\]]*\]\s*\{(?P<body>[^}]*)\}\s*(?P<name>\w+)\s*;"
)


def strip_comments(sv: str) -> str:
    sv = re.sub(r"/\*.*?\*/", "", sv, flags=re.S)
    return re.sub(r"//[^\n]*", "", sv)


def enum_members(sv: str, type_name: str) -> list[str]:
    """Members of `typedef enum logic [...] { ... } type_name;` in declaration order."""
    for m in ENUM_RE.finditer(strip_comments(sv)):
        if m["name"] == type_name:
            members = [x.strip() for x in m["body"].split(",") if x.strip()]
            explicit = [x for x in members if "=" in x]
            if explicit:
                raise ValueError(f"{type_name}: explicit values not supported: {explicit}")
            return members
    raise ValueError(f"enum {type_name} not found")


def python_list(py: str, var: str) -> list[str]:
    for node in ast.parse(py).body:
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == var for t in node.targets
        ):
            return list(ast.literal_eval(node.value))
    raise ValueError(f"list {var} not found")


def check(sv: str, type_name: str, prefix: str, py: str, var: str) -> str | None:
    """None if the list matches the enum, else a description of the mismatch."""
    members = enum_members(sv, type_name)
    bad_prefix = [x for x in members if not x.startswith(prefix)]
    if bad_prefix:
        return f"{type_name}: members without prefix {prefix}: {bad_prefix}"
    want = [x[len(prefix) :] for x in members]
    got = python_list(py, var)
    if got != want:
        return f"{var} = {got} but {type_name} declares {want}"
    return None


def main() -> int:
    rc = 0
    for rtl, type_name, prefix, pyfile, var in CHECKS:
        sv, py = (ROOT / rtl).read_text(), (ROOT / pyfile).read_text()
        try:
            problem = check(sv, type_name, prefix, py, var)
        except ValueError as e:
            problem = str(e)
        if problem:
            print(f"FAIL {pyfile}:{var} vs {rtl}:{type_name}: {problem}")
            rc = 1
        else:
            print(f"ok   {pyfile}:{var} matches {rtl}:{type_name}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
