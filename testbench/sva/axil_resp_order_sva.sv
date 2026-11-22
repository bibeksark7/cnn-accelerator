// axil_resp_order_sva: AXI4-Lite response ordering for one slave interface (spec §13.3):
// a write response only after both its AW and W have been accepted, a read response only after
// its AR. Bound with the valid_ready_sva channel checks by axil_slave_port_bind.sv and
// axil_interconnect_bind.sv (Verilator --assert runs).
//
//   a_b_after_aw_and_w   bvalid |-> an accepted AW and an accepted W without a B yet
//   a_r_after_ar         rvalid |-> an accepted AR without an R yet
//   c_aw_before_w / c_w_before_aw / c_aw_with_w   covers: each arrival order of AW and W
//
// aw_q, w_q and ar_q count accepted addresses / data not yet answered (a B or R handshake
// answers one of each).
module axil_resp_order_sva (
    input logic clk,
    input logic rst,
    input logic awvalid,
    input logic awready,
    input logic wvalid,
    input logic wready,
    input logic bvalid,
    input logic bready,
    input logic arvalid,
    input logic arready,
    input logic rvalid,
    input logic rready
);

  int aw_q, w_q, ar_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      aw_q <= 0;
      w_q  <= 0;
      ar_q <= 0;
    end else begin
      aw_q <= aw_q + int'(awvalid && awready) - int'(bvalid && bready);
      w_q  <= w_q + int'(wvalid && wready) - int'(bvalid && bready);
      ar_q <= ar_q + int'(arvalid && arready) - int'(rvalid && rready);
    end
  end

  a_b_after_aw_and_w :
  assert property (@(posedge clk) disable iff (rst) bvalid |-> (aw_q > 0 && w_q > 0));

  a_r_after_ar :
  assert property (@(posedge clk) disable iff (rst) rvalid |-> ar_q > 0);

  c_aw_before_w :
  cover property (@(posedge clk) disable iff (rst) awvalid && awready && w_q == 0 && !wvalid);

  c_w_before_aw :
  cover property (@(posedge clk) disable iff (rst) wvalid && wready && aw_q == 0 && !awvalid);

  c_aw_with_w :
  cover property (@(posedge clk) disable iff (rst) awvalid && awready && wvalid && wready);

endmodule
