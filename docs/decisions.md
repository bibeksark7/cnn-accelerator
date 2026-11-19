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
- Pipelining the multiply → round/shift → saturate path gives timing margin at 50 MHz on the
  MAX 10. Whether a single-cycle path would close was not evaluated.

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
- **Block start.** A block starts streaming only after all N of its steps have arrived (or, for a
  partial last block, after it is padded at drain). Each row's skew is measured from that start,
  so gaps between steps, including gaps inside a block, only delay the block. They cannot
  misalign partial sums, which is why §11.2 allows them.
- **Throughput.** A block takes N cycles to arrive and N cycles to stream, so one step per cycle
  is sustained indefinitely. `i_valid` therefore needs no `ready`.
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

## D-016 — Spec review round 2: rounding width, array handshake ordering, START condition (Phase 1 review)

**Decision** (approved in the Phase 1 review, round 2). `docs/spec.md` now requires:
- **§3.1:** the rounding constant is a signed value at least 49 bits wide (e.g.
  `49'sd1 <<< (S − 1)`), and `>>>` is applied to a signed operand.
- **§11.2:**
  - `i_clear` never coincides with `i_valid`;
  - `i_drain` never coincides with the last `i_valid` (it comes in a later cycle).
- **§9 / §10.2:** `START` is accepted only when the accelerator is idle and no memory-port read
  is pending; otherwise it is ignored.

D-015 now states explicitly that a weight-stationary block starts streaming only after all N of
its steps have arrived.

**Reason.**
- In Verilog, a narrow or unsigned rounding constant truncates or makes the expression unsigned,
  and `>>>` on an unsigned operand is a logical shift. Either bug corrupts negative results.
- Forbidding same-cycle `i_clear`/`i_valid` and `i_drain`/last `i_valid` removes ordering
  ambiguities that an output-stationary and a weight-stationary array could otherwise resolve
  differently.
- Refusing `START` while a memory-port read is in flight keeps the port's response from
  colliding with a run's buffer accesses.

**Clarification (Phase 2 batch 3 review, approved).** "Pending" means accepted at an earlier
edge. A read accepted in the same cycle as `START` was not pending when `START` was checked, so
both are accepted: the buffer is read at that edge, while the memory port still owns it, and the
data returns with `o_mem_rvalid` while `BUSY` is already high (spec §10.3). The select is
registered with the read, so the run's buffer traffic cannot disturb the returned word.
`testbench/system/test_accel_top.py::test_csr_rules` offers a read and `START` in one idle cycle
and checks that both are accepted, that exactly one `o_mem_rvalid` returns the right word while
`BUSY` is high, and that the run's logits are unaffected.

## D-017 — Output-stationary array implementation (Phase 2)

**Decision.** `systolic_array`:
- **Skew:** input skew uses one tapped delay line per operand; row/column `i` taps stage `i − 1`.
- **Flush detection:** a step is "in flight" while its valid bit is anywhere in the skew line
  or the PE grid. The drain FSM (`S_IDLE → S_FLUSH → S_EMIT`) waits for that to clear, then
  emits rows 0…N−1 through a row multiplexer.
- **No fixed flush latency:** the wait is computed from the valid bits, not a counter.

- **`o_idle`:** built only from registered state (the skew-line and grid valid bits plus the
  drain FSM), so it has no combinational path from any input. A step presented in the current
  cycle is not yet counted.
- **Delay lines:** packed 2D arrays, with taps assigned in a named generate loop.

**Alternatives.**
- Triangular per-row shift registers. Not fewer flops: lane `i` never reads stages `≥ i` of the
  tapped line, so synthesis removes them and both give the same flop count. The tapped line is
  simply less generate code.
- A cycle counter for the flush (would encode a latency).
- Shifting accumulators out of the grid (cheaper than a mux, slower drain).

**Reason.** Valid-tracking makes the flush correct for any step timing, including gaps, which
§11.2 allows, and makes `o_idle` exact. The row multiplexer keeps drain logic trivial; its cost
will be measured in the Phase 4 synthesis report.

**Correction (Phase 2 batch 1 review).** An earlier version of this entry called "remove the grid
valid bits from the flush condition" an *equivalent* mutant. That was wrong. Output rows are
unaffected (emission trails the wavefront), but `o_idle` is part of the §11.2 interface. With the
mutant, `o_idle` rises while later PEs are still accumulating, and a clear issued then leaves stale
products in the accumulators. `test_idle_then_clear_discards_partial_sums` and the
`a_idle_means_empty` assertion now both catch it (BUG-004).

## D-018 — Testbench conventions (Phase 2)

**Decision.**
- **Drive and sample timing:** inputs are driven after a falling edge; outputs are sampled in
  `ReadOnly`. A valid/ready transfer is counted only from values sampled before the rising edge
  that performs it (`testbench/common/handshake.py`; see BUG-003).
- **Signed values:** packed into unsigned integers in the testbench (`common/bits.py`).
- **Seeds:** every random test logs its seed (`TB_SEED`, fixed default).
- **Expected values:** come from `model/golden.py` wherever the golden model defines the
  arithmetic.
