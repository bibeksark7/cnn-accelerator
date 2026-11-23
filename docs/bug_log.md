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
- **How found.** Code review: `o_idle` is part of the §11.2 interface, so a mutant that
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
  on every module written so far. Verilator `-Wall`, Icarus and Yosys had accepted all three files.
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
  - The full DE10-Lite build (`fpga/de10lite/build_win.sh`) is the final regression: every
    warning it reports must be listed in `fpga/de10lite/expected_warnings.txt` (checkpoint 4).

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

## BUG-011 — ARGMAX with `src = IMG` added the image offset to its LOGIT base (Phase 3)

- **Symptom.** None observed. With `src = IMG` and `IMG_SEL = s`, an ARGMAX layer read its logits
  from `src_base + s · 784` instead of `src_base`. The error was hidden only because 784 is a
  multiple of 16: the argmax unit takes the low 8 bits of the base (784 mod 256 = 16), and the
  16-entry LOGIT file keeps only the low 4 bits of the index, so the offset vanished. A different
  `IMG_SIZE` or a 32-entry LOGIT file would have read the wrong logits for every image but 0.
- **How found.** Code review of `layer_seq.sv`.
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

## BUG-012 — A withdrawn descriptor read left the CSR block's pending flag set (Phase 3)

- **Symptom.** If a master raised `i_csr_valid` for a `DESC` read and dropped it before
  `o_csr_ready` (after the RAM read was issued), the next `DESC` read was answered in its first
  cycle with the *previous* read's word.
- **How found.** Code review of the §10.1 handshake rule; then
  reproduced by `test_withdrawn_descriptor_read`, which fails on the old RTL.
- **Root cause (RTL).** `desc_pend_q` was cleared only when a request was accepted. Withdrawing a
  request violates §10.1, but the slave silently answered a different request with stale data
  instead of starting over.
- **Fix.** `csr_block` also clears `desc_pend_q` in any cycle without `i_csr_valid`. The
  master-side rule itself is now checked by `a_csr_req_stable` (`testbench/sva/accel_top_if_sva.sv`).
- **Regression test.** `test_csr_block.py::test_withdrawn_descriptor_read` (withdrawal followed by
  a read of another word after 0, 1 and 3 idle cycles; each must wait for its own RAM read and
  return its own word), on Icarus and Verilator.

## BUG-013 — The mutant-patch check could not see system-test killing tests (Phase 3)

- **Symptom.** `scripts/tests/test_mutant_patches.py::test_killing_test_exists` failed for the
  two new mutants whose killing test is `testbench/system/test_accel_top.py` (m26, m29):
  "is not a collected pytest node", although both tests exist and kill their mutants.
- **How found.** Running the script tests after adding the system-level mutants.
- **Root cause (verification infrastructure).** The check collected only `testbench/unit`, so
  every mutant had to be killed by a unit test. That was true for the first 20 mutants, which hid
  the limitation.
- **Fix.** The check collects `testbench/unit` and `testbench/system`.
- **Regression test.** `test_mutant_patches.py` passes for all 32 mutants, and
  `scripts/run_mutants.py` kills m26 and m29 with their system tests.

## BUG-014 — No system test could see a design without saturation (Phase 4)

- **Symptom.** With mutant m22 (int8 saturation removed from postproc) applied, every CI system
  test passed; only the postproc unit test failed.
- **How found.** The CI failure proof on a throwaway branch (run 44622993548): the system-test
  step stayed green with m22 applied.
- **Root cause (test gap).** No image in the 50-image quick subset saturates any layer, so the
  network never exercised the saturating path in CI. Over the whole MNIST test set, conv2
  saturates low 4 times (images 3081, 5555, 8619, 9427; model/reports/saturation.json).
- **Fix.** `model/export.py` also writes `saturation_subset.npz` (those 4 images and their golden
  logits), and `test_accel_top.py::test_saturating_images` runs them in the main Verilator system
  test: every logit bit-exact, and the postproc must be seen saturating low during each run.
- **Regression test.** With m22 applied, `test_saturating_images` fails at image 3081 with wrong
  logits while the quick subset still passes; the coverage bin for real-data low saturation is
  now met instead of a documented gap.


## Phase 5 — RISC-V SoC

