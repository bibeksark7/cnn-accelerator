# Bug log

Format: **symptom → how found → root cause → fix → regression test added.**
Every real bug found during the project is logged here, newest at the bottom.

---

## BUG-001 — Counter RTL does not compile in any tool (Phase 0)

- **Symptom.** `iverilog -g2012` stopped with `syntax error … Missing closing quote for string`;
  Verilator and Yosys reported `syntax error, unexpected STRING` at line 2.
- **How found.** First parse of `rtl/counter.sv` with all three tools while converting the counter
  test to the pytest runner flow.
- **Root cause.** A Python-style `"""…"""` docstring had been placed inside the module body.
  SystemVerilog has no docstrings; the quotes are read as string literals, and string literals
  may not span lines.
- **Fix.** Replaced it with a `//` header comment (purpose, ports, latency, per the coding rules);
  sized the increment constant (`8'd1`) so the file is also `verilator --lint-only -Wall` clean.
- **Regression test.** `scripts/lint.sh` (Verilator `-Wall`, Icarus, Yosys on every RTL file) now
  runs in CI on every push, and `testbench/unit/test_counter.py` runs the counter on both simulators.

## Phase 1 — model and golden model

No defects in the model code. (BUG-002, below, is a Phase 1 defect in the checkpoint script.)
The golden model was checked against independent references (Python big-int
requantization, nested-loop convolution, pack/unpack round-trips) in `model/tests/test_golden.py`.

## BUG-002 — Phase checkpoint passed with all of the phase's work uncommitted (Phase 1)

- **Symptom.** `scripts/checkpoint.sh 1` reported `[PASS] latest CI run on main is green for HEAD`
  and `CHECKPOINT 1: PASS` while every Phase 1 file was still untracked or modified, so the green CI
  run was for the previous phase's commit.
- **How found.** Running the checkpoint locally before committing. A pass was unexpected, since
  the work had never been pushed.
- **Root cause.** The check only compared the latest CI run's commit with `HEAD` and `HEAD` with its
  upstream. Uncommitted work leaves `HEAD` unchanged, so all three agreed.
- **Fix.** The check now first requires `git status --porcelain` to be empty (no modified,
  staged or untracked non-ignored files). Only then does it compare `HEAD`, upstream and the CI
  run.
- **Regression test.** No automated test of the checkpoint script. Verified by running
  `scripts/checkpoint.sh 1` with the uncommitted Phase 1 tree: it now reports
  `[FAIL] … uncommitted or untracked changes` and `CHECKPOINT 1: FAIL`.

## BUG-003 — Array testbench recorded result rows one clock edge early (Phase 2)

- **Symptom.** `test_systolic_array` timed out in every test after the first, waiting for
  `o_idle` before clearing the next tile. The array was stuck in its row-emit state, holding a
  row nobody had taken.
- **How found.** Logging `o_idle` and the drain state in the failing test: `state_q = S_EMIT` at
  the start of the second tile.
- **Root cause (testbench).** The row collector checked `o_row_valid && i_row_ready` in
  `ReadOnly` *after* a rising edge and counted that as a transfer. A valid/ready transfer happens
  at a rising edge using the values from *before* it. The collector then changed
  `i_row_ready` (randomly, often to 0) at the next falling edge, so the last row was "received"
  by the test but never accepted by the array.
- **Fix.** Set `i_row_ready` after a falling edge, then sample `valid`, `ready` and `data` in
  `ReadOnly` of that same time step, which are the values the next rising edge uses. Count a
  transfer only then.
- **Regression test.** `test_systolic_array.py` now passes with random row backpressure on N =
  8 (Icarus and Verilator), 3 and 1. A wrong-skew RTL mutant still fails it. The same sampling
  rule is used for every valid/ready interface in later testbenches.

## BUG-004 — Array `o_idle` semantics untested; a real mutant was misclassified as equivalent (Phase 2)

- **Symptom.** A mutant that left the PE-grid valid bits out of the "in flight" condition passed
  every array test. I recorded it in D-017 as equivalent.
- **How found.** Phase 2 batch 1 review: `o_idle` is part of the §11.2 interface, so a mutant that
  changes it cannot be equivalent.
- **Root cause.**
  - **Test gap:** every test cleared the array only after a completed drain. That is long after
    the grid empties, so an early `o_idle` was never observable.
  - **Analysis error:** the equivalence argument considered only output rows, not every output
    of the interface.
- **Fix.**
  - `o_idle` is now built only from registered state (`i_valid` removed from the in-flight term).
  - New test `test_idle_then_clear_discards_partial_sums`: stream steps without a drain, clear as
    soon as `o_idle` rises, drain, expect zeros.
  - New SVA `a_idle_means_empty` (`o_idle` implies no valid bit in the skew lines or the grid).
