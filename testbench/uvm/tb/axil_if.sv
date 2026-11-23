// axil_if: one AXI4-Lite interface (spec §13.3) between the UVM agent and a slave, with the
// protocol rules of both sides as concurrent assertions.
//
// Parameters:
//   ADDR_W - address width (23 for the accelerator's slave: offsets in its 8 MB region)
//
// Signals: the five AXI4-Lite channels (no AxPROT: the design does not use them), plus `rst`
// (synchronous, active high; driven by tb_top) and `cycle`, a free-running cycle count that the
// monitors use to time-stamp handshakes.
//
// Clocking blocks: `drv_cb` for the driver (outputs 1 ns after the edge), `mon_cb` for the monitor
// (inputs sampled just before the edge, so a handshake counts in the cycle whose rising edge sees
// valid && ready).
//
// Assertions (disabled during reset). Master side: AWVALID / WVALID / ARVALID stay high, with
// their payload stable, until accepted; all three are low in reset. Slave side: BVALID / RVALID
// stay high, with response and data stable, until accepted; a write response only for a write
// whose AW and W were both accepted, a read response only for an accepted AR; no EXOKAY (not an
// AXI4-Lite response); BVALID / RVALID low after a reset cycle.
interface axil_if #(
    parameter int ADDR_W = 23
) (
    input logic clk
);
  logic              rst;
  logic              awvalid;
  logic              awready;
  logic [ADDR_W-1:0] awaddr;
  logic              wvalid;
  logic              wready;
  logic [      31:0] wdata;
  logic [       3:0] wstrb;
  logic              bvalid;
  logic              bready;
  logic [       1:0] bresp;
  logic              arvalid;
  logic              arready;
  logic [ADDR_W-1:0] araddr;
  logic              rvalid;
  logic              rready;
  logic [      31:0] rdata;
  logic [       1:0] rresp;
  longint            cycle = 0;

  always @(posedge clk) cycle <= cycle + 1;

  clocking drv_cb @(posedge clk);
    default input #1step output #1ns;
    output awvalid, awaddr, wvalid, wdata, wstrb, bready, arvalid, araddr, rready;
    input awready, wready, bvalid, bresp, arready, rvalid, rdata, rresp, rst;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, awvalid, awready, awaddr, wvalid, wready, wdata, wstrb, bvalid, bready, bresp;
    input arvalid, arready, araddr, rvalid, rready, rdata, rresp, cycle;
  endclocking

  // Transactions accepted but not yet answered, per channel (for the response-order rules).
  int unsigned aw_n = 0, w_n = 0, b_n = 0, ar_n = 0, r_n = 0;
  always @(posedge clk) begin
    if (rst) begin
      aw_n <= 0;
      w_n  <= 0;
      b_n  <= 0;
      ar_n <= 0;
      r_n  <= 0;
    end else begin
      if (awvalid && awready) aw_n <= aw_n + 1;
      if (wvalid && wready) w_n <= w_n + 1;
      if (bvalid && bready) b_n <= b_n + 1;
      if (arvalid && arready) ar_n <= ar_n + 1;
      if (rvalid && rready) r_n <= r_n + 1;
    end
  end

  // ---------------------------------------------------------------- master obligations
  a_awvalid_held :
  assert property (@(posedge clk) disable iff (rst)
    awvalid && !awready |=> awvalid && $stable(awaddr));
  a_wvalid_held :
  assert property (@(posedge clk) disable iff (rst)
    wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb));
  a_arvalid_held :
  assert property (@(posedge clk) disable iff (rst)
    arvalid && !arready |=> arvalid && $stable(araddr));
  a_master_quiet_in_reset :
  assert property (@(posedge clk) rst |-> !awvalid && !wvalid && !arvalid);

  // ---------------------------------------------------------------- slave obligations
  a_bvalid_held :
  assert property (@(posedge clk) disable iff (rst) bvalid && !bready |=> bvalid && $stable(bresp));
  a_rvalid_held :
  assert property (@(posedge clk) disable iff (rst)
    rvalid && !rready |=> rvalid && $stable(rdata) && $stable(rresp));
  a_b_after_aw_and_w :
  assert property (@(posedge clk) disable iff (rst) bvalid |-> aw_n > b_n && w_n > b_n);
  a_r_after_ar :
  assert property (@(posedge clk) disable iff (rst) rvalid |-> ar_n > r_n);
  a_no_exokay :
  assert property (@(posedge clk) disable iff (rst)
    (bvalid |-> bresp != 2'b01) and (rvalid |-> rresp != 2'b01));
  a_slave_quiet_after_reset :
  assert property (@(posedge clk) $past(rst) && rst |-> !bvalid && !rvalid);

endinterface