The AXI4-Lite blocks, the accelerator slave and the SoC passed their tests without an RTL logic
defect being found. Tool-compatibility fixes made while writing them (an enum ternary that Icarus
needs cast, constant part-selects inside `always_comb` that Icarus does not support, `return` in
a function that Yosys rejects, names that clash with Verilator's built-in `mailbox` class) were
caught by `scripts/lint.sh` before any commit and are not listed.

## BUG-015 — The SoC RAM was not inferred as block RAM (Phase 5)

- **Symptom.** The first Quartus compile of the SoC stayed in Analysis & Synthesis many times
  longer than the whole Milestone 1 synthesis, with `quartus_map`'s memory growing steadily. A
  synthesis-only probe of the RAM module alone did not finish either; both were stopped.
- **How found.** The trial SoC build in `fpga/de10lite_soc/`, then a Quartus probe of the RAM
  primitive on its own (`scripts/quartus_probe.sh`).
- **Root cause.** The first RAM (`sram_be`) held packed byte lanes (`logic [3:0][7:0] mem[]`) and
  wrote them in a `for` loop under per-byte enables, with a read enable. Quartus Prime Lite 22.1
  did not recognise that as a byte-enabled block RAM and started building 64 KB (524,288 bits)
  out of registers. Verilator, Icarus and Yosys simulate and parse it correctly, so lint and every
  simulation passed.
- **Fix.** `axil_ram` now uses a 32-bit `sram_1r1w`, the template every accelerator buffer
  already maps to M9K, and performs a write with only some strobes set as a read-modify-write
  (read the word, merge the strobed bytes, write one cycle later). A probe then maps the 64 KB RAM
  to block RAM, and the SoC build completes (`fpga/de10lite_soc/reports/`). D-042 records the
  change.
- **Regression test.** `test_axil_ram.py` (every WSTRB value, against a model) covers the
  read-modify-write; checkpoint 5 requires the SoC build to complete and close timing.

## BUG-016 — `make APP=quick` succeeded without building the firmware (Phase 5)

- **Symptom.** `make APP=quick` printed `'…/images.c' is up to date.` and exited 0; no ELF or
  RAM image was produced.
- **How found.** The first build of the quick-subset app by hand.
- **Root cause.** The Makefile includes the app's `app.mk` before its own `all:` rule, and GNU make
  takes the first rule it reads as the default goal: the app's generator rule for `images.c`.
- **Fix.** `.DEFAULT_GOAL := all` in `firmware/Makefile`.
- **Regression test.** `testbench/common/firmware.py::build` now fails unless the ELF, the RAM
  image and `toolchain.txt` exist after `make`, so every SoC test would catch a build that does
  nothing.

## BUG-017 — A test compared against stale data and corrupted the next test's weights (Phase 5)

- **Symptom.** In `test_accel_axil.py`, `test_buffer_window` failed with "a high-half write
  touched a buffer", and the next test in the same simulation, `test_poll_during_run`, then
  failed with every logit wrong.
- **How found.** The first run of the accelerator-slave system test.
- **Root cause.** Test bug, twice over. The check compared WGT word 7 with its init-file value,
  but the random writes just before it could have written word 7. Because the failure came before
  the test restored WGT and PARAM, the network weights stayed overwritten for the following test,
  which runs in the same simulation.
- **Fix.** The test keeps a model of every word it writes and compares with the model; it checks
  the untouched word at an index it has modelled.
- **Regression test.** The corrected test itself. Lesson recorded for later tests: a test that
  changes shared buffers checks against a model of its own writes, never against the init files.

## BUG-018 — A firmware rebuild with another image count kept the old images (Phase 5)

- **Symptom.** `scripts/soc_speedup.py --images 4` timed out: the bench firmware reported done
  after 1 image (`MAILBOX` = `0x600D_0001`) while the test waited for 4.
- **How found.** The first four-image speedup run, after one-image bench runs in the same build
  directory.
- **Root cause.** `images.c` depended only on the generator and the subset file, not on
  `BENCH_IMAGES`, so make considered the one-image `images.c` up to date. The test then waited for
  a done code that could never come instead of failing at once.
- **Fix.** `firmware/apps/bench/app.mk` writes `BENCH_IMAGES` to a stamp file that changes only
  when the count does, and `images.c` depends on it. The bench test now accepts any done code and
  then fails with "the firmware ran N images, the test expects …" if the count differs.
- **Regression test.** The bench test's image-count check; checked by hand: a rebuild with 4 then 1
  images regenerates `images.c` each time, and a rebuild with the same count does not.

## BUG-019 — An AXI4-Lite cover point could never fire at the interconnect (Phase 5)

- **Symptom.** With the slave-port and interconnect tests changed to fail unless every AW/W order
  cover is hit, `test_axil_interconnect[verilator]` failed: `c_w_before_aw` had 0 hits over 300
  writes, although the random master sends W before AW on about a third of them.
- **How found.** The new requirement itself (`test_zz_aw_w_order_cover`), on its first run.
- **Root cause.** Verification bug. `axil_resp_order_sva` documented its covers as "each arrival
  order of AW and W" but defined them on acceptance (`wvalid && wready && ...`). The interconnect
  holds W until its AW has been routed (spec §13.3), so at its CPU-side port a W is never accepted
  first: the cover was unreachable there, and before the requirement nothing noticed that it never
  fired.
- **Fix.** The covers are defined on arrival: a transfer arrives in the first cycle its VALID is
  high, and the k-th AW pairs with the k-th W (D-049). The monitor counts each order; both tests
  require every count to be non-zero.
- **Regression test.** `test_zz_aw_w_order_cover` in `test_axil_slave_port.py` and
  `test_axil_interconnect.py`. Lesson: a cover point is evidence only once a test fails when it is
  not hit.

## BUG-020 — A UVM test that passed while checking almost nothing (Phase 6)

- **Symptom.** `accel_poll_test` (register traffic throughout a run, spec §13.4) failed its own
  minimum: 175 checked reads over 4 runs, against 2,000 required. Every check that ran passed.
- **How found.** The test's minimum (`min_checked_reads`), which every UVM test has so that a
  test that exercises nothing cannot print TEST PASSED.
- **Root cause.** Verification bug, two of them. The poll sequence started 20 cycles after the
  run sequence and stopped after seeing DONE three times, but DONE was still set from the
  previous run, so it stopped before the new run's START. When it did run, its random mix
  included buffer-window accesses, which the slave correctly holds until the run ends; the slave
  serves one transaction at a time, so the first of them held every later poll too.
- **Fix.** The poll sequence waits until STATUS shows BUSY, makes `n_free` accesses the slave must
  answer during a run (registers, WHI) and only then a few held buffer accesses.
- **Regression test.** `accel_poll_test`'s minimums (2,000 checked reads, 4 runs, 3 golden runs).

## BUG-021 — Register-model predictions silently rejected (Phase 6)

- **Symptom.** `accel_reg_test` passed with 2,112 `UVM_WARNING`s: "Trying to predict value of
  register 'regs.IMG_SEL' while it is being accessed".
- **How found.** Reading the log of the first passing run; the pass criterion then ignored
  warnings.
- **Root cause.** Verification bug. The scoreboard predicts the register model's mirror (only it
  knows whether a write was performed while busy), with `predict()`'s default
  `UVM_PREDICT_DIRECT`. UVM refuses a direct prediction while a register operation on that
  register is in flight, which is exactly when the scoreboard sees the write, and returns without
  updating the mirror: the warning was the only sign.
