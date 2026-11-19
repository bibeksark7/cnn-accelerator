// fsm_legal_sva: an FSM state register only ever holds one of its N_STATES encodings
// (0 .. N_STATES-1, the enum's order). Bound by fsm_legal_bind.sv (Verilator --assert runs).
// The RTL's default branches return to IDLE, so an illegal value could only come from a
// corrupted register; the assertion makes that visible instead of silently recovering.
module fsm_legal_sva #(
    parameter int W        = 3,
    parameter int N_STATES = 8
) (
    input logic         clk,
    input logic         rst,
    input logic [W-1:0] state
);

  a_state_legal :
  assert property (@(posedge clk) disable iff (rst) 32'(state) < N_STATES);

endmodule
