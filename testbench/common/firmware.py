"""Build a firmware app with firmware/Makefile and read its symbols (D-038, D-042)."""

from __future__ import annotations

import os
import subprocess
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
    args = ["make", "-C", str(FIRMWARE_DIR), f"APP={app}", f"OUT={out}"]
    args += [f"{k}={v}" for k, v in (extra or {}).items()]
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"firmware build failed for {app}:\n{proc.stdout}\n{proc.stderr}")
    return Firmware(app, out)
