// systolic_array_if_sva: assertions on the systolic_array interface (spec §11.2).
//
// Uses only interface ports, so it applies unchanged to every implementation of the interface
// (output-stationary now, weight-stationary in Phase 7). Bound by systolic_array_bind.sv.
// Simulation-only (Verilator --assert); Icarus does not support concurrent assertions.
//
// Producer obligations:
//   a_clear_not_with_valid  i_clear and i_valid never in the same cycle
//   a_clear_only_when_idle  i_clear only while o_idle
//   a_drain_window_quiet    no i_valid or i_clear from i_drain until the last row is accepted
// Array obligation:
//   a_row_stable            a row held under backpressure keeps its data, last flag and valid
module systolic_array_if_sva #(
    parameter int N     = 8,
    parameter int ACC_W = 32
) (
    input logic               clk,
    input logic               rst,
    input logic               i_clear,
    input logic               i_valid,
    input logic               i_drain,
    input logic               o_row_valid,
    input logic               i_row_ready,
    input logic [N*ACC_W-1:0] o_row_data,
    input logic               o_row_last,
    input logic               o_idle
);

  // Drain window: from the i_drain pulse through the cycle the last row is accepted.
  logic drain_window_q;
  logic in_drain_window;

  always_ff @(posedge clk) begin
    if (rst) begin
      drain_window_q <= 1'b0;
    end else if (i_drain) begin
      drain_window_q <= 1'b1;
    end else if (o_row_valid && i_row_ready && o_row_last) begin
      drain_window_q <= 1'b0;
    end
  end

  assign in_drain_window = i_drain || drain_window_q;

  a_clear_not_with_valid :
  assert property (@(posedge clk) disable iff (rst) !(i_clear && i_valid));

  a_clear_only_when_idle :
  assert property (@(posedge clk) disable iff (rst) i_clear |-> o_idle);

  a_drain_window_quiet :
  assert property (@(posedge clk) disable iff (rst) in_drain_window |-> !(i_valid || i_clear));

  a_row_stable :
  assert property (@(posedge clk) disable iff (rst)
      (o_row_valid && !i_row_ready) |=>
      (o_row_valid && $stable(o_row_data) && $stable(o_row_last)));

endmodule
