#!/usr/bin/env python3
"""Extract the DE10-Lite pin assignments the demo uses from Terasic's golden top.

Source: DE10_LITE_Golden_Top.qar, shipped with Quartus Prime Lite 22.1 under
quartus/common/devplatforms/DE10_LITE_Golden_Top/. Restore it with
`quartus_sh --restore DE10_LITE_Golden_Top.qar -output <dir>` and pass <dir>/platform_setup.tcl.
Keeps the location and I/O-standard assignments of MAX10_CLK1_50, KEY, SW, HEX0..HEX5 and LEDR
(the official Terasic port names) and writes fpga/de10lite/pins.tcl.

Usage: scripts/extract_de10lite_pins.py <platform_setup.tcl>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "fpga" / "de10lite" / "pins.tcl"
PORTS = re.compile(r"-to (MAX10_CLK1_50|KEY\[\d\]|SW\[\d\]|HEX[0-5]\[\d\]|LEDR\[\d\])\s*$")


def main() -> None:
    src = Path(sys.argv[1])
    keep = []
    for line in src.read_text().splitlines():
        line = line.strip()
        if PORTS.search(line) and line.startswith(
            ("set_location_assignment", "set_instance_assignment -name IO_STANDARD")
        ):
            keep.append(line)
    locations = [line for line in keep if line.startswith("set_location_assignment")]
    assert len(locations) == 1 + 2 + 10 + 6 * 8 + 10, f"{len(locations)} location assignments"
    header = [
        "# DE10-Lite pin assignments for the demo top (official Terasic port names).",
        "# Extracted by scripts/extract_de10lite_pins.py from Terasic's DE10_LITE_Golden_Top",
        "# (Quartus Prime Lite 22.1, quartus/common/devplatforms/DE10_LITE_Golden_Top).",
        "# Sourced by fpga/de10lite/build.tcl. Do not edit by hand.",
        "",
    ]
    OUT.write_text("\n".join(header + sorted(keep, key=_order)) + "\n")
    print(f"wrote {OUT} ({len(locations)} pins)")


def _order(line: str) -> tuple:
    port = PORTS.search(line).group(1)
    name, _, idx = port.partition("[")
    return (name, int(idx.rstrip("]") or 0), "set_location" in line)


if __name__ == "__main__":
    main()
