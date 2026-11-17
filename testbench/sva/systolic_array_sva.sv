// systolic_array_sva: protocol and state assertions for systolic_array (spec §11.2).
//
// Simulation-only (Verilator with --assert); bound into every systolic_array instance by the
// bind statement at the end of this file. Icarus does not support concurrent assertions, so
// Icarus runs do not compile this file.
//
// Input-protocol properties (the producer's obligations):
//   a_clear_not_with_valid  i_clear and i_valid never in the same cycle
//   a_clear_only_when_idle  i_clear only while o_idle
//   a_drain_window_quiet    no i_valid or i_clear from i_drain until the last row is accepted
// Output properties (the array's obligations):
//   a_row_stable            a row held under backpressure keeps its data, last flag and valid
//   a_idle_means_empty      o_idle implies no valid bit in the skew lines or the PE grid
module systolic_array_sva #(
    parameter int N      = 8,
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input logic                                 clk,
    input logic                                 rst,
    input logic                                 i_clear,
    input logic                                 i_valid,
    input logic                                 i_drain,
    input logic                                 o_row_valid,
    input logic                                 i_row_ready,
    input logic [                N*ACC_W-1:0]   o_row_data,
    input logic                                 o_row_last,
    input logic                                 o_idle,
    input logic [                    N*N-1:0]   pe_v_out,
    input logic [((N > 1) ? N - 1 : 1) - 1:0]   v_dly_q
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

  a_idle_means_empty :
  assert property (@(posedge clk) disable iff (rst) o_idle |-> (pe_v_out == '0 && v_dly_q == '0));

endmodule

bind systolic_array systolic_array_sva #(
    .N     (N),
    .DATA_W(DATA_W),
    .ACC_W (ACC_W)
) u_systolic_array_sva (
    .clk        (clk),
    .rst        (rst),
    .i_clear    (i_clear),
    .i_valid    (i_valid),
    .i_drain    (i_drain),
    .o_row_valid(o_row_valid),
    .i_row_ready(i_row_ready),
    .o_row_data (o_row_data),
    .o_row_last (o_row_last),
    .o_idle     (o_idle),
    .pe_v_out   (pe_v_out),
    .v_dly_q    (v_dly_q)
);
