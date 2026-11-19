// valid_ready_sva: the generic valid/ready rule for one link (spec §10.1's rule, applied to the
// internal links): once `valid` is high it stays high, with `payload` unchanged, until `ready`.
// Bound per module by the *_vr_bind.sv files (Verilator --assert runs).
//
//   a_valid_held      valid && !ready |=> valid
//   a_payload_stable  valid && !ready |=> $stable(payload)
//   c_stall           cover: a stall (valid && !ready) happens
// stalls_q / transfers_q count stalls and transfers over the whole simulation (not reset), so a
// test can require that the link was exercised under backpressure (testbench/common/coverage.py
// reads them).
module valid_ready_sva #(
    parameter int W = 1
) (
    input logic         clk,
    input logic         rst,
    input logic         valid,
    input logic         ready,
    input logic [W-1:0] payload
);

  int unsigned stalls_q = 0;
  int unsigned transfers_q = 0;
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (valid && !ready) stalls_q <= stalls_q + 1;
      if (valid && ready) transfers_q <= transfers_q + 1;
    end
  end

  a_valid_held :
  assert property (@(posedge clk) disable iff (rst) (valid && !ready) |=> valid);

  a_payload_stable :
  assert property (@(posedge clk) disable iff (rst) (valid && !ready) |=> $stable(payload));

  c_stall :
  cover property (@(posedge clk) disable iff (rst) valid && !ready);

endmodule
