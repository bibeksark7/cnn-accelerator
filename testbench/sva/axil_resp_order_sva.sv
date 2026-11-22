// axil_resp_order_sva: AXI4-Lite response ordering for one slave interface (spec §13.3):
// a write response only after both its AW and W have been accepted, a read response only after
// its AR. Bound with the valid_ready_sva channel checks by axil_slave_port_bind.sv and
// axil_interconnect_bind.sv (Verilator --assert runs).
//
//   a_b_after_aw_and_w   bvalid |-> an accepted AW and an accepted W without a B yet
//   a_r_after_ar         rvalid |-> an accepted AR without an R yet
//   c_aw_before_w / c_w_before_aw / c_aw_with_w   covers: each arrival order of a write's AW and W
//
// aw_q, w_q and ar_q count accepted addresses / data not yet answered (a B or R handshake
// answers one of each).
//
// Arrival order. A transfer arrives in the first cycle its VALID is high (VALID then stays high
// until READY, valid_ready_sva). The k-th AW and the k-th W belong to the same write, so with
// equal arrival counts (aw_arr_q == w_arr_q) the next write's AW and W are both still to come, and
// whichever arrives first (or both in one cycle) gives its order. Arrival, not acceptance: a
// slave may hold W until its AW (the interconnect does, spec §13.3), and must still handle a W
// that arrives first. aw_before_w_n, w_before_aw_n and aw_with_w_n count each order over the
// whole simulation (not reset), so a test can require every order
// (testbench/common/coverage.py, cover_aw_w_orders).
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

  // aw_wait_q / w_wait_q: the channel's current transfer arrived in an earlier cycle.
  logic aw_wait_q, w_wait_q;
  int unsigned aw_arr_q, w_arr_q;  // arrivals so far
  logic aw_new, w_new;
  assign aw_new = awvalid && !aw_wait_q;
  assign w_new  = wvalid && !w_wait_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      aw_wait_q <= 1'b0;
      w_wait_q  <= 1'b0;
      aw_arr_q  <= 0;
      w_arr_q   <= 0;
    end else begin
      aw_wait_q <= awvalid && !awready;
      w_wait_q  <= wvalid && !wready;
      if (aw_new) aw_arr_q <= aw_arr_q + 1;
      if (w_new) w_arr_q <= w_arr_q + 1;
    end
  end

  logic aw_before_w, w_before_aw, aw_with_w;
  assign aw_before_w = aw_arr_q == w_arr_q && aw_new && !w_new;
  assign w_before_aw = aw_arr_q == w_arr_q && w_new && !aw_new;
  assign aw_with_w   = aw_arr_q == w_arr_q && aw_new && w_new;

  int unsigned aw_before_w_n = 0;
  int unsigned w_before_aw_n = 0;
  int unsigned aw_with_w_n = 0;
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (aw_before_w) aw_before_w_n <= aw_before_w_n + 1;
      if (w_before_aw) w_before_aw_n <= w_before_aw_n + 1;
      if (aw_with_w) aw_with_w_n <= aw_with_w_n + 1;
    end
  end

  a_b_after_aw_and_w :
  assert property (@(posedge clk) disable iff (rst) bvalid |-> (aw_q > 0 && w_q > 0));

  a_r_after_ar :
  assert property (@(posedge clk) disable iff (rst) rvalid |-> ar_q > 0);

  c_aw_before_w :
  cover property (@(posedge clk) disable iff (rst) aw_before_w);

  c_w_before_aw :
  cover property (@(posedge clk) disable iff (rst) w_before_aw);

  c_aw_with_w :
  cover property (@(posedge clk) disable iff (rst) aw_with_w);

endmodule
