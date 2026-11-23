// axil_if: one AXI4-Lite interface (spec §13.3) between the UVM agent and a slave, with the
// protocol rules of both sides checked by concurrent assertions (see below).
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
// Assertions (disabled during reset). The channel rules are the design's own AXI4-Lite checker,
// bound to this interface by axil_if_bind.sv (the modules every Verilator test of an AXI slave
// uses: valid_ready_sva per channel, axil_resp_order_sva for the response order). Here only what
// that checker does not cover: no EXOKAY (not an AXI4-Lite response), the master's VALIDs low in
// reset, BVALID / RVALID low after a reset cycle.
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

  a_master_quiet_in_reset :
  assert property (@(posedge clk) rst |-> !awvalid && !wvalid && !arvalid);
  a_no_exokay :
  assert property (@(posedge clk) disable iff (rst)
    (bvalid |-> bresp != 2'b01) and (rvalid |-> rresp != 2'b01));
  a_slave_quiet_after_reset :
  assert property (@(posedge clk) $past(rst) && rst |-> !bvalid && !rvalid);

endinterface
