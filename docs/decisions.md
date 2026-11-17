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
- Each FSM is small enough to unit-test and to cover exhaustively.
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

Sources: `timing_setup_worst.rpt`, `timing_hold_worst.rpt`, `probe_<module>.sta.summary` and
`fmax.rpt` in each report directory.

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
