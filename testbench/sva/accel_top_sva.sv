// accel_top_sva: buffer-ownership and scheduling assertions for rtl/top/accel_top.sv.
// Bound by accel_top_bind.sv (Verilator --assert runs only), together with one
// buf_port_mux_sva per buffer multiplexer.
//
//   a_owner_change_when_idle  the owner vectors change only while every unit (GEMM engine,
//                             pool, argmax) is idle, in that cycle and the one before (D-028);
//                             a reset returns them to the memory port at the same edge as it
//                             stops the units, so the cycle after a reset is excluded
//   a_one_unit_busy           at most one unit runs at a time
//   a_start_when_idle         a unit is started only while every unit is idle
//   a_mem_quiet_while_busy    the memory port issues no buffer request while BUSY
module accel_top_sva (
    input logic       clk,
    input logic       rst,
    input logic [2:0] own_img,
    input logic [2:0] own_act0,
    input logic [2:0] own_act1,
    input logic [1:0] own_wgt,
    input logic [1:0] own_prm,
    input logic       gemm_busy,
    input logic       pool_busy,
    input logic       argmax_busy,
    input logic       gemm_start,
    input logic       pool_start,
    input logic       argmax_start,
    input logic       seq_busy,
    input logic [4:0] mem_re,
    input logic [4:0] mem_we
);

  logic [12:0] owners;
  logic any_busy, any_start;
  assign owners    = {own_img, own_act0, own_act1, own_wgt, own_prm};
  assign any_busy  = gemm_busy || pool_busy || argmax_busy;
  assign any_start = gemm_start || pool_start || argmax_start;

  a_owner_change_when_idle :
  assert property (@(posedge clk) disable iff (rst)
      ($changed(owners) && !$past(rst)) |-> (!any_busy && !$past(any_busy)));

  a_one_unit_busy :
  assert property (@(posedge clk) disable iff (rst) $onehot0({gemm_busy, pool_busy, argmax_busy}));

  a_start_when_idle :
  assert property (@(posedge clk) disable iff (rst) any_start |-> !any_busy);

  a_mem_quiet_while_busy :
  assert property (@(posedge clk) disable iff (rst) seq_busy |-> ((mem_re | mem_we) == '0));

endmodule
