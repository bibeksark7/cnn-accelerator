"""Build-and-run helper wrapping ``cocotb_tools.runner`` for the pytest test flow.

Every test file defines one or more pytest functions that call :func:`run_cocotb`.
The cocotb coroutines live in the same file, so ``test_module`` is normally
``Path(__file__).stem``.
"""

from __future__ import annotations

import os
from collections.abc import Mapping, Sequence
from pathlib import Path

from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner

REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "rtl"
SIM_BUILD_DIR = REPO_ROOT / "sim_build"

# Simulators every unit test can be parameterized over.
SIMULATORS = ("icarus", "verilator")

_SIM_BUILD_ARGS: dict[str, list[str]] = {
    "icarus": ["-g2012"],
    "verilator": [],
}
# Extra build args when waveforms are requested (Icarus dumps FST via cocotb already).
_SIM_WAVE_ARGS: dict[str, list[str]] = {
    "verilator": ["--trace-fst", "--trace-structs"],
}


def _build_dir_name(toplevel: str, sim: str, parameters: Mapping[str, object]) -> str:
    tag = "_".join(f"{k}{v}" for k, v in sorted(parameters.items()))
    return f"{toplevel}_{sim}" + (f"_{tag}" if tag else "")


def run_cocotb(
    *,
    sim: str,
    toplevel: str,
    sources: Sequence[Path],
    test_module: str,
    parameters: Mapping[str, object] | None = None,
    extra_build_args: Sequence[str] = (),
    seed: int | None = None,
    testcase: str | None = None,
    waves: bool | None = None,
) -> Path:
    """Build ``sources`` for ``sim`` and run the cocotb tests in ``test_module``.

    Fails (raises ``AssertionError``) if any cocotb test fails or no test ran, so the
    pytest result never depends on the simulator exit code alone.

    Waveforms are off by default; set ``WAVES=1`` in the environment to record them.
    """
    params = dict(parameters or {})
    if waves is None:
        waves = os.environ.get("WAVES", "0") == "1"

    build_dir = SIM_BUILD_DIR / _build_dir_name(toplevel, sim, params)
    build_args = [*_SIM_BUILD_ARGS.get(sim, []), *extra_build_args]
    if waves:
        build_args += _SIM_WAVE_ARGS.get(sim, [])

    runner = get_runner(sim)
    runner.build(
        sources=list(sources),
        hdl_toplevel=toplevel,
        parameters=params,
        build_args=build_args,
        build_dir=build_dir,
        timescale=("1ns", "1ps"),
        waves=waves,
        always=True,
    )
    results_xml = runner.test(
        hdl_toplevel=toplevel,
        test_module=test_module,
        parameters=params,
        build_dir=build_dir,
        test_dir=build_dir,
        seed=seed,
        testcase=testcase,
        timescale=("1ns", "1ps"),
        waves=waves,
    )

    num_tests, num_failed = get_results(results_xml)
    assert num_tests > 0, f"no cocotb tests ran ({results_xml})"
    assert num_failed == 0, f"{num_failed}/{num_tests} cocotb tests failed ({results_xml})"
    return results_xml
