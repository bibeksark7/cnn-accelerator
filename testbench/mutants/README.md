# RTL mutants (bug injection)

Each `*.patch` is a single realistic bug, as a unified diff against the committed RTL. Patches are
never applied to the working tree. `scripts/run_mutants.py` applies each one in a temporary git
worktree (a copy of the current working tree), runs its killing test from the table below and
parses the test results:

- a mutant is **killed** when its killing test fails;
- when the table names a required assertion, the simulator log must also report that assertion
  failing (an SVA kill; the mutant changes no output, see `docs/decisions.md` D-026);
- every killing test must first pass on the unmutated design (baseline).

```sh
scripts/run_mutants.py                 # all mutants, report to stdout
scripts/run_mutants.py m15 -j 1        # one mutant
scripts/run_mutants.py --report testbench/reports/mutation.md
```

`scripts/tests/test_mutant_patches.py` checks in CI that every patch still applies to the current
RTL and has a table row whose killing test exists. `scripts/checkpoint.sh` checks that no patch is
applied to the working tree.

| Mutant | Bug | Killing test | Required assertion |
|---|---|---|---|
| `m01_agen_a_row_wrap_2c` | im2col pixel step at the end of an output row is +2C instead of +3C | `testbench/unit/test_agen_a.py::test_agen_a[icarus-8]` | — |
| `m02_agen_a_kernel_row_stride` | kernel-row jump adds C instead of the row stride W·C | `testbench/unit/test_agen_a.py::test_agen_a[icarus-8]` | — |
| `m03_agen_a_chunk_restart` | the next K chunk restarts at k = 0 instead of where the last ended | `testbench/unit/test_agen_a.py::test_agen_a[icarus-8]` | — |
| `m04_agen_a_k_8c` | CONV K computed as 8·C instead of 9·C | `testbench/unit/test_agen_a.py::test_agen_a[icarus-8]` | — |
| `m05_agen_pool_row_start` | next pool output row starts one input row (not two) further | `testbench/unit/test_agen_pool.py::test_agen_pool[icarus]` | — |
| `m06_agen_pool_window_step` | next pool window is C (not 2C) further | `testbench/unit/test_agen_pool.py::test_agen_pool[icarus]` | — |
| `m07_agen_pool_ceil` | pool output width rounds up instead of down | `testbench/unit/test_agen_pool.py::test_agen_pool[icarus]` | — |
| `m08_engine_wgt_addr_k0` | WGT address ignores the K-chunk offset | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m09_engine_wgt_col_tile` | next column tile reuses the previous tile's weights | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m10_engine_tile_out_base` | output base not advanced to the next row tile | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m11_engine_ragged_cols` | columns beyond C_out are written back | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m12_engine_row_out_stride` | output row stride +1 instead of +C_out | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m13_engine_prm_col_offset` | parameters not offset by the column tile | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m14_engine_no_clear` | accumulators never cleared between output tiles | `testbench/unit/test_gemm_engine.py::test_gemm_engine[icarus-3-16]` | — |
| `m15_engine_no_zero_forcing` | padded rows' A lanes not forced to zero (spec §5) | `testbench/unit/test_gemm_engine.py::test_gemm_engine[verilator-8-16]` | `a_padded_rows_zero` |
| `m16_argmax_tie_last` | argmax uses `>=`: ties go to the highest index | `testbench/unit/test_argmax_unit.py::test_argmax_unit[icarus]` | — |
| `m17_argmax_unsigned` | argmax compares logits unsigned | `testbench/unit/test_argmax_unit.py::test_argmax_unit[icarus]` | — |
| `m18_pool_unsigned_max` | pool compares bytes unsigned (negative values lose) | `testbench/unit/test_pool_unit.py::test_pool_unit[icarus]` | — |
| `m19_pool_window_restart` | pool maximum not restarted at a new window | `testbench/unit/test_pool_unit.py::test_pool_unit[icarus]` | — |
| `m20_mux_read_not_gated` | port mux passes a read request from a non-owner | `testbench/unit/test_buf_port_mux.py::test_buf_port_mux[icarus-3-8-13]` | — |
| `m21_postproc_round_const` | rounding constant 2^S instead of 2^(S−1) | `testbench/unit/test_postproc.py::test_postproc[icarus]` | — |
| `m22_postproc_no_saturation` | int8 saturation missing (low 8 bits kept) | `testbench/unit/test_postproc.py::test_postproc[icarus]` | — |
| `m23_postproc_no_relu` | ReLU not applied | `testbench/unit/test_postproc.py::test_postproc[icarus]` | — |
| `m24_postproc_ready_dropped` | last pipeline stage ignores `i_ready` (dropped handshake) | `testbench/unit/test_postproc.py::test_postproc[icarus]` | — |
| `m25_array_a_skew` | A operands of rows ≥ 2 enter the array with a one-cycle skew instead of i cycles | `testbench/unit/test_systolic_array.py::test_systolic_array[icarus-8]` | — |
| `m26_top_pingpong_dst_swap` | ACT0/ACT1 destination decode swapped (ping-pong error) | `testbench/system/test_accel_top.py::test_accel_top[icarus-quick-2]` | — |
| `m27_seq_fc_dst_unchecked` | FC with `dst ≠ LOGIT` not reported as a §9 error | `testbench/unit/test_layer_seq.py::test_layer_seq[icarus-8]` | — |
| `m28_csr_desc_pend_kept` | a withdrawn descriptor read stays pending (BUG-012 regression) | `testbench/unit/test_csr_block.py::test_csr_block[icarus-8-16-32]` | — |
| `m29_top_result_not_cleared` | RESULT not cleared at START | `testbench/system/test_accel_top.py::test_accel_top[verilator-main-50]` | — |
| `m30_perf_clear_keeps_inputs` | counter input register not cleared at START (clear-cycle events counted) | `testbench/unit/test_perf_counters.py::test_perf_counters[icarus-32]` | — |
| `m31_mac_clear_ignored` | MAC cell ignores `i_clear` | `testbench/unit/test_mac_cell.py::test_mac_cell[icarus]` | — |
| `m32_mem_ready_while_busy` | memory port ready while BUSY (requests accepted during a run) | `testbench/unit/test_mem_port.py::test_mem_port[icarus-64]` | — |
| `m33_argmax_last_hangs` | argmax stays in its last-compare state: `o_done` never comes (a hang, no wrong value) | `testbench/unit/test_argmax_unit.py::test_argmax_unit[icarus]` | — |
| `m34_postproc_deadlock` | output withheld while stage 3 is full and stage 4 waits for its own output: the pipeline deadlocks once both are full (a stall that never drains) | `testbench/unit/test_postproc.py::test_postproc[icarus]` | — |