- **Timeouts:** only hang guards, never expected latencies.
- **Exception: synchronous-read buffer models.** The engine test's buffer model (`serve()` in
  `test_gemm_engine.py`) samples read requests with the rule above, but drives the read data
  *immediately after* the rising edge that accepts the request, not after the next falling edge.
  It models a RAM's registered output, which changes at the clock edge. The data is then stable
  for the whole cycle in which the engine consumes it, exactly the 1-cycle latency of spec §5.
- **Done pulses:** a one-cycle `o_done` is watched from the first rising edge after the cycle that
  raises `i_start`, because a unit with nothing to do may finish immediately (BUG-009).

**Reason.** One sampling rule for every interface removes a whole class of off-by-one-edge
testbench bugs. Reproducible seeds make failures debuggable. Checking against the golden model
keeps RTL and model bit-exact by construction.

## D-019 — Spec §3.1: post-processing stage list allows a split multiply stage (Phase 2)

**Decision** (approved in the Phase 2 batch 1 review). §3.1 already required "at least three"
register stages. Its stage list now states that the first step (bias add and multiply) may take
two stages: register `y`, `M` and `S`, then multiply the registered operands into a registered
product. `postproc` uses four stages: y/M/S → multiply → round/shift → saturate/ReLU.

**Reason.** Giving the multiply its own stage, with registered operands, keeps the 32-bit bias
add off the multiplier's path. In the Quartus probe (`fpga/probe_reports/postproc/`, D-024), the
32 × 17 multiply maps onto the MAX 10's embedded DSP multipliers, while the pipeline registers
around it stay in logic. Order and arithmetic are unchanged, and the latency is still not part of
any interface.

## D-020 — Post-v1.0 performance and area ideas, deferred (Phase 2)

Not implemented before `v1.0` (Milestone 1 is correctness-first). Recorded so they are not lost.

Performance:
- **Overlap staging with drain.** While the array drains and post-processes one output tile, the
  A loader could already stage the next tile's A chunk.
  - **No second staging bank set is needed.** The banks are free as soon as streaming ends,
    because the accumulators, not the banks, hold the tile being drained.
  - Only overlapping staging with *streaming* would need double-buffered banks.
  - **Conflict with A reuse (§5):** reuse keeps the staged A across all column tiles of a row
    tile, so the banks are not free during the drain unless the next tile starts a new row
    tile.
  - With the three-FSM engine (D-023), this is a scheduling change, not a datapath change.
- **Byte-enabled staging RAM.** Replace the N byte-wide staging banks with one `N·DATA_W`-wide RAM
  with byte enables. Quartus maps that to fewer, fuller M9K blocks. The A loader keeps writing one
  byte per cycle (one byte enable), and streaming reads one full word.
- **Reuse staged A across column tiles (spec §5 "optional reuse").** When a layer has a single
  K chunk (`K ≤ K_TILE`), keep the staged A tile for every column tile of a row tile instead of
  restaging it. conv2 (2 column tiles, K = 72) would save about 8.7k cycles per image
  (121 · 72 staged bytes). It conflicts with overlapping staging and drain (above).
- **Exact cycle model.** A `model/perf.py` that predicts every layer's cycle count exactly from
  the descriptor and the engine's schedule, asserted against `LAYER_CYC` and the engine test's
  busy cycles. It would make the dataflow study (Phase 7) and any scheduling change measurable
  before simulation.

Area:
- **Post-processing flags.** `requant_en` and `relu_en` are constant for a whole layer, so they
  need not travel through every pipeline stage (today they are registered into stage 3 alongside
  each element). They could come straight from the layer configuration.
- **Shared post-processing output register.** `o_q8` and `o_y` are never both used for the same
  element (requantized int8 for CONV, int32 for FC). Stage 4 could register one 32-bit result
  instead of two.
- **Row multiplexer.** The drain's N:1 multiplexer over `N·ACC_W`-bit rows could be replaced by
  shifting accumulators down the columns during the drain, trading logic for drain cycles.
- **Accumulator width.** The golden model's overflow bound gives the largest accumulator magnitude
  for a given network. A narrower `ACC_W` (a spec change) would shrink every PE accumulator and
  the drain path. `ACC_W = 32` stays the spec for generality.

## D-021 — MAX 10 configuration mode for initialized block RAM (Phase 2)

**Decision.** Every Quartus project for this design sets
`INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"` (single uncompressed image with memory
initialization). Phase 4's `build.tcl` must include it.

**Evidence.** A Quartus Prime Lite 22.1std Analysis & Synthesis probe of `sram_1r1w` (1024 × 64,
`$readmemh` init file) on the 10M50DAF484C7G:
- **Default configuration mode:** Quartus reported `RAM logic "mem" is uninferred because MIF is
  not supported for the selected family`. It built the memory from registers and logic.
- **With the setting:** it inferred an M9K simple-dual-port RAM, and its generated MIF matched the
  init file word for word.

The first probe was run by hand. `scripts/quartus_probe.sh` now generates every probe project
from a template that always includes this setting.

