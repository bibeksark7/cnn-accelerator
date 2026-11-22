// req_rsp_sva: a request/response link without response backpressure (axil_slave_port's local
// side, spec-internal): one response per accepted request, never a response without one.
// Bound by axil_slave_port_bind.sv (Verilator --assert runs).
//
//   a_rsp_answers_req   rsp_valid |-> an accepted, unanswered request (or one accepted this cycle)
//   a_one_outstanding        at most one accepted request is unanswered
//   a_accept_when_none_open  a new request is accepted only when none is unanswered
module req_rsp_sva (
    input logic clk,
    input logic rst,
    input logic req_valid,
    input logic req_ready,
    input logic rsp_valid
);

  int open_q;  // accepted requests not yet answered
  logic req_hs;
  assign req_hs = req_valid && req_ready;
  always_ff @(posedge clk) begin
    if (rst) open_q <= 0;
    else open_q <= open_q + int'(req_hs) - int'(rsp_valid);
  end

  a_rsp_answers_req :
  assert property (@(posedge clk) disable iff (rst) rsp_valid |-> (open_q > 0 || req_hs));

  a_one_outstanding :
  assert property (@(posedge clk) disable iff (rst) open_q <= 1);

  a_accept_when_none_open :
  assert property (@(posedge clk) disable iff (rst) req_hs |-> open_q == 0);

endmodule
