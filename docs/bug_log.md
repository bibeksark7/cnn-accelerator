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
  - Quartus cannot run in CI (Windows-only), so `scripts/lint.sh` gained two grep-based checks
    that run everywhere: no inline `for (genvar …)`, and named `g_*` generate blocks only inside
    explicit `generate/endgenerate`. They reject the original `systolic_array.sv` and the bare
    generate-if version of `sram_1r1w.sv`.
  - Phase 4's full Quartus build is the final regression.