- **Fix.** The scoreboard predicts with `UVM_PREDICT_WRITE` (allowed during an access; applies the
  field's access policy), and a UVM test now fails on any UVM_WARNING.
- **Regression test.** Every UVM test (`check_passed` in `testbench/uvm/test_uvm.py`: no
  UVM_ERROR, UVM_FATAL or UVM_WARNING).

## BUG-022 — A poll gap that stalled every other sequence (Phase 6)

- **Symptom.** The merged UVM coverage missed one bin: no low-half buffer write ever arrived while
  the accelerator was busy, although the poll test issues one in every other run.
- **How found.** `scripts/uvm_coverage.py`'s goal (every bin met or a documented gap).
- **Root cause.** Verification bug. The run sequence spaced its STATUS polls by giving each read a
  random AR delay of up to 255 cycles. The driver issues reads in order, so the poll sequence's
  accesses queued behind every gap (about 50 cycles each), the run ended before the poll
  sequence reached its held accesses, and they all arrived while idle.
- **Fix.** Poll gaps are waits in the sequence itself (`accel_base_seq::wait_cycles`), which do
  not hold the driver; the poll test also rotates which held access goes first, since only the
  first reaches the slave while busy (the rest wait behind it).
- **Regression test.** The coverage goal in `test_uvm_coverage` (bin
  `cg_access_busy.x_access_busy.<A_BUF_LOW_WRITE, busy>`).