**Reason.** The FPGA demo preloads weights, parameters, descriptors and images through init
files. Without memory initialization, the buffers would not map to block RAM at all.

**Trade-off.** This mode gives up the MAX 10's dual-image configuration (two images in internal
flash, for remote update or fallback) and configuration bitstream compression. Neither is needed
for this project.

## D-022 — RTL rules for Quartus Prime Lite 22.1 compatibility (Phase 2)

**Decision.** In addition to the coding rules in the project's RTL style:
- generate constructs always use explicit `generate … endgenerate`;
- genvars are declared at module scope (`genvar gi, gj;`), never inline in `for`, and loops step
  with `gi = gi + 1`;
- no unary minus applied to a size cast (`-N'(x)`); use typed signed localparams for such
  constants;
- every new module gets a Quartus Analysis & Synthesis probe before it is committed, until the
  Phase 4 build covers the whole design.

`scripts/check_quartus_compat.py` (run by `scripts/lint.sh`) enforces the first three rules
(BUG-005); `scripts/quartus_probe.sh` runs the probes.

**Reason.** Quartus is the one required tool that cannot run in CI, and its front end rejected
constructs the other three accept. Encoding the rules in lint keeps CI meaningful for it.

## D-023 — GEMM engine structure: three FSMs linked by handshakes (Phase 2)

**Decision.** The GEMM engine is three small FSMs:
- **A load:** stages one A chunk into the staging banks through the address generator;
- **stream:** reads the staging banks and WGT words and presents reduction steps to the array;
- **drain:** pulses `i_drain`, takes result rows, and feeds post-processing and write-back.

They are linked by valid/ready-style start/done handshakes. A small top-level sequencer runs them
strictly one after another for each (row tile, column tile, K chunk) in `v1.0`.

**Alternatives.** One monolithic FSM (simplest to write, hardest to change and to verify); an
overlapped pipeline now (faster, but conflicts with the correctness-first M1 goal).

**Reason.**
- Each control block is small and is covered through the engine-level tests, internal assertions
  (`testbench/sva/gemm_engine_impl_sva.sv`: each block starts only when idle, stream only on
  `load_done`, drain only after the last chunk, at most one block active) and FSM transition
  coverage of the sequencer and drain FSMs (`test_fsm_transition_coverage`). They are not
  unit-tested as separate modules (D-026).
- Because they communicate only through handshakes, the D-020 overlaps become scheduling changes
  in the sequencer, not rewrites of the datapath FSMs.

## D-024 — Quartus fit and timing probes of the array and post-processing (Phase 2)

**Decision.** `systolic_array` (N = 8) and `postproc` are fitted and timed on their own with
`scripts/quartus_probe.sh --fit --virtual-pins --clock clk:20.000`:
- 50 MHz `create_clock`;
- every `i_*`/`o_*` port and `rst` a virtual pin, so the clock stays a real pin.

Reports are committed under `fpga/probe_reports/<module>/`.

**Results** (slow 1200 mV 85 °C model unless noted):

