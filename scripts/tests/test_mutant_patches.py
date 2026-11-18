"""RTL mutant patches in testbench/mutants/: each applies cleanly to the current RTL, and each has
a README row whose killing test exists (scripts/run_mutants.py runs them)."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from functools import cache
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = sorted((ROOT / "testbench" / "mutants").glob("*.patch"))


def _load_runner():
    spec = importlib.util.spec_from_file_location(
        "run_mutants", ROOT / "scripts" / "run_mutants.py"
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules["run_mutants"] = mod
    spec.loader.exec_module(mod)
    return mod


RUNNER = _load_runner()
ROWS = {m.name: m for m in RUNNER.parse_readme()}


@cache
def _collected_nodes() -> frozenset[str]:
    out = subprocess.run(
        [sys.executable, "-m", "pytest", "--collect-only", "-q", "-p", "no:cacheprovider",
         "testbench/unit"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout  # fmt: skip
    return frozenset(line.strip() for line in out.splitlines() if "::" in line)


def test_patches_exist():
    assert PATCHES


def test_readme_rows_match_patches():
    assert set(ROWS) == {p.stem for p in PATCHES}


@pytest.mark.parametrize("patch", PATCHES, ids=[p.stem for p in PATCHES])
def test_patch_applies(patch: Path):
    result = subprocess.run(
        ["git", "apply", "--check", str(patch)], cwd=ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("patch", PATCHES, ids=[p.stem for p in PATCHES])
def test_killing_test_exists(patch: Path):
    row = ROWS.get(patch.stem)
    assert row is not None, f"{patch.stem} has no README row"
    assert row.node in _collected_nodes(), f"{row.node} is not a collected pytest node"
