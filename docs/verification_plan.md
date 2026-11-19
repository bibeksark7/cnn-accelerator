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
| Descriptor §9 rules; committed `desc.hex` is legal | `test_descriptor_error_rules` (`hwmap.descriptor_error` vs the legal (src, dst) pairs of every op), `test_committed_descriptor_table_is_legal` | all 8 ops × 16 (src, dst) pairs | done |
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
| GEMM engine: whole CONV/FC layers, tiling over M, Ncols and K | `testbench/unit/test_gemm_engine.py`: conv1, conv2 and fc with the exported memory images equal the golden layer outputs; 16 random back-to-back CONV/FC layers vs `golden.conv_layer` / `golden.fc_layer`; every output written exactly once, nothing else written; 8 RTL mutants, all caught (the zero-forcing one by SVA, D-026) | M and C_out not multiples of N; K > `K_TILE` (FC, and every layer with K_TILE = 16); several column tiles; ReLU on/off; full int8 activations; random bases; N = 8 (Icarus, Verilator) and 3 | done |
| Layer-unit contract (engine, pool, argmax) | `testbench/sva/unit_if_sva.sv`, bound to all three units in every Verilator run (D-030); `test_engine_sva_fires`, `test_pool_sva_fires`, `test_argmax_sva_fires` | start only when idle, config stable while busy, done a pulse that ends busy and only while busy, busy falls only after done (or reset), no access while idle, `o_src_re` / `o_dst_we` only while busy | done |
| GEMM engine implementation assertions | `testbench/sva/gemm_engine_impl_sva.sv` (Verilator runs) | padded rows zero at the array input (kills `m15_engine_no_zero_forcing`); write port matches the mode; each control block starts only when idle; stream only on `load_done`; drain only after the last chunk; at most one block active | done |
| GEMM engine FSM transition coverage, reset and no-work layers | `test_gemm_engine.py::test_fsm_transition_coverage` (all 19 sequencer and 12 drain transitions in every configuration; unreachable branches listed; skipped under a test filter) and the pytest wrapper's check of `fsm_coverage.json`; `test_reset_mid_layer_then_clean_layer`, `test_random_cycle_resets`, `test_layers_without_work`; `scripts/check_fsm_names.py` keeps the state-name lists equal to the RTL enums | reset during A load, stream, drain PRM, ROW and ELEM, post-processing flush; 20 resets at random cycles of a layer; C_out = 0, no output pixels, K = 0; K_TILE = 1, 16, 128 | done |
| Mutation testing | 34 mutants in `testbench/mutants/` (README: each mutant's killing test and, for SVA kills, the required assertion); `scripts/run_mutants.py` (temporary worktree per mutant, baseline run, JUnit + cocotb results parsed, D-029); `scripts/tests/test_mutant_patches.py`; `checkpoint.sh 2` checks no patch is applied | every mutant killed by its named test (34 / 34, `testbench/reports/mutation.md`); m15 killed by `a_padded_rows_zero` | done |
| Buffers: 1-cycle synchronous read, preload | `testbench/unit/test_sram_1r1w.py` | `$readmemh` preload, read hold, concurrent read/write to different addresses | done |
| A-operand address generator: im2col (CONV), linear (FC) | `testbench/unit/test_agen_a.py`: every (bank, kpos, address) vs a direct formula under the engine's command sequence; real conv/fc layers gathered through the addresses equal `golden.im2col`; no `$mul` cells | network shapes with K_TILE = 128; random shapes, bases and chunk sizes 1–128 (chunks split kernel rows); several column tiles (rewind); edge tiles; single output row/column; C = 1; no-output shapes; backpressure; N = 8 and 3 | done |
| Pool window generator | `testbench/unit/test_agen_pool.py`: every (address, first, last, dst, end) vs a direct formula; real pool layers max-pooled through the addresses equal `golden.maxpool2`; no `$mul` cells | odd H/W (floor), random bases, C = 1–4, no-output shapes, backpressure | done |
| Post-processing (§3, §3.1), 4-stage pipeline | `testbench/unit/test_postproc.py`: directed + 2400 random vs `golden.requantize`; Yosys netlist also passes it | rounding ties ±, saturation high/low, ReLU clamp, S = 1 and 47, M min/max, int32 extremes of y, FC bypass, gaps + backpressure | done |
| Pool unit | `testbench/unit/test_pool_unit.py`: pool1/pool2 on golden activations equal `golden.maxpool2`; 30 random shapes vs `golden.maxpool2`; every output written once | odd sizes (floor), full int8 range incl. all-negative tensors, no-output shapes, random bases; mutants m18, m19; an X on a strobe, address or write data fails with the signal's name (`common.sim.resolved`) | done |
| Argmax unit | `testbench/unit/test_argmax_unit.py` vs `np.argmax` | planted ties, all equal, int32 extremes, all negative, counts 0, 1 and 1–16, offset bases; mutants m16, m17; an X on the read port, done, result or maximum fails with the signal's name | done |
| CSR block (§10.1, §10.2) | `testbench/unit/test_csr_block.py` (Python descriptor-RAM model, random read grant) | every register and its decode; bits [1:0] ignored; unmapped and out-of-range addresses read 0 and ignore writes; START pulses; IMG_SEL and DESC writes ignored while busy; register reads without wait states; DESC reads only through a granted RAM read; a withdrawn DESC read leaves nothing pending (BUG-012); DESC_DEPTH 8 and 4, PERF_W 32 and 20 | done |
| Performance counters (§10.2, D-024, D-027, D-028) | `testbench/unit/test_perf_counters.py` (cycle-by-cycle vs a Python model with the input register); `test_accel_top.py` `PortCounter` checks CYC_TOTAL, CYC_MAC, BUF_RD and BUF_WR every cycle of a run against the unit ports, two cycles later | clear (also drops the clear cycle's events), busy gating, 0–5 reads and 0–2 writes per cycle, the one-cycle input lag, layer counts inclusive of start and done cycles, saturation of every counter (PERF_W = 8) | done |
| LOGIT register file | `testbench/unit/test_logit_rf.py` | registered and combinational reads, read-before-write, hold, reset clears every entry | done |
| Buffer port ownership (D-028) | `testbench/unit/test_buf_port_mux.py`: only the owner's requests reach the RAM (non-owner requests ignored in Icarus runs); `buf_port_mux_sva.sv` bound in Verilator runs; `test_mux_sva_fires` | no owner, every owner, 2–4 owners, 8- and 64-bit data; one-hot violations; non-owner reads and writes; mutant m20 | done |
| Memory port (§10.3) | `testbench/unit/test_mem_port.py` (cycle by cycle vs a model, read data changing every cycle) | every `sel` incl. reserved 5–7; strobes; not ready while busy or with a read pending; exactly one `o_mem_rvalid` per read with the data of the buffer read; WGT width 64 and 24 | done |
| Layer sequencer (§8, §9, D-028) | `testbench/unit/test_layer_seq.py` (descriptor-RAM and unit models; expected behaviour written from §9) | the network table for all 16 IMG_SEL values (IMG_SEL · 784 by shift-add); 40 random valid tables; every §9 error (reserved ops 4–7; every illegal (src, dst) pair for CONV/POOL, FC and ARGMAX, incl. FC dst ≠ LOGIT and ARGMAX src = IMG/ACT0/ACT1; missing `last`) then a clean run; ARGMAX src = LOGIT with any dst is not an error; FC from IMG gets the image offset, ARGMAX never does (BUG-011); START ignored while busy and while a memory-port read is pending; reset mid-run; registered fields and owners stable while a unit runs, owners change only when every unit is idle | done |

## 3. System (Phase 3; Verilator)

| Feature | Test(s) | Coverage items | Status |
|---|---|---|---|
| Full network, quick subset (50 images), logits bit-exact | `testbench/system/test_accel_top.py::test_network_quick_subset` through `accel_top` (Verilator with every assertion bound; Icarus, 2 images; CI every push) | weights from init files, images through the memory port 16 at a time, run back to back with IMG_SEL; every LOGIT and RESULT; BUF_WR = activation outputs; CYC_TOTAL = sum(LAYER_CYC) + 7 per layer + 1 (the sequencer's schedule, also checked for error runs); counters equal an independent count of unit port activity every cycle; final ACT0/ACT1 contents = golden conv2/pool2 | done |
| Memory port, CSR rules and §9 errors at the top level | `test_accel_top.py::test_memory_port`, `test_csr_rules`, `test_errors` | every buffer read back (high address bits ignored), reserved sel, no access accepted while busy; ID/CONFIG/DESC window; writes and STARTs ignored while busy; START ignored with a read pending; a read accepted in the START cycle returns once while busy (D-016); a write accepted in the START cycle is performed; reserved op, dst = IMG, src = dst, src = LOGIT for CONV/POOL/FC, dst = LOGIT for CONV/POOL, FC dst = IMG/ACT0/ACT1, ARGMAX src = IMG/ACT0/ACT1, missing last, then a clean run; RESULT is 0 after every error run although an ARGMAX-only run set it to a nonzero class just before (cleared at START) | done |
| Counter saturation at the top level | `test_accel_top.py` with PERF_W = 12 | CYC_TOTAL, BUF_RD, BUF_WR and conv LAYER_CYC saturate; results unchanged | done |
| Full network, ≥ 1,000 test images | `scripts/full_run.py` → `test_accel_top.py::test_full_run` (TB_MODE = full, Verilator, every assertion bound; local only, D-032); reports `testbench/reports/full_run.{md,json}`, `perf_counters.{md,json}` | the whole MNIST test set: every logit vs golden, RESULT vs label (hardware accuracy), STATUS, every counter per image | done |
| Intermediate buffers match golden layer by layer | `test_accel_top.py::test_layer_by_layer`: runs of the first k layers (k = 1 .. 5) | conv1, pool1, conv2, pool2 outputs read back through the memory port; FC LOGITs | done |
| Reset mid-run, then a clean run | `test_accel_top.py::test_reset_mid_run` | one-cycle reset during each of the six layers; CSRs reset; weights, images and descriptors kept | done |
| No X on outputs after reset | `test_accel_top.py` `x_monitor` (Icarus, 4-state; every cycle of the quick run) | every control and status output never X/Z after reset; `o_csr_rdata` not X with an accepted request, `o_mem_rdata` not X with `o_mem_rvalid` | done |
| Saturation in real data | `model/saturation.py` → `model/reports/saturation.json` (all 10,000 test images): conv1 never saturates; conv2 saturates low 4 times (images 3081, 5555, 8619, 9427), never high; those images are bit-exact in the full run. Coverage point `network data: post-processing saturation` (quick subset: not reached, documented gap) | done (measured); quick-subset bin a documented gap |

## 4. Assertions, formal, mutation (Phase 3)

| Item | Where | Status |
|---|---|---|
| Handshake stability (valid held until ready, payload stable) | host interfaces: `testbench/sva/accel_top_if_sva.sv` bound at `accel_top` (CSR and memory-port requests stable until accepted; `o_mem_rvalid` a one-cycle pulse, only for an outstanding read, one read at a time; not ready while busy); `test_accel_top_sva_fires` violates both master rules. Internal links: generic `valid_ready_sva` bound to `agen_a`, `agen_pool`, the array → row-register link and both sides of `postproc` (`*_vr_bind.sv`), in every Verilator unit run of those blocks and the system test; each unit test ends with a stall cover (the link must have transferred and stalled). In the engine, `a_pp_out_never_stalled` / `a_pp_in_never_stalled` assert the two postproc stalls that cannot occur. Layer units: `unit_if_sva`. Post-processing pipeline: also the formal proof below | done |
| Legal FSM states | `testbench/sva/fsm_legal_sva.sv` bound (`fsm_legal_bind.sv`) to every FSM with unused encodings: layer sequencer, engine sequencer and drain, `agen_a`, `agen_pool`, pool unit (Verilator system runs); `sva_violation_fsm_illegal` deposits an unused encoding and `test_accel_top_sva_fires` requires `a_state_legal`; `scripts/tests/test_fsm_legal_bind.py` checks every bind's W and N_STATES against the RTL enum | done |
| No buffer address out of range | by construction: every buffer address is taken modulo its power-of-two depth (spec §5, D-028), so no out-of-range access exists to assert. That a wrap never happens for the shipped network is checked on the descriptors: `model/tests/test_golden.py::test_descriptor_address_extents` (source with the farthest IMG_SEL, destination, weights, parameters, LOGIT entries) | done |
| No X on outputs after reset (valid-qualified) | Icarus cocotb monitor in `test_accel_top.py` (Verilator is 2-state): the quick network run, and the `xcheck` configuration running `test_errors` and `test_reset_mid_run` | done |
| Formal proofs | `testbench/formal/` (SymbiYosys, D-033), run by `test_formal.py` in CI. Unbounded: MAC cell (accumulate exactly a·b, clear, hold, forwarding; k-induction, 32-bit accumulator); argmax (first maximum of the window, lowest-index ties, reads inside the window, done exactly count + 2 cycles after start; PDR, VAL_W = 4, IDX_W = 3); postproc elastic pipeline (in order, no loss or duplication, ≤ 4 inside, ready when there is room, output stable under backpressure, 4-cycle latency and full drain while `i_ready` is high; PDR). Bounded: argmax at full width (VAL_W = 32, IDX_W = 8, symbolic indices; BMC depth 40, windows ≤ 10 logits). Every proof has a cover task that must reach its covers. Each mutant run keeps only the named property, which must fail: m31, m16, m17, m24, m33, m34 (and m16, m17, m33 on the full-width check) | done; full-width argmax bounded only |
| Bug injection: all mutants caught | 34 mutants in `testbench/mutants/` (unit-level and system-level: rounding constant, saturation, ReLU, dropped ready, array skew, ping-pong decode, descriptor checks, CSR pending read, RESULT clear, counter clear, MAC clear, memory port ready while busy, argmax hang, postproc deadlock); `scripts/run_mutants.py --report testbench/reports/mutation.md` (D-029) | done: 34 / 34 killed, none equivalent |
| Buffer ownership at the top level | `testbench/sva/accel_top_sva.sv` + one `buf_port_mux_sva` per multiplexer (`accel_top_bind.sv`): owners change only while every unit is idle; one unit busy at a time; start only when idle; memory port quiet while busy; only the owner requests each buffer; registered src/dst stable while a unit runs (`a_src_dst_stable_while_busy`) | done |

## 5. Functional coverage (Phase 3 report)

`scripts/coverage_report.py --run` (D-034) runs the unit and system tests, merges their
`coverage.json` files and checks every bin of `GOALS`; the result is
`testbench/reports/coverage.md`. Targets and where they are sampled:

| Target | Coverage points (scope) | Status |
|---|---|---|
| Layer types | `layers started` CONV/POOL/FC/ARGMAX (`accel_top`); `unit started` (`layer_seq`); `layer type` (`gemm_engine`) | met |
| Edge tiles in M and Ncols | `row tiles (M)`, `column tiles (Ncols)`, `column tile count` (`gemm_engine`) | met |
| K chunk count 1 and > 1; K = 1; K ranges | `K chunks`, `K` (`gemm_engine`); `K` 0, 1, 2..N−1, N, N+1..127, 128 (`systolic_array`) | met |
| Saturation high/low; ReLU clamp; rounding ties | `saturation`, `ReLU`, `rounding` (`postproc`); real-data saturation (`accel_top`) | met in `postproc`; real data: documented gap |
| Back-to-back inferences | `inferences` (`accel_top`) | met |
| Reset mid-operation | `reset during a layer` 0..5 (`accel_top`); `reset mid-run` (`layer_seq`); engine resets: FSM transition coverage (`test_gemm_engine.py`) | met |
| Backpressure on every valid/ready interface | handshake monitors: `postproc` input and output, array `result rows`, engine-internal links (Verilator); bus wait states: `CSR bus`, `memory port` (`accel_top`, `csr_block`) | met, except the two engine-internal postproc stalls, which cannot occur (documented gaps) |
| Error paths | `descriptor errors`, every §9 kind (`layer_seq`, `accel_top`); `START` ignored while busy / with a read pending | met |

## 6. FPGA demo (Phase 4)

| Feature | Test(s) | Coverage items | Status |
|---|---|---|---|
| Board I/O blocks | `test_sync_2ff`, `test_reset_gen` (power-up from 0, POR length, button assert/release latency), `test_debounce` (bounces shorter than the stable time never change the level; one press pulse per press, cycle by cycle vs a model), `test_hex7seg` (every code vs a segment table) | Icarus and Verilator | done |
| CSR and memory-port register stages | `test_csr_slice`, `test_mem_slice`: random requests and wait states; each request reaches accel_top's side once, in order, held until accepted; every read returns its data once, in order | Icarus and Verilator | done |
| Demo controller | `test_demo_ctrl`: random presses, busy and host traffic vs the intended behaviour (IMG_SEL then START on an accepted press; other presses ignored; host requests pass unchanged only while idle) | Icarus and Verilator; `fsm_legal_sva` bound | done |
| Bring-up through the host side | `testbench/system/test_fpga_core.py::test_bring_up`: ID, CONFIG, DESC/WGT/PARAM read back equal to the hex files, image 0 in IMG | Verilator, every accel_top assertion bound (the stages are its bus masters) | done |
| Demo runs | `test_fpga_core.py::test_demo_runs`: all 16 images via the controller: RESULT = golden class, label, every LOGIT, CYC_TOTAL = the counter report; a press while busy ignored | Verilator with SVA | done |
| Board top | `testbench/system/test_de10lite_top.py`: power-up, bouncing KEY[0] presses, HEX0/HEX1/HEX5..2 and LEDR decoded for 4 images, '-' while busy, press while busy ignored, KEY[1] reset | Verilator | done |
| Timing closure and constraints | `fpga/de10lite/build_win.sh`: full compile, setup/hold slack at 50 MHz, `unconstrained_paths.rpt` all zero | reports in `fpga/de10lite/reports/` | done (checkpoint 4 checks) |
| On the board | the human programs the DE10-Lite and confirms the demo | — | pending (human) |