| Module | Worst setup slack | Worst hold slack (fast 0 °C) | Fmax | Critical path |
|---|---|---|---|---|
| `systolic_array` | +10.970 ns | +0.090 ns | 110.74 MHz | `g_row[4].g_col[0].u_mac_cell\|o_a[0]` → `g_row[4].g_col[1].u_mac_cell\|acc_q[31]`: forwarded A operand, 8 × 8 multiply and 32-bit accumulate in the right-hand neighbour (data delay 9.014 ns) |
| `postproc` | +5.882 ns | +0.149 ns | 70.83 MHz | `s2_q[0]` → `r3_q[6]`: shift amount through the rounding constant, the 49-bit add and the variable arithmetic shift (data delay 13.925 ns) |
| `gemm_engine` (N = 8, K_TILE = 128; contains the array, post-processing, `agen_a` and 8 staging banks) | +6.722 ns | +0.095 ns | 75.31 MHz | `u_postproc\|s2_q[1]` → `u_postproc\|r3_q[7]`: the post-processing variable shifter again (data delay 13.207 ns) |
| `pool_unit` (with `agen_pool`) | +11.364 ns | +0.152 ns | 115.79 MHz | `u_agen_pool\|row_stride_q[2]` → `u_agen_pool\|o_addr[15]`: the 4-term source-address sum (data delay 8.258 ns) |
| `argmax_unit` (re-run after the register restructure, D-031) | +12.926 ns | +0.151 ns | 141.36 MHz | `best_q[6]` → `best_q[1]`: the 32-bit signed compare and update (data delay 6.997 ns) |
| `accel_top` (the whole core, with the network's WGT, PARAM and descriptor init files; re-run after the Phase 3 pre-work: counter input register, RESULT register, §9 checks) | +7.228 ns | +0.101 ns | 78.3 MHz | `u_gemm_engine\|u_postproc\|s2_q[1]` → `u_gemm_engine\|u_postproc\|r3_q[22]`: the post-processing variable shifter (data delay 12.699 ns) |

Sources: `timing_setup_worst.rpt`, `timing_hold_worst.rpt`, `probe_<module>.sta.summary` and
`fmax.rpt` in each report directory.

The engine probe (`fpga/probe_reports/gemm_engine/`) uses 6,832 logic elements, 4,606 registers,
68 embedded 9-bit multiplier elements (64 for the array, 4 for post-processing) and 12 M9K blocks:
8 for the staging banks and 4 that Quartus chose for the array's input-skew delay lines
(RAM-based shift registers, `altshift_taps`).

The `accel_top` probe (`fpga/probe_reports/accel_top/`) uses 9,345 logic elements (19 %), 5,936
registers, 68 embedded 9-bit multiplier elements and 341,184 memory bits (20 %): every §5 buffer,
the descriptor table and the staging banks are block RAM (IMG 128 Kbit, ACT0 and ACT1 64 Kbit each,
WGT 64 Kbit, PARAM 4 Kbit, descriptors 1 Kbit, staging 8 Kbit: 340,992 bits; the other 192 bits
are the array's input-skew delay lines, as in the engine probe), and Analysis & Synthesis reports
no warnings, so the init files were accepted (D-021). Its 274 ports are virtual pins.
The 17 extra registers are the counter input register (9: busy, MAC-active, 5 read and 2 write
requests) and RESULT (8).
Earlier fits of `accel_top`: +6.008 ns / 71.47 MHz with 9,332 LEs, before the counter input
register (worst path: `agen_a`'s read enable through the buffer multiplexers' request count into
the saturating `BUF_RD` add, data delay 13.970 ns); and, before the §9 LOGIT checks, +6.736 ns
(the drain's column select into the bias add) and +5.365 ns (the post-processing variable
shifter). With the counters registered, the worst path is the post-processing shifter, the
engine's own critical path. The worst path moves between logic cones from fit to fit; every fit
closed at 50 MHz with more than 5 ns of setup slack.

**Performance-counter input register (Phase 3 pre-work, approved).** `perf_counters` registers
`{busy, rd, wr, mac_active}` before the saturating adds. Every `accel_top` fit so far had a
counter or a long data path within a few nanoseconds of the worst path, and the last one's worst
path ran from `agen_a`'s read enable through the buffer multiplexers and the request popcount
into the 33-bit `BUF_RD` add. The register cuts the counters out of the units' timing: their only
cost is that the four counters lag the events by one more cycle (spec §10.2: final one cycle after
`DONE`). The layer counters are not delayed; they count sequencer events, not unit ports. A clear
also clears the input register, so the counted events are exactly those before (one cycle later).
The spec §10.2 note on the lag (final one cycle after `DONE`) was approved on 2026-11-19.

**Reading.**
- Both blocks close timing at 50 MHz with margin on every corner. The whole design will be
  checked again in Phase 4.
- `postproc`'s critical path is the variable shifter: the arithmetic right shift by `S`, a
  barrel shifter over the 49-bit rounding intermediate, together with the rounding add that
  feeds it. It is the longer of the two blocks' paths.
- If the full design gets tight, the first remedy is another split (shift, then round), which
  §3.1 already allows.
- **Post-v1.0 option:** narrow the supported `S` range. Spec §3 allows `S` in [1, 47]; a
  narrower range shrinks the barrel shifter. This is a spec change, and the offline quantizer
  would have to assert the new range.

## D-025 — Address generators: incremental counters, engine-driven commands (Phase 2)

**Decision.**
- **`agen_a` (CONV im2col and FC linear) and `agen_pool` (2×2 window scan) use only counters and
  adders.** Values that would need a multiply are built by repeated addition during a short setup:
  the row stride `W·C`, and FC's `K = H·W·C`. CONV's `K = 9·C` is `(C << 3) + C`. Yosys finds no
  `$mul` cells and Quartus uses no embedded multipliers for either module.
- **Cheap address steps.** Inside one 3×3 kernel row the `3·C` source bytes are contiguous (HWC),
  so the im2col address advances by 1 except at kernel-row wraps (`+W·C`). Output pixels advance
  by `C`, or `3·C` at the end of an output row.
- **K chunks without division.** All rows of a tile cover the same `k` range, so the generator
  saves the reduction-index state where a chunk ends and restores it for each row. A chunk can
  therefore start mid-kernel-row.
- **Only valid rows are staged.** Rows of a tile beyond the last output pixel are not emitted;
  `o_row_mask` tells the engine which staging banks are valid, and the engine feeds zeros for the
  others. FC (M = 1) stages one row instead of N.
- **Engine-driven commands.** `agen_a` takes `STAGE`, `NEXT_CHUNK`, `REWIND_K` and `NEXT_TILE`
  over a handshake, so tiling order stays in the engine.
- **Degenerate shapes.** A layer with K = 0 (C = 0) has no valid tiles. POOL with H or W below 2,
  or C = 0, produces no addresses.

**Alternatives.** Multipliers for `(oy·W + ox)·C` (uses DSP blocks the array needs and lengthens
the address path); dividing `k` into (ky, kx, ci) at each chunk start (needs dividers); emitting
padded rows as explicit zeros (N·Kc cycles wasted per padded tile, 7 of 8 rows for FC).

**Reason.** Small and fast hardware with obviously bounded logic depth. The tests compare every
address with a direct formula and with the golden model's data layout.

## D-026 — GEMM engine implementation (Phase 2)

**Decision.** `rtl/core/gemm_engine.sv` implements D-023 as one module with four clearly separated
control blocks, linked by start/done signals: A load, stream, drain, and the sequencer that runs
them one after another per (row tile, column tile, K chunk).
- **A load.** Issues `STAGE` to `agen_a`, reads the source buffer (1-cycle latency) and writes the
  byte into the staging bank of its tile row one cycle later.
- **Stream.** Reads all N banks and one WGT word per cycle; the data arrive one cycle later and
  are presented to the array as one step. Rows outside the tile (`o_row_mask` low) are forced to
  zero at the array input.
- **Drain.**
  - Prefetches the column tile's N parameter words into registers (one read per cycle).
  - Pulses `i_drain` and captures each result row into a **row register** (the array/post-processing
    boundary).
  - Feeds the valid elements to `postproc` one per cycle.
  - Counts elements in flight in `postproc`, so it finishes only when every result is written.
- **Addresses** use only adders: WGT `wgt_base + nt·K + k0 + kpos`, PARAM `param_base + nt·N + j`,
  output `dst_base + m·C_out + nt·N + j` (`m·C_out` stepped by `C_out` per row and carried to the
  next row tile).
- **Order.** The array is cleared before the first chunk of every output tile. The address
  generator's next command is issued after each stream, so its tile scan overlaps the drain.

**Alternatives.**
- Separate modules per FSM, each unit-tested: more wiring for little gain at this size, since
  the blocks share the tile state. Instead, the control blocks are covered through engine-level
  tests, internal assertions and FSM transition coverage. Every reachable transition of the
  sequencer (19) and drain (12) FSMs is hit in every test configuration. The branches that cannot
  be taken are listed with reasons in `test_gemm_engine.py`:
  - the `CLEAR`, `STAGE`, `CMD` and `NEXT` wait loops;
  - a drain stall in `ELEM`;
  - illegal encodings.

  Reset is exercised during A load, stream, drain and the post-processing flush.
- Re-reading parameters per element: 2 cycles per element instead of 1.
- Staging explicit zeros for padded rows: N·Kc wasted cycles per padded tile.

**Reason.**
- Simplest structure that keeps each control block small and sequential (correctness first).
- The row register cuts the drain path from the array's row multiplexer into post-processing.
  In the Quartus probe, the engine's critical path is inside post-processing, not at that
  boundary (D-024).

**Padded rows (spec §5 reworded, approved in the engine review).** §5 previously said rows
`m ≥ M` are written as 0 when staging. The engine does not stage them; instead it forces their
array inputs to zero. §5 now says exactly that ("padded rows are forced to zero at the array
input"), and the zero-forcing stays in the RTL.

**The zero-forcing mutant is killed by SVA (engine review).** Removing the zero-forcing
(`testbench/mutants/m15_engine_no_zero_forcing.patch`) changes no layer output:
- **Output-stationary:** a row's result depends only on that row's A-values, and padded rows are
  never written back.
- **Weight-stationary (D-015 mapping):** padded output rows likewise only feed their own
  accumulator rows.

It is still observable, and §5 stays normative, because:
- the spec requires padded rows to be zero at the array input;
- X (4-state simulation, before a bank is first written) or stale bytes in padded lanes would
  break the no-X rule and could falsely trip, or mask, the planned accumulator-overflow
  assertion;
- garbage in padded lanes toggles multipliers and accumulators for nothing, which shows up as
  dynamic power in the Phase 8 power analysis.

The implementation assertion `a_padded_rows_zero` (every array step presents 0 on padded lanes)
fires on the mutant in Verilator runs, so the mutant is recorded as **killed**, not equivalent.

## D-027 — Performance counter definitions (engine review)

**Decision** (approved in the engine review, before the CSR block is built). Spec §10.2 now
defines:
- **`BUF_RD` / `BUF_WR`:** count accesses to the §5 buffers only. Reads are of IMG, ACT0, ACT1,
  WGT and PARAM; writes are to ACT0 and ACT1. The GEMM engine's internal staging banks, the
  LOGIT register file, the descriptor table and memory-port accesses are not counted.
- **`CYC_MAC`:** counts the cycles in which the GEMM engine's `o_mac_active` is high, i.e. the
  array consumed a reduction step.
- **`LAYER_CYC[L]`:** counts from the cycle the sequencer starts layer `L` through the cycle that
  layer's unit reports done.

**Reason.**
- Each counter has one unambiguous source signal, so the CSR block can be checked against a
  simple model.
- `BUF_*` measure traffic on the large shared buffers, which is what the dataflow study (Phase 7)
  compares. The staging banks are an engine implementation detail.

## D-028 — Buffer ownership, pool unit and argmax unit (Phase 2)

**Decision.**
- **One owner per buffer.**
  - Each §5 buffer gets a `buf_port_mux` in front of its single read port and single write port.
    The layer sequencer drives a one-hot owner vector per buffer: the host memory port while
    idle, otherwise the unit executing the current layer (GEMM engine or pool unit) for the
    buffers named by its descriptor.
  - One owner covers both ports, because a layer never reads and writes the same buffer.
  - Only the owner's requests pass (AND-OR multiplexer); read data fans out to all requesters.
  - Assertions (`testbench/sva/buf_port_mux_sva.sv`): the owner vector is one-hot or zero, and no
    input that does not own the buffer issues a read or write. The mux is combinational, so the
    assertions are sampled on the clock of whatever contains it: a unit-test harness now,
    `accel_top` later.
- **Pool unit.** `agen_pool` addresses are read as soon as they are offered (the read port is
  free during POOL). Data returns one cycle later and updates a running signed maximum, which is
  restarted on each window's first read. The window's maximum is written from a register one
  cycle after its last read. Completion is detected from the empty pipeline, so shapes with no
  output also finish.
- **Argmax unit.**
  - Reads the logits through a 1-cycle-latency port, the same convention as the buffers, so
    the LOGIT register file can register its read data.
  - A later value replaces the running maximum only if it is strictly greater (`>`). Ties
    therefore go to the lowest index, as spec §3 and `np.argmax` require. A count of 0 gives
    result 0.

**Alternatives.**
- **Priority-encoded arbitration between requesters:** hides a sequencing bug instead of exposing
  it; the one-hot owner plus assertions makes an illegal overlap an immediate failure.
- **Per-port owners:** not needed while a layer never reads and writes one buffer.
- **Argmax with `>=` scanning from the top index down:** equivalent but less obvious than strict
  `>` from index 0 (and mutant `m16` shows `>=` from index 0 is wrong).

**Reason.** Simple, fully specified ownership that is easy to check in simulation, and units that
reuse the address generators and the 1-cycle read convention already verified.

**Spec additions (approved in the batch 3 review; spec §5, §8, §9, §10).**
- **Read-data return select.** The units' source data is selected by the layer's `src` field,
  registered before the layer starts; the memory port registers its buffer select with each read.
  A late or combinational select cannot mix data of two buffers.
- **Registered owner vectors.** The sequencer's owner vectors are registers. They are loaded the
  cycle before a unit is started and cleared the cycle after its done pulse, so they change only
  while every unit is idle; `a_owner_change_when_idle` (`testbench/sva/accel_top_sva.sv`) checks
  it, outside reset.
- **`src = dst` is a §9 error** for CONV and POOL (a layer never reads and writes one buffer,
  which the single-owner, single-port scheme relies on). ARGMAX ignores `dst`.
- **LOGIT as a buffer.** LOGIT is written only by FC and read only by ARGMAX, and the descriptor
  must say so:
  - `src = LOGIT` is a §9 error for CONV, POOL and FC; `dst = LOGIT` is one for CONV and POOL.
    LOGIT is not a byte buffer, so without these checks a unit would read 0 or its writes would be
    dropped, silently.
  - *(Phase 3 pre-work, approved.)* **FC with `dst ≠ LOGIT`** and **ARGMAX with `src ≠ LOGIT`**
    are §9 errors too. Before, FC ignored `dst` (it always writes LOGIT) and ARGMAX ignored `src`
    (it always reads LOGIT), so a descriptor could name a buffer the unit never touched. Now the
    `src`/`dst` fields always describe what the layer really reads and writes. This also covers
    the old FC `dst = IMG` and `src = dst` checks.
- **Image offset only for buffer-reading layers** *(Phase 3 pre-work, approved)*. The sequencer
  adds `IMG_SEL · IMG_SIZE` to `src_base` only for a CONV, POOL or FC with `src = IMG`. Before, it
  added the offset for any `src = IMG`, including ARGMAX, whose base indexes the LOGIT registers
  (BUG-011). FC is included on purpose: an FC reading the image directly must follow `IMG_SEL`
  like the other layers. The committed `desc.hex` passes every rule
  (`model/tests/test_golden.py::test_committed_descriptor_table_is_legal`, using
  `hwmap.descriptor_error`).
- **A failing layer never starts.** The descriptor errors (all but a missing `last`) are checked
  before the layer's unit is started: `STATUS` shows the layer's index and its `LAYER_CYC` stays 0.
- **`DESC` reads during a run** wait (`o_csr_ready` low) until the sequencer is not fetching,
  instead of returning 0 (§10.1).
- **A memory-port read accepted in the same cycle as START** completes normally (§10.3; see
  D-016).
- **A memory-port write accepted in the same cycle as START** is performed (§10.3; approved
  2026-11-19, tested by `test_csr_rules`).
- **Address-range policy.** Addresses are taken modulo each buffer's power-of-two depth (high bits
  ignored), as for the memory port. Accesses are never out of range; oversized descriptors wrap
  and are not detected. Checking ranges would need the layer's extent (a multiply per descriptor)
  and would add an error path that the network never needs.
- **Per-buffer address widths.** IMG needs 14 bits (16 · 784 = 12,544 bytes > 2^13), ACT 13,
  WGT 10, PARAM 6, LOGIT 4. `buf_port_mux`'s default `AW` is now 14 (the widest byte buffer);
  `accel_top` sets every instance's width explicitly.
- **`BUF_RD` / `BUF_WR` from the multiplexer outputs.** Each cycle adds the number of read
  requests leaving the five multiplexers (0–5) and write requests leaving ACT0/ACT1's (0–2), with a
  saturating add. The width is the new `PERF_W` parameter (spec 32); a 12-bit build tests
  saturation. All counters saturate (the spec's "They saturate" now names every counter).
- **Memory-port word writes.** One write is one whole word: bytes from `[7:0]`, WGT from
  `[N·DATA_W − 1:0]` (64 bits for N = 8), PARAM from all 64 bits.
- **Registered descriptor fields** (spec §8): the four words are read into registers before the
  layer starts and every unit is configured from them.

## D-029 — Mutant runner pulled forward from Phase 3 (batch 3 review)

**Decision.** `scripts/run_mutants.py` runs the bug-injection mutants:
- **Isolation.** Each patch is applied in its own temporary `git worktree` at HEAD, with the
  current working tree (modified, new and deleted files, ignored files excluded) copied over it,
  so a run checks exactly the code under review and the main working tree is never modified.
- **Kill criterion.** The killing test named in `testbench/mutants/README.md` must fail
  (pytest JUnit file), and a simulation must have run (cocotb results file present), so a build
  error or a mistyped test id is an `ERROR`, not a kill. When the README names a required
  assertion (SVA kill, `m15`), an `Assertion failed` line naming it must be in the simulator log;
  a failure for another reason is `WRONG`.
- **Baseline.** Every distinct killing test first runs on the unmutated tree and must pass.
- **Report.** Per mutant: verdict, killing test, and the first failing cocotb test with its
  message (or the assertion line). `--report` writes `testbench/reports/mutation.md`.
- **Guards.** `scripts/checkpoint.sh 2` fails if any patch is currently applied to the working
  tree (`git apply -R --check` must fail for every patch). `scripts/tests/test_mutant_patches.py`
  checks in CI that every patch applies and that its README row names a collected pytest node.

**Alternatives.** A shell loop applying patches in place (what the review bundle did by hand): a
crash or interrupt leaves a mutant in the RTL, and exit codes cannot tell a build error from a
kill.

**Reason.** Phase 3 requires the runner; having it now makes the 20+ existing mutants a
repeatable regression instead of a one-off check, and the kill criterion is strict enough that a
mutant cannot be "killed" by an unrelated failure.

## D-030 — One start/busy/done contract for all layer units (batch 3 review)

**Decision.** `testbench/sva/unit_if_sva.sv` replaces `gemm_engine_if_sva.sv` and is bound to the
GEMM engine, the pool unit and the argmax unit (one bind file each). Parameters: the
configuration width `CFG_W` and the number of other read and write enables. Properties: start only
when idle and configuration stable while busy (sequencer obligations); done is a pulse, ends busy,
only while busy; busy falls only after done (or a reset); no port access while idle;
`o_src_re |-> o_busy`, `o_dst_we |-> o_busy`. The engine-only "write port matches the mode" check
moved to `gemm_engine_impl_sva.sv`. Each unit has a fires-test for both sequencer obligations.
- `gemm_engine_impl_sva`'s drain-active input is now bound as `dstate_q != D_IDLE`, evaluated in
  the engine's scope, so the assertion file no longer copies the engine's enum encoding.
- `scripts/check_fsm_names.py` (run by `scripts/tests/`) checks that the testbench's `Q_NAMES` /
  `D_NAMES` lists equal the engine's `qstate_t` / `dstate_t` enums in order.

**Reason.** The sequencer drives all three units the same way, so one contract, checked in one
place, catches a sequencer bug against any unit, and the WS array work (Phase 7) does not touch it.

## D-031 — Control path: CSR block, memory port, layer sequencer, accel_top (Phase 2)

**Decision.**
- **Partitioning.** `csr_block` (bus decode, register map), `perf_counters`, `layer_seq`
  (descriptor walk, errors, ownership, unit starts), `mem_port` (host handshake, read return),
  `logit_rf` (LOGIT registers) and `accel_top` (buffers, port multiplexers, request decode).
- **CSR timing.** Register reads are answered in the cycle they arrive (ready = valid); the read
  multiplexer is combinational. Descriptor reads take one more cycle (synchronous RAM) and use the
  table's read port only when the sequencer is not reading it, so DESC is readable during a run
  (a few cycles of wait at most) instead of reading 0.
- **LOGIT registers, not RAM.** 16 × 32 bits: the CSR block reads any entry combinationally, the
  argmax unit through a registered port with the buffers' 1-cycle latency, and reset clears them
  (the CSR reset value is 0).
- **RESULT** *(changed in the Phase 3 pre-work, approved)* is a register in `accel_top`:
  cleared by reset and at an accepted START, loaded from the argmax unit's result on its done
  pulse. Before, it was the argmax unit's own result register, which kept the previous run's class
  through a run that stopped with an error before its ARGMAX layer. The spec only promised RESULT
  when `DONE` and not `ERROR`, so that was not a spec violation, but a stale class after an error
  is easy to misread (e.g. on the FPGA's HEX display); 8 flip-flops remove it.
- **IMG offset.** `IMG_SEL · IMG_SIZE` is computed once at START by shift-and-add over the set
  bits of the constant (784 = 512 + 256 + 16): no multiplier, no per-layer cost.
- **Sequencer schedule.** About 7 cycles per layer: 4 descriptor reads plus capture, check,
  start, done, release. The counter `LAYER_CYC[L]` covers the unit's run only.
- **Request decode.** Each multiplexer input is the unit's request ANDed with "this buffer is the
  layer's src (or dst)", so a unit only ever requests the buffers its descriptor names, and the
  ownership assertions check the decode against the owner registers.
- **Engine `K_TILE`.** The staging banks hold `max(K_TILE, 2)` bytes, which keeps the bank
  address at least 1 bit wide; `K_TILE = 1` is legal and is tested (Verilator, N = 3) instead of
  being documented as forbidden.
- **Argmax restructure.** Control and result registers (with reset) and datapath registers
  (without) are in separate `always_ff` blocks; the running maximum's next value comes from one
  `always_comb` with the start clear first and the compare second (they never coincide).

- **Quartus Analysis & Synthesis** of every new module (D-022): 0 errors. The only warnings are
  inputs that drive no logic, all ignored by the spec: `i_csr_addr[1:0]` (`csr_block`,
  `accel_top`) and `i_mem_addr[15:14]` (`accel_top`: IMG, the widest buffer, needs 14 bits). The
  GEMM engine on its own reports the reserved PARAM bits [63:54] and the base-address bits above
  the WGT and PARAM address widths. Fit and timing of `accel_top`: D-024.

**Reason.** Small blocks, each with its own unit test against a Python model, and one place
(`accel_top`) where they are connected and the whole network is checked against the golden model.


## D-032 — Full-network run and performance-counter report (Phase 3)

**Decision.** `scripts/full_run.py` builds the input vectors from the MNIST test set in the
git-ignored `data/` cache (hardware input `pixel >> 1`) and the golden logits, then runs
`test_accel_top.py::test_full_run` (`TB_MODE=full`) on Verilator with every assertion bound, in
its own build directory. The test runs the images exactly as the quick subset does (16 per IMG
load, back to back with IMG_SEL, weights from the init files) and writes one JSON line per image
(logit match, RESULT, STATUS, every counter). The script writes
`testbench/reports/full_run.{md,json}` and `testbench/reports/perf_counters.{md,json}` from those
lines, so every README number about accuracy and cycles comes from a committed report.

**Alternatives.** A pytest-parameterized full run (it would run on every `pytest testbench` and
need the MNIST cache in CI); committing the vectors (a dataset copy, which the project rules
forbid).

**Reason.** The project plan allows the full run to be a locally run regression with a committed
report (a pre-approved scope cut). A separate script keeps CI free of the dataset, while the
run uses the same test code as CI.

## D-033 — Formal proofs: ports-only wrappers, immediate assertions, PDR (Phase 3)

**Decision.**
- `testbench/formal/<module>_props.sv` instantiates the module and states its properties as
  immediate assertions with `$past`, using only its ports. The open-source Yosys front end
  rejects `|=>` and does not resolve hierarchical references (both tried; a reference became an
  undriven wire), so concurrent SVA and internal signals are out.
- Engines: k-induction (`smtbmc yices`) for the MAC cell, where every property is one-step;
  PDR (`abc pdr`) for argmax and postproc. With ports-only properties, k-induction fails on
  postproc: a stalled pipeline can hold invisible wrong state for any number of cycles. PDR finds
  the needed internal invariants itself and proves postproc in seconds.
- argmax is proved at `VAL_W = 4`, `IDX_W = 3` (8 logits). The LOGIT file is a free constant
  (`anyconst`) read through a constant-index mux (a variable part-select gave `x` bits that the
  AIG back end rejects). At `VAL_W = 6` neither engine finished (PDR stopped after 8 minutes, k-induction at depth 24
  after 15); at `VAL_W = 4` both prove it in about 70 s.
- The handshake block is `postproc`, the design's elastic valid/ready pipeline. Each input
  carries its sequence number as the tag, and `i_acc` is a function of it, so every output can be
  traced back to its input.
- `test_formal.py` runs each proof (must PASS) and re-runs it on a mutated copy of the RTL (must
  FAIL on a named property): m31 (MAC ignores clear), m16 and m17 (argmax tie and signedness),
  m24 (postproc drops `i_ready`). CI runs it.

**Alternatives.** Bounded model checking only (a proof only up to the depth); Verific-based
SymbiYosys (commercial); assertions inside the RTL under `` `ifdef FORMAL `` to reach internal
state (adds verification code to synthesizable files).

**Reason.** Unbounded proofs with the free toolchain, on the three blocks the verification plan names, with
evidence that each property set is not vacuous.

