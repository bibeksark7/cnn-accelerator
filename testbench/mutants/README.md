# RTL mutants (bug injection)

Each `*.patch` is a single realistic bug, as a unified diff against the committed RTL. Patches are
never applied to committed RTL; the Phase 3 mutation runner applies each one to a temporary copy,
runs the regression and records whether it is caught. Until then, a mutant can be checked by hand:

```sh
git apply testbench/mutants/<name>.patch
pytest "<killing test>" -q      # must fail
git apply -R testbench/mutants/<name>.patch
```

`scripts/tests/test_mutant_patches.py` checks in CI that every patch still applies to the current RTL.

| Mutant | Bug | Killed by |
|---|---|---|
| `m01_agen_a_row_wrap_2c` | im2col pixel step at the end of an output row is +2C instead of +3C | `test_agen_a.py::test_agen_a[icarus-8]` |
| `m02_agen_a_kernel_row_stride` | kernel-row jump adds C instead of the row stride W·C | `test_agen_a.py::test_agen_a[icarus-8]` |
| `m03_agen_a_chunk_restart` | the next K chunk restarts at k = 0 instead of where the last ended | `test_agen_a.py::test_agen_a[icarus-8]` |
| `m04_agen_a_k_8c` | CONV K computed as 8·C instead of 9·C | `test_agen_a.py::test_agen_a[icarus-8]` |
| `m05_agen_pool_row_start` | next pool output row starts one input row (not two) further | `test_agen_pool.py::test_agen_pool[icarus]` |
| `m06_agen_pool_window_step` | next pool window is C (not 2C) further | `test_agen_pool.py::test_agen_pool[icarus]` |
| `m07_agen_pool_ceil` | pool output width rounds up instead of down | `test_agen_pool.py::test_agen_pool[icarus]` |
| `m08_engine_wgt_addr_k0` | WGT address ignores the K-chunk offset | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m09_engine_wgt_col_tile` | next column tile reuses the previous tile's weights | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m10_engine_tile_out_base` | output base not advanced to the next row tile | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m11_engine_ragged_cols` | columns beyond C_out are written back | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m12_engine_row_out_stride` | output row stride +1 instead of +C_out | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m13_engine_prm_col_offset` | parameters not offset by the column tile | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m14_engine_no_clear` | accumulators never cleared between output tiles | `test_gemm_engine.py::test_gemm_engine[icarus-3-16]` |
| `m15_engine_no_zero_forcing` | padded rows' A lanes not forced to zero (spec §5) | SVA `a_padded_rows_zero` in `test_gemm_engine.py::test_gemm_engine[verilator-8-16]` (no output changes, see docs/decisions.md D-026) |
| `m16_argmax_tie_last` | argmax uses `>=`: ties go to the highest index | `test_argmax_unit.py::test_argmax_unit[icarus]` |
| `m17_argmax_unsigned` | argmax compares logits unsigned | `test_argmax_unit.py::test_argmax_unit[icarus]` |
| `m18_pool_unsigned_max` | pool compares bytes unsigned (negative values lose) | `test_pool_unit.py::test_pool_unit[icarus]` |
| `m19_pool_window_restart` | pool maximum not restarted at a new window | `test_pool_unit.py::test_pool_unit[icarus]` |
| `m20_mux_read_not_gated` | port mux passes a read request from a non-owner | `test_buf_port_mux.py::test_buf_port_mux[icarus-3-8-13]` |