- **Regression test.** With the mutant re-applied, the new test fails on Icarus (N = 8), and on
  Verilator the assertion `a_idle_means_empty` fires. D-017 is corrected.

## BUG-005 — Quartus rejected RTL that Verilator, Icarus and Yosys all accepted (Phase 2)

- **Symptom.** Quartus Prime Lite 22.1std Analysis & Synthesis failed on three files:
  - `sram_1r1w.sv`: `Error (10170): ... near text: "if"; expecting "endmodule"` (a generate-if
    with no `generate` keyword);
  - `systolic_array.sv`: `Error (10170): ... near text: "for"; expecting "endmodule"` and
    `Error (10149): ... identifier "i" is already declared` (generate-for loops with inline
    `genvar` and no `generate` keyword);
  - `postproc.sv`: `Error (10170): ... near text: "'"; expecting ","` on `-R_W'(128)` (unary minus
    applied to a size cast).
- **How found.** Quartus probe compiles: the `sram_1r1w` M9K probe (D-021), then the same check
  on every batch 1 module. Verilator `-Wall`, Icarus and Yosys had accepted all three files.
- **Root cause.** Quartus 22.1 Lite's SystemVerilog front end is stricter than the other three
  tools:
  - it needs explicit `generate … endgenerate`;
  - it treats `for (genvar i …)` as a module-scope declaration, so two loops both using `i`
    collide;
  - it cannot parse `-N'(x)`.
- **Fix.**
  - Explicit `generate … endgenerate` blocks with module-scope genvars (`genvar gi, gj;`) and
    `gi = gi + 1` steps.
  - Typed signed localparams for the saturation bounds.
- **Regression test.**
  - All three modules now pass Quartus Analysis & Synthesis with 0 errors and 0 warnings.
  - Quartus cannot run in CI (Windows-only), so `scripts/lint.sh` runs
    `scripts/check_quartus_compat.py` everywhere. It tracks generate nesting and flags named
    `g_*` blocks or module-scope `for (`/`if (` outside `generate/endgenerate`, inline genvars,
    and unary minus on a size cast. It rejects the original `systolic_array.sv`, the bare
    generate-if `sram_1r1w.sv` and the `-R_W'(128)` form; its own tests are in
    `scripts/tests/`.
  - Phase 4's full Quartus build is the final regression.

## BUG-006 — Quartus probe script made the clock a virtual pin (Phase 2)

- **Symptom.** The first fit/timing probes of `systolic_array` and `postproc` reported
  `Total pins : 0`. Quartus also warned `Ignored 6800 Virtual Pin logic option assignments`.
- **How found.** Reading the fit summary before trusting the timing numbers: a design with a
  clock must keep at least the clock pin.
- **Root cause.** `scripts/quartus_probe.sh` assigned `VIRTUAL_PIN ON -to *` and then
  `VIRTUAL_PIN OFF -to clk`. The wildcard won, so the clock was driven from logic and the timing
  was not representative.
- **Fix.** Virtual pins are assigned by the port naming convention: `-to i_*`, `-to o_*`, `-to rst`.
  The clock is never matched.
- **Regression test.** The committed probe reports show `Total pins : 1` for both modules. The
  timing numbers in D-024 are from the corrected run.

## BUG-007 — lint.sh's Yosys step did not read the file under test (Phase 2)

- **Symptom.** Linting a file outside `rtl/` would have failed in Yosys with "module not found"
  instead of reporting the file's real problems.
- **How found.** While writing `scripts/tests/test_lint.py`, which lints known-bad fixture files.
- **Root cause.** The Yosys command read only `rtl/**/*.sv` (for submodules), not the file
  being linted.
- **Fix.** Yosys reads the file under test plus every RTL file, de-duplicated.
- **Regression test.** `scripts/tests/test_lint.py` lints five fixtures and expects each to fail:
  - a bare generate-if;
  - an Icarus "sorry" construct;
  - two cells driving one net;
  - a combinational loop;
  - an undriven wire.

  It also expects the committed RTL to pass. It runs in CI.

## BUG-008 — K-chunking at K_TILE = 128 was covered only by the network test (Phase 2)

- **Symptom.** With `CI=true`, which skips the slow network-layer test on Icarus, the new FSM
  transition-coverage test failed on the Icarus N = 8, K_TILE = 128 build:
  `qstate: transitions never hit [('CMD', 'STAGE')]`.
- **How found.** The engine's FSM transition coverage (`test_fsm_transition_coverage`), which
  requires every reachable sequencer transition in every configuration.
