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
