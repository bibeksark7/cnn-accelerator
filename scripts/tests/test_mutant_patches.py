"""Every RTL mutant patch in testbench/mutants/ still applies cleanly to the current RTL."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PATCHES = sorted((ROOT / "testbench" / "mutants").glob("*.patch"))


def test_patches_exist():
    assert PATCHES


@pytest.mark.parametrize("patch", PATCHES, ids=[p.stem for p in PATCHES])
def test_patch_applies(patch: Path):
    result = subprocess.run(
        ["git", "apply", "--check", str(patch)], cwd=ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("patch", PATCHES, ids=[p.stem for p in PATCHES])
def test_patch_is_listed_in_readme(patch: Path):
    readme = (ROOT / "testbench" / "mutants" / "README.md").read_text()
    assert f"`{patch.stem}`" in readme
