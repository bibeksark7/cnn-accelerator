# Design and project decisions

Each entry: **decision**, alternatives considered, reason. Newest at the bottom.

---

## D-001 — Toolchain: OSS CAD Suite snapshot 2026-11-01, appended to PATH (Phase 0)

**Decision.** Install the YosysHQ OSS CAD Suite prebuilt tarball
(`oss-cad-suite-linux-x64-20261101.tgz`, release tag `2026-11-01`) into `~/tools/oss-cad-suite`.
Only its `bin/` directory is added, at the **end** of `PATH` in `~/.bashrc`
(`export PATH="$PATH:$HOME/tools/oss-cad-suite/bin"`); its `environment` script is never sourced.
`scripts/env.sh` applies the same rule for scripts and CI.

**Alternatives.** Distribution packages (Ubuntu's Verilator is too old for cocotb 2.x);
building Verilator from source (slower, and still no Yosys/SymbiYosys); the newest nightly
(less settled).

**Reason.** One download provides Verilator, Yosys, SymbiYosys and solvers with no `sudo`.
The suite also ships `iverilog`, `vvp` and its own Python; appending it to `PATH` guarantees the
system Icarus 12 and the project venv always win. A snapshot about two weeks old is pinned so
the local machine and CI use the same versions.

**Verified (2026-11-17, venv active, login shell):**

| Check | Result |
|---|---|
| `which python` | `~/cnn-accelerator/.venv/bin/python` (Python 3.14.4) |
| `which iverilog` | `/usr/bin/iverilog` |
| `iverilog -V` | `Icarus Verilog version 12.0 (stable)` |
| `which verilator` | `~/tools/oss-cad-suite/bin/verilator` |
| `verilator --version` | `Verilator 5.053 devel rev v5.052-654-gdd8a7d5e4` (≥ 5.036 required) |
| `yosys -V` | `Yosys 0.70+286 (git sha1 63eecf3dd)` |
| `sby --help` | runs (SymbiYosys from the same suite) |

## D-002 — Test flow: pytest + `cocotb_tools.runner` with a shared helper (Phase 0)

**Decision.** Each test file holds its cocotb coroutines plus a pytest entry point that calls
`testbench/common/runner.py::run_cocotb()`. The helper builds into
`sim_build/<toplevel>_<sim>[_<params>]`, passes `-g2012` to Icarus, enables FST tracing only when
`WAVES=1`, and asserts from the cocotb results file that at least one test ran and none failed.
`pyproject.toml` sets `pythonpath = ["testbench"]` so `common` imports both under pytest and
inside the simulator (the runner forwards `sys.path` as `PYTHONPATH`).
CI additionally checks pytest's JUnit XML with `scripts/check_junit.py` (fails on zero tests,
failures, errors, or unexpected skips).

**Alternatives.** Per-test cocotb Makefiles (the original setup); `cocotb-test`.

**Reason.** One command (`pytest testbench`) runs everything; tests parameterize naturally over
simulator and RTL parameters; no extra dependency.

## D-003 — Counter RTL repaired; exempt from port-naming convention (Phase 0)

**Decision.** `rtl/counter.sv` had a Python-style `"""` docstring inside the module, which no
tool accepts (see BUG-001). It was replaced with a `//` header comment, and the increment constant
was sized (`8'd1`) so the file is `verilator -Wall` clean. Port names (`clk`, `rst`, `en`, `count`)
are unchanged and do not use the `i_`/`o_` prefixes.

**Reason.** The counter is a toolchain check only and is deleted once the core RTL has tests in
CI (Phase 2). Renaming its ports would be an interface change for a throwaway module.

## D-004 — Python tooling pins (Phase 0)

**Decision.**
- `requirements.txt` (CI and simulation): cocotb 2.1.0, pytest 9.2.0, numpy 2.5.4, ruff 0.17.3
  plus their exact transitive pins.
- `requirements-dev.txt` (training): includes `requirements.txt`, then torch 2.14.1+cpu,
  torchvision 0.29.1+cpu (PyTorch CPU wheel index), matplotlib 3.11.2, with exact transitive pins.
- Ruff config in `pyproject.toml`: target `py314`, line length 100, rule sets
  `E, F, W, I, B, UP, SIM, RUF`.

**Alternatives.** torch 2.15.0 (newest, but its torchvision pairing was less clear: torchvision
0.29.2 has no cp314 Linux wheel); ruff 0.17.5 (released less than a week before installation).

**Reason.** torch 2.14.1 and torchvision 0.29.1 were released together as a matched pair and
both ship cp314 wheels. CPU wheels avoid a multi-GB CUDA download that training this network
does not need.

## D-005 — CI environment (Phase 0)

**Decision.** GitHub Actions on `ubuntu-24.04`: Python 3.14 (`actions/setup-python`), Icarus 12
from apt, and the same OSS CAD Suite snapshot as D-001, downloaded once and kept in
`actions/cache` keyed by the snapshot tag. One job runs: tool-version report (asserting Icarus 12
comes from the system), ruff, `scripts/lint.sh`, unit tests on both simulators, and a results-file
check.

**Reason.** Matches the local tool versions exactly, needs no Verilator source build, and the
cache keeps runs fast after the first.