- **Root cause (test gap).** `CMD → STAGE` (moving to the next K chunk) only happens when
  K > K_TILE. The random layers have K ≤ 45 (CONV) or a random FC that only sometimes
  exceeds 128. In the K_TILE = 128 builds, only the network's FC layer (K = 400) exercised
  K-chunking, so skipping it in push CI would have left chunking untested on Icarus.
- **Fix.** `test_random_layers` now always ends with an FC with K = 200 and a CONV with K = 144.
  Both need several K chunks for any K_TILE ≤ 128, and the CONV covers conv chunking at
  K_TILE = 128, which no test did before.
- **Regression test.** The coverage test passes on every configuration with and without
  `CI=true`.

## BUG-009 — Testbench missed a one-cycle done pulse that came immediately after start (Phase 2)

- **Symptom.** `test_argmax_unit` timed out waiting for `o_done` on both simulators.
- **How found.** First run of the new argmax test.
- **Root cause (testbench).** With `i_count = 0`, the unit is done one cycle after `i_start`. The
  test raised `i_start`, lowered it at the next falling edge and only then started waiting for
  `o_done`. By then the one-cycle pulse had already passed.
- **Fix.** The test watches `o_done` from the first rising edge after raising `i_start`, lowering
  `i_start` only if the pulse has not come. D-018 now states this rule for every done pulse.
- **Regression test.** `test_argmax_unit.py` (count 0 among the directed cases) passes on Icarus
  and Verilator. Mutants `m16` (ties to the highest index) and `m17` (unsigned compare) are caught.

## BUG-010 — Assertions fired after a one-cycle reset (Phase 2)

- **Symptom.** The first run of `test_reset_mid_run` (system test) stopped in Verilator with
  `Assertion failed in accel_top.u_accel_top_sva.a_owner_change_when_idle`; with that fixed,
  `accel_top.u_gemm_engine.u_unit_if_sva.a_busy_ends_with_done` fired at the same point.
- **How found.** System test: reset asserted for a single cycle while the GEMM engine was running.
- **Root cause (assertions).** Both properties compare a cycle with the one before (`$changed`,
  `$fell`, `$past`). `disable iff (rst)` only disables evaluation while `rst` is high. A one-cycle
  reset clears the owner registers and the engine's busy flag at the same edge that ends the reset
  cycle, so the first cycle after reset saw "owners changed while the engine was busy in the
  previous cycle" and "busy fell without a done pulse". The engine's own reset tests always held
  `rst` for two cycles, which hid the second case (it existed in the old `gemm_engine_if_sva`).
- **Fix.** Both antecedents exclude the cycle after a reset (`&& !$past(rst)`); the property
  headers say why. No RTL change.
- **Regression test.** `test_accel_top.py::test_reset_mid_run` (one-cycle reset in each of the six
  layers, then a clean bit-exact run) passes on Verilator with every assertion bound.

## BUG-011 — ARGMAX with `src = IMG` added the image offset to its LOGIT base (Phase 3 pre-work)

- **Symptom.** None observed. With `src = IMG` and `IMG_SEL = s`, an ARGMAX layer read its logits
  from `src_base + s · 784` instead of `src_base`. The error was hidden only because 784 is a
  multiple of 16: the argmax unit takes the low 8 bits of the base (784 mod 256 = 16), and the
  16-entry LOGIT file keeps only the low 4 bits of the index, so the offset vanished. A different
  `IMG_SIZE` or a 32-entry LOGIT file would have read the wrong logits for every image but 0.
- **How found.** Review of `layer_seq.sv` (Phase 2 checkpoint review).
- **Root cause (RTL and spec).** The sequencer applied the offset for any `src = IMG`, as spec §9
  then said, and ARGMAX ignored `src` (it always reads LOGIT), so §9 accepted ARGMAX
  `src = IMG`. The unit test's expected model followed the same rule and its random tables always
  gave ARGMAX `src = LOGIT`, so nothing exercised the case.
- **Fix.** `layer_seq` adds the offset only for CONV, POOL and FC (`unit_op && src == IMG`).
  Spec §9 now makes ARGMAX with `src ≠ LOGIT` an error (and FC with `dst ≠ LOGIT`), so the case
  is rejected before the layer starts (D-028).
- **Regression test.** `test_layer_seq.py::test_every_error` runs ARGMAX with `src` = IMG, ACT0
  and ACT1 for every `dst` (each must stop with `ERROR`), and every illegal FC `(src, dst)` pair;
  it fails on the old sequencer. Its expected model applies the offset only to buffer-reading ops
  and checks it for FC with `src = IMG`. `test_accel_top.py::test_errors` covers ARGMAX
  `src = IMG/ACT0/ACT1` and FC `dst = IMG/ACT0/ACT1` through the CSR bus.
