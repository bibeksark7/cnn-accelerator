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

## D-006 — Network channel counts kept as specified (Phase 1)

**Decision.** Keep conv1 = 8 and conv2 = 16 channels (5,258 parameters).

**Reason.** The float model reaches the required accuracy without changes
(`model/reports/train.json`, from `model/train.py`).

## D-007 — HWC activation layout; FC flatten in HWC order at training time (Phase 1)

**Decision.**
- All activations are channel-last (HWC). The im2col reduction index is
  `k = (ky·3 + kx)·C_in + ci`.
- The PyTorch model flattens pool2's output in HWC order (`permute(0, 2, 3, 1)`) before the FC
  layer, so the trained FC weights are already in hardware order.

**Alternatives.** CHW layout (PyTorch's native one); permuting FC weights at export.

**Reason.**
- With HWC, one 3×3 kernel tap reads `C_in` consecutive bytes, and the CONV output
  `(m, co)` lands at `m·C_out + co`, which is directly the next layer's HWC input. No layout
  conversion is needed between layers.
- Training in HWC order removes a permutation step that would be an easy place for a silent
  bug.

## D-008 — Quantization details (Phase 1)

**Decision.**
- **Weights:** clamped to [−127, 127] (symmetric, −128 unused).
- **Activation scales:** calibrated as the maximum post-ReLU activation over 10,000 training
  images. That was chosen over 99.999/99.99/99.9 percentiles by integer accuracy on the 5,000-image
  validation split; ties go to the larger percentile.
- **`M`, `S`:** `S = 15 − ⌊log2 m⌋`, `M = round(m·2^S)`, with a carry fix if rounding reaches
  2^16.
- **Test set:** used only for the final reported numbers.

**Alternatives.** Percentile calibration; quantization-aware training.

**Reason.** Post-training quantization with max calibration already stays well within the 1%
budget (`model/reports/quantize.json`), so the simpler method wins. A side effect: real MNIST
data never saturates the requantizer, so saturation coverage comes from directed tests (see
`docs/verification_plan.md`).

## D-009 — Buffer bandwidth: staged A, pre-packed wide B words (Phase 1)

**Decision.**
- **B:** weights are packed offline into `N·DATA_W`-bit words (one reduction step per word,
  column-tile major).
- **A:** activations are gathered one byte per cycle by the im2col/linear address generator into
  N byte-wide staging banks of depth `K_TILE = 128`. They are then streamed N bytes per cycle.
  GEMMs with K > `K_TILE` (fc, K = 400) run in K chunks with the output-stationary accumulators
  kept between chunks.

**Alternatives.**
- N-banked activation buffers (im2col rows are not contiguous, so bank conflicts need a complex
  layout).
- Staging whole K for every tile (3.2 KB of A storage for fc).
- Double-buffered staging (faster, more control logic).

**Reason.** Simplest scheme that is clearly correct. Weight bandwidth comes for free from the
offline packing. `K_TILE = 128` keeps each staging bank in one MAX 10 M9K block, and it makes the
real network exercise K-chunking (fc), so the system test covers that path. The utilization cost
is accepted for Milestone 1.

## D-010 — Image selection by CSR offset, separate image buffer (Phase 1)

**Decision.** Input images live in a dedicated IMG buffer. Conv1's descriptor reads `src = IMG`,
and the effective base is `src_base + IMG_SEL · 784`, with `IMG_SEL` a CSR latched at START.

**Alternatives.** The host rewrites conv1's descriptor for every image; images in ACT0.

**Reason.** The descriptor table stays static (the network is pure data), the FPGA top only
drives `IMG_SEL` from the switches, and ping-pong layers can never overwrite an image, so images
run back to back without reloading.

## D-011 — Committed model artifacts and generation flow (Phase 1)

**Decision.**
- **Committed:**
  - `model/artifacts/float_weights.npz` (trained float weights);
  - `params.npz` (integer parameters);
  - `quick_subset.npz` (50 images: the first 5 of each class in test-set order, with expected
    logits);
  - `mem/*.hex` + `mem/layout.json` (weight, parameter and descriptor memory images).
- **Generation:** `train.py` → `quantize.py` → `export.py`. Quantize and export are
  deterministic, and `scripts/checkpoint.sh 1` regenerates them and requires byte-identical
  output.
- **FPGA init files** for the 16 board images (and their labels) are generated in Phase 4, when
  the board top defines them.

**Reason.**
- Training is not bit-reproducible across machines. Committing the float weights lets anyone
  re-run quantization and export exactly, and CI needs only NumPy.
- A class-balanced quick subset exercises every output class.

## D-012 — Golden-model overflow check by an order-independent bound (Phase 1)

**Decision.** For every GEMM, the golden model asserts `Σ_k |A·B| + |bias| ≤ 2^31 − 1` rather than
checking only the final sums.

**Reason.** The hardware accumulates in a different order than NumPy, with K chunks and bias added
last. The bound guarantees that no partial sum overflows in any order, so a passing golden run
proves that 32-bit accumulators (which wrap rather than saturate) are always exact.

## D-013 — Spec scope: what is normative (Phase 1)

**Decision.** `docs/spec.md` fixes as normative:
- the arithmetic, data layouts and memory formats;
- the descriptor format and execution semantics;
- the CSR map, CSR bus and memory port;
- the interfaces of `accel_top` and `systolic_array`.

Internal module interfaces are defined in module headers during Phase 2 and summarized in
`docs/architecture.md`. Buffer read latency (1 cycle) is the only fixed latency.

**Reason.** These are the contracts that tests, firmware (Milestone 2) and the
weight-stationary array (Milestone 3) depend on. Keeping internal partitioning out of the spec
leaves room to refactor RTL without changing the spec.

## D-014 — Spec review changes before Phase 2 (Phase 1 review)

**Decision** (approved in the Phase 1 review). `docs/spec.md` now specifies:
- **Reset values** for every CSR (§10.2): 0 unless stated; `ID`/`CONFIG` are constants. `rst`
  does not clear the descriptor table or any buffer.
- **Array step timing** (§11.2): `i_valid` may deassert between steps (including between K
  chunks). Accumulators hold, and results depend only on the step sequence, not its timing.
- **Drain window** (§11.2): from `i_drain` until the last row is accepted, the producer asserts
  neither `i_valid` nor `i_clear`.
- **Optional A reuse** (§5): when `K ≤ K_TILE`, the staged A tile may be reused across all column
  tiles of a row tile.
- **Post-processing implementation** (§3.1): `M` is multiplied as `$signed({1'b0, M})`, and the
  datapath is pipelined (multiply → round/shift → saturate/ReLU).

**Reason.**
- Reset values make the post-reset state testable ("no X after reset").
- Not clearing buffers lets a reset recover without reloading.
- Gap-tolerant step timing lets the GEMM engine stall between steps (staging, buffer latency) and
  keeps the interface implementable by the weight-stationary array (D-015).
- The signed-multiply note prevents a classic Verilog bug: mixing signed and unsigned operands
  makes the whole multiply unsigned.
- A single-cycle multiply-round-saturate path would not close at 50 MHz on the MAX 10.

## D-015 — The `systolic_array` interface (spec §11.2) is implementable weight-stationary (Phase 1 review)

**Decision.** Freeze §11.2 for both arrays. This sketch shows `systolic_array_ws` can implement it
with no backpressure and no interface change.

**Mapping.** Reduction steps are grouped into blocks of N (`g = k / N`, `r = k mod N`). PE
`(r, j)` holds weight `B[gN + r][j]`. For output row `i`, array row `r` receives `A[i][gN + r]`
(skewed by `r`). Partial sums flow down the columns, and the bottom of column `j` yields
`Σ_r A[i][gN+r] · B[gN+r][j]`. That value is added into an N × N int32 accumulator bank (the same
storage the output-stationary array keeps in its PEs).

**How the interface's data arrives.** Step `k` delivers `i_b` = `B[k][0..N−1]` and
`i_a` = `A[0..N−1][k]`. That is exactly one weight row for array row `r` and the N activations
array row `r` will need.
- **Weights.** Each PE has an active and a shadow weight register. Step `r` of block `g + 1`
  writes `i_b` into the shadow registers of row `r`. Row `r` copies shadow → active at the start
  of its (skewed) streaming window for that block. A row's shadow is rewritten no earlier than the
  cycle it is copied, so two registers per PE suffice.
- **Activations.** Each array row has a double-buffered N-byte register. Step `r` of a block
  fills one bank while the previous block's bank is streamed out over N cycles.
- **Throughput.** A block takes N cycles to arrive and N cycles to stream, so one step per cycle
  is sustained indefinitely. `i_valid` therefore needs no `ready`. Gaps between steps only delay
  a block's start and are harmless, which is why §11.2 allows them.
- **Drain.** On `i_drain` a partial last block is padded internally with zero steps. The
  pipeline is flushed, and rows are emitted from the accumulator bank through the same
  `o_row_*` handshake. The extra latency is allowed because drain latency is
  implementation-specific.
- **Clear.** `i_clear` zeroes the accumulator bank.

**Cost compared with output-stationary.**
- Extra storage: two weight registers per PE (2·N²·8 bits) and 2·N·N activation bytes.
- Same accumulator bank and multiplier count.

**Conclusion.** Workable. Testbenches written against §11.2 (handshakes only, no cycle counts)
run unchanged on both arrays.
