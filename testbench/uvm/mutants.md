# Mutants against the UVM bench

A subset of the RTL mutants in `testbench/mutants/` (same patches) run against the UVM tests
instead of their cocotb killing tests: every mutant of the accelerator's AXI4-Lite slave and its
front end, the memory port's busy rule, and the datapath and result bugs an end-to-end
scoreboard must see. The interconnect, RAM, GPIO and SoC address-map mutants are not here: those
blocks are not part of this bench's design under test.

```sh
scripts/run_mutants.py --table testbench/uvm/mutants.md -j 1 --report testbench/reports/uvm_mutation.md
```

Run with `-j 1`: each mutant rebuilds the UVM bench (about 4.8 GB of memory at `-j 2`).

The last column names how the kill must show in the simulator log (any one of those listed): an
assertion of the AXI4-Lite checker bound to `axil_if`, or a UVM message ID in brackets: `[SB]` a
scoreboard mismatch, `[HANG]` the env's watchdog (no transaction completed for 400,000 cycles),
`[STATUS]` the status monitor. `scripts/run_mutants.py` reports any other failure as WRONG.

`m36` shows as an R without an AR, not as a B before W: the port takes a transaction's direction
from whether both AW and W are buffered, so a transaction started with only AW buffered is decoded
as a read and answered on R.

| Mutant | Bug | Killing test | Required kill mechanism |
|---|---|---|---|
| `m35_port_resp_not_held` | AXI slave port drops B / R after one cycle instead of holding them until BREADY / RREADY | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `u_b_vr_sva.a_valid_held` or `u_r_vr_sva.a_valid_held` |
| `m36_port_write_without_w` | AXI slave port starts a write once AW is buffered, without waiting for W | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `u_order_sva.a_r_after_ar` |
| `m37_port_same_cycle_rsp_lost` | AXI slave port ignores a local response given in the request's acceptance cycle | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `[HANG]` |
| `m38_port_ar_freed_on_b` | AXI slave port frees the AR buffer on the B handshake instead of R (reads hang) | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `[HANG]` |
| `m48_axil_whi_kept` | accelerator slave: WHI not cleared after a low-half buffer write (stale high half in the next word) | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `[SB]` |
| `m49_axil_read_half_swapped` | accelerator slave: buffer-window read returns the other half of the 64-bit word | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `[SB]` |
| `m50_axil_csr_hole_aliased` | accelerator slave: CSR-window addresses above 4 KB alias the CSRs instead of DECERR | `testbench/uvm/test_uvm.py::test_uvm[accel_bus_test]` | `[SB]` |
| `m51_axil_buf_ignores_mem_ready` | accelerator slave: buffer-window access completes without waiting for the memory port's ready | `testbench/uvm/test_uvm.py::test_uvm[accel_poll_test]` | `[HANG]` |
| `m53_axil_csr_waits_for_idle` | accelerator slave: CSR accesses wait for the memory port's ready, i.e. are held until a run ends | `testbench/uvm/test_uvm.py::test_uvm[accel_poll_test]` | `[SB]` |
| `m54_axil_whi_waits_for_idle` | accelerator slave: a high-half (WHI) write waits for the memory port's ready, i.e. is held until a run ends | `testbench/uvm/test_uvm.py::test_uvm[accel_poll_test]` | `[SB]` |
| `m32_mem_ready_while_busy` | memory port ready while BUSY (requests accepted during a run) | `testbench/uvm/test_uvm.py::test_uvm[accel_poll_test]` | `[SB]` |
| `m21_postproc_round_const` | rounding constant 2^S instead of 2^(S−1) | `testbench/uvm/test_uvm.py::test_uvm[accel_infer_test]` | `[SB]` |
| `m22_postproc_no_saturation` | int8 saturation missing (low 8 bits kept) | `testbench/uvm/test_uvm.py::test_uvm[accel_infer_test]` | `[SB]` |
| `m23_postproc_no_relu` | ReLU not applied | `testbench/uvm/test_uvm.py::test_uvm[accel_infer_test]` | `[SB]` |
| `m26_top_pingpong_dst_swap` | ACT0/ACT1 destination decode swapped (ping-pong error) | `testbench/uvm/test_uvm.py::test_uvm[accel_infer_test]` | `[SB]` |
| `m27_seq_fc_dst_unchecked` | FC with `dst ≠ LOGIT` not reported as a §9 error | `testbench/uvm/test_uvm.py::test_uvm[accel_error_test]` | `[SB]` |
| `m29_top_result_not_cleared` | RESULT not cleared at START | `testbench/uvm/test_uvm.py::test_uvm[accel_error_test]` | `[SB]` |
| `m55_perf_buf_rd_not_cleared` | BUF_RD cleared only by reset, not at START (it accumulates over runs) | `testbench/uvm/test_uvm.py::test_uvm[accel_infer_test]` | `[SB]` |
