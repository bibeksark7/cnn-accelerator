// buf_port_mux_sva: ownership assertions for one buffer's port multiplexer (rtl/mem/buf_port_mux.sv).
//
// The multiplexer is combinational, so these are checked on the clock of whatever instantiates it
// (the unit-test harness now; accel_top's clock later). Simulation-only (Verilator --assert).
//
//   a_owner_onehot0      at most one owner at a time
//   a_only_owner_reads   no read request from an input that does not own the buffer
//   a_only_owner_writes  no write request from an input that does not own the buffer
module buf_port_mux_sva #(
    parameter int NUM_OWNERS = 3
) (
    input logic                  clk,
    input logic                  rst,
    input logic [NUM_OWNERS-1:0] i_owner,
    input logic [NUM_OWNERS-1:0] i_re,
    input logic [NUM_OWNERS-1:0] i_we
);

  a_owner_onehot0 :
  assert property (@(posedge clk) disable iff (rst) $onehot0(i_owner));

  a_only_owner_reads :
  assert property (@(posedge clk) disable iff (rst) (i_re & ~i_owner) == '0);

  a_only_owner_writes :
  assert property (@(posedge clk) disable iff (rst) (i_we & ~i_owner) == '0);

endmodule
