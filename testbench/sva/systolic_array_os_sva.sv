// systolic_array_os_sva: implementation assertions for the output-stationary systolic_array.
//
// Refers to internal signals of rtl/core/systolic_array.sv, so it is specific to that
// implementation. Bound by systolic_array_bind.sv. Simulation-only (Verilator --assert).
//
//   a_idle_means_empty  o_idle implies no valid bit in the skew lines or the PE grid
module systolic_array_os_sva #(
    parameter int N = 8
) (
    input logic                               clk,
    input logic                               rst,
    input logic                               o_idle,
    input logic [                  N*N-1:0]   pe_v_out,
    input logic [((N > 1) ? N - 1 : 1) - 1:0] v_dly_q
);

  a_idle_means_empty :
  assert property (@(posedge clk) disable iff (rst) o_idle |-> (pe_v_out == '0 && v_dly_q == '0));

endmodule
