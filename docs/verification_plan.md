# Verification plan

Feature → test(s) → coverage item(s) → status. Kept current every phase.
Reference: `model/golden.py` + `model/hwmap.py` + committed `model/artifacts/` (`docs/spec.md` §3–§9).

Status values: **done** (test exists and passes in CI), **planned** (phase in brackets),
**gap** (known hole, with reason).

## 1. Golden model and artifacts (Phase 1)

| Feature | Test(s) | Coverage / evidence | Status |
|---|---|---|---|
| Golden reproduces committed quick-subset logits bit for bit | `model/tests/test_golden.py::test_quick_subset_logits_bit_exact` | 50 images, 5 per class | done |
| Whole network = naive nested-loop implementation (no shared code with golden) | `model/tests/test_reference_network.py::test_golden_matches_naive_network` | test images 0–2 (digits 7, 2, 1); logits and class | done |
| Requantize = `sat8((y·M + 2^(S−1)) >>> S)` | `test_requantize_matches_bigint_reference` (4005 random/extreme cases vs Python big ints) | full int32 `y`, full M and S ranges | done |
| Round half up, incl. negative ties; saturation both ends | `test_requantize_rounding_and_saturation` (10 directed cases) | ±0.5, ±1.5, ±2.5, ±256, −128/127 exact | done |
| int32 overflow is detected (order-independent bound) | `test_gemm_overflow_detected`, `test_gemm_bound_is_order_independent`, `test_requantize_rejects_int32_overflow` | cancelling partial sums | done |
| im2col + GEMM = direct convolution | `test_conv_matches_direct_loops`, `test_conv_layer_requant_relu_matches_reference` | non-square input, C_in > 1, full int8 range | done |
| Max pool 2×2 stride 2, floor | `test_maxpool_floor_and_values` | odd H and W, negative values | done |
| Argmax ties go to the lowest index | `test_argmax_ties_lowest_index` | ties, all-equal, int32 extremes | done |
| FC flattens in HWC order | `test_fc_uses_hwc_flatten` | one-hot activation | done |
| Weight / parameter packing round-trips; committed hex = rebuilt image | `test_memory_image_matches_params`, `test_pack_unpack_roundtrip_ragged_columns` | ragged `Ncols` (not a multiple of N), K = 1 | done |
| Descriptor encode/decode; network table ping-pongs | `test_descriptor_encode_decode_roundtrip`, `test_descriptor_table_ping_pong` | 200 random descriptors, all field extremes | done |
| Integer accuracy within 1% of float on the full test set | `test_accuracy_report_within_one_percent`; `scripts/checkpoint.sh 1` | `model/reports/quantize.json` | done |

## 2. RTL units (Phase 2; Icarus default, Verilator in CI)

