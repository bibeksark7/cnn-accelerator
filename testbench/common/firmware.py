"""Build a firmware app with firmware/Makefile and read its symbols (D-038, D-042)."""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from common.runner import REPO_ROOT, SIM_BUILD_DIR

FIRMWARE_DIR = REPO_ROOT / "firmware"
PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf-")


@dataclass
class Firmware:
    app: str
    out: Path

    @property
    def hex(self) -> Path:
        return self.out / f"{self.app}.hex"

    @property
    def elf(self) -> Path:
        return self.out / f"{self.app}.elf"

    def symbols(self) -> dict[str, int]:
        """Address of every symbol in the ELF (from nm)."""
        out = subprocess.run(
            [f"{PREFIX}nm", str(self.elf)], check=True, capture_output=True, text=True
        ).stdout
        syms = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3:
                syms[parts[2]] = int(parts[0], 16)
        return syms

    def toolchain(self) -> str:
        return (self.out / "toolchain.txt").read_text().strip()


def build(app: str, extra: dict[str, str] | None = None) -> Firmware:
    """Run `make APP=<app>`; raises with the compiler output if the build fails."""
    out = SIM_BUILD_DIR / "firmware" / app
    # PYTHON: the generators need NumPy, so they run with this interpreter (the venv's).
    args = ["make", "-C", str(FIRMWARE_DIR), f"APP={app}", f"OUT={out}", f"PYTHON={sys.executable}"]
    args += [f"{k}={v}" for k, v in (extra or {}).items()]
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"firmware build failed for {app}:\n{proc.stdout}\n{proc.stderr}")
    fw = Firmware(app, out)
    # A make run can succeed without building the image (BUG-016): require every output.
    for f in (fw.elf, fw.hex, out / "toolchain.txt"):
        if not f.exists():
            raise RuntimeError(f"firmware build for {app} did not produce {f.name}:\n{proc.stdout}")
    return fw
