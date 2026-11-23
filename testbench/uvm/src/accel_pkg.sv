// accel_pkg: the UVM environment, sequences and tests for the accelerator's AXI4-Lite slave
// (accel_axil_slave + accel_top, spec §13.4). Built on axil_pkg's agent.
package accel_pkg;
  import uvm_pkg::*;
  import axil_pkg::*;
  `include "uvm_macros.svh"

  `include "accel_defs.svh"
  `include "accel_ref.svh"
  `include "accel_regs.svh"
  `include "accel_status_mon.svh"
  `include "accel_coverage.svh"
  `include "accel_scoreboard.svh"
  `include "accel_env.svh"
  `include "accel_seqs.svh"
  `include "accel_tests.svh"
endpackage