| Feature | Test(s) | Coverage items | Status |
|---|---|---|---|
| MAC cell: multiply-accumulate, clear, wrap | `testbench/unit/test_mac_cell.py` (directed + 2000 random steps) | int8 extremes, idle gaps, clear, wrap past 2^31 | done |
| Systolic array (§11.2): tile result = A·B | `testbench/unit/test_systolic_array.py`: directed + random tiles vs NumPy (12 random tiles on Icarus, 60 on Verilator), handshakes only | K = 0, 1, N±1, 128; all zeros; int8 extremes; back-to-back tiles; step gaps; row backpressure; N = 8, 3, 1 | done |
| Systolic array `o_idle` (§11.2): idle only when no step is in flight | `test_systolic_array.py::test_idle_then_clear_discards_partial_sums`; SVA `a_idle_means_empty` | clear issued as soon as `o_idle` rises, K = 1, 2, N, 2N+1 | done |
| Systolic array interface assertions (reusable for the WS array) | `testbench/sva/systolic_array_if_sva.sv`, bound in every Verilator run (N = 8 and 3); `test_sva_assertions_fire` violates each producer obligation and checks that exact assertion fires first | clear vs valid, clear only when idle, drain-window quiet, row stable under backpressure | done |
| Systolic array OS implementation assertions | `testbench/sva/systolic_array_os_sva.sv` | idle means empty (skew lines and grid) | done |
| RTL lint and Quartus compatibility | `scripts/lint.sh` (Quartus-compat checker, Verilator `-Wall`, Icarus, Yosys `check -assert`); `scripts/tests/` (fixtures must fail, RTL must pass); `scripts/quartus_probe.sh` A&S per module in `checkpoint.sh 2` (local) | bare generate, inline genvar, unary minus on a cast, Icarus sorry, multi-driver, loop, undriven | done |
| GEMM engine: tiling over M, Ncols, K with zero padding | `test_gemm_engine.py`: random GEMMs vs golden | M, Ncols not multiples of N; K > `K_TILE` (multiple chunks); K = 1; maximum K | planned [2] |
| Buffers: 1-cycle synchronous read, preload | `testbench/unit/test_sram_1r1w.py` | `$readmemh` preload, read hold, concurrent read/write to different addresses | done |
| A-operand address generator: im2col (CONV), linear (FC) | `testbench/unit/test_agen_a.py`: every (bank, kpos, address) vs a direct formula under the engine's command sequence; real conv/fc layers gathered through the addresses equal `golden.im2col`; no `$mul` cells | network shapes with K_TILE = 128; random shapes, bases and chunk sizes 1–128 (chunks split kernel rows); several column tiles (rewind); edge tiles; single output row/column; C = 1; no-output shapes; backpressure; N = 8 and 3 | done |
| Pool window generator | `testbench/unit/test_agen_pool.py`: every (address, first, last, dst, end) vs a direct formula; real pool layers max-pooled through the addresses equal `golden.maxpool2`; no `$mul` cells | odd H/W (floor), random bases, C = 1–4, no-output shapes, backpressure | done |
| Post-processing (§3, §3.1), 4-stage pipeline | `testbench/unit/test_postproc.py`: directed + 2400 random vs `golden.requantize`; Yosys netlist also passes it | rounding ties ±, saturation high/low, ReLU clamp, S = 1 and 47, M min/max, int32 extremes of y, FC bypass, gaps + backpressure | done |
| Pool unit | `test_pool.py` vs `golden.maxpool2` | odd sizes (floor), negative values | planned [2] |
| Argmax unit | `test_argmax.py` | ties, all equal, int32 extremes | planned [2] |
| CSR block (§10.2) | `test_csr.py` | every register; RO/WO; START while busy ignored; writes while busy ignored | planned [2] |
| Memory port (§10.3) | `test_mem_port.py` | every `sel`, reserved `sel`, not ready while busy | planned [2] |
| Sequencer: descriptor walk, errors (§9) | `test_sequencer.py` | each op; reserved op; dst = IMG; missing `last` | planned [2] |

## 3. System (Phase 3; Verilator)

| Feature | Test(s) | Coverage items | Status |
|---|---|---|---|
| Full network, quick subset (50 images), logits bit-exact | `testbench/system/test_accel_top.py` (CI every push) | weights loaded once, images back to back | planned [3] |
| Full network, ≥ 1,000 test images | same test, full-run mode; report in `testbench/reports/` | hardware accuracy reported | planned [3] |
| Intermediate buffers match golden layer by layer | memory-port read-back after each layer (debug mode) | every layer type | planned [3] |
| Reset mid-run, then a clean run | `test_accel_top.py::test_reset_mid_run` | reset during each layer type | planned [3] |
| Saturation in real data | none: the calibrated network never saturates on MNIST (checked in Phase 1) | covered by directed post-processing tests instead | gap (by design) |

## 4. Assertions, formal, mutation (Phase 3)

| Item | Where | Status |
|---|---|---|
| Handshake stability (valid held until ready, payload stable) | SVA bind files, Verilator | planned [3] |
| No buffer address out of range; legal FSM states | SVA | planned [3] |
| No X on outputs after reset, **valid-qualified**: every `o_*valid` / `o_idle` / `o_ready` / status output is never X after reset; a data output is never X in a cycle where its qualifying valid is high (data under a low valid may be X) | SVA (Verilator is 2-state, so X checks run on Icarus with a cocotb monitor) | planned [3] |
| Formal: MAC accumulate/clear; argmax lowest-index max; one valid/ready buffer | SymbiYosys | planned [3] |
| Bug injection: 8–10 mutants, all caught | `scripts/mutation.sh`, `testbench/reports/mutation.md` | planned [3] |

## 5. Functional coverage targets (Phase 3 report)

Layer types (CONV, POOL, FC, ARGMAX); edge tiles in M and Ncols; K chunk count = 1 and > 1;
K = 1; saturation hit high/low; ReLU clamp; back-to-back inferences; reset mid-operation;
backpressure on every valid/ready interface; error paths.
