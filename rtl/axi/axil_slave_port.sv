// axil_slave_port: AXI4-Lite slave front end (spec §13.3). Turns the five AXI4-Lite channels into
// one request/response interface, so each SoC slave only implements a simple local protocol.
//
// AXI side (32-bit data; AWPROT/ARPROT are not used):
//   - AW, W and AR each have a one-entry buffer; a channel is ready while its buffer is empty,
//     so AW and W may arrive in either order or in the same cycle.
//   - One transaction at a time: a write starts once both AW and W are buffered, a read once AR
//     is buffered. When both are possible in the same cycle the write goes first (spec §13.3
//     leaves that order unspecified).
//   - B / R are held, with their response and data stable, until BREADY / RREADY. The buffers of
//     a transaction are freed when its response is accepted.
// Local side:
//   - Request: o_req_valid with o_req_we/addr/wdata/wstrb, accepted when i_req_ready. The request
//     is a register output and stays stable until accepted (for a read, wdata/wstrb are don't-care).
//   - Response: i_rsp_valid with i_rsp_resp (and i_rsp_rdata for a read), one pulse per accepted
//     request, in the acceptance cycle or any later cycle; no backpressure. A pulse at any other
//     time is ignored.
//
// Parameters:
//   ADDR_W - address bits passed to the slave (the interconnect has already decoded the region)
//
// Ports:
//   clk, rst                                            - clock, synchronous active-high reset
//   i_awvalid, o_awready, i_awaddr                      - AXI write address
//   i_wvalid, o_wready, i_wdata, i_wstrb                - AXI write data
//   o_bvalid, i_bready, o_bresp                         - AXI write response
//   i_arvalid, o_arready, i_araddr                      - AXI read address
//   o_rvalid, i_rready, o_rdata, o_rresp                - AXI read data
//   o_req_valid, i_req_ready, o_req_we, o_req_addr,
//   o_req_wdata, o_req_wstrb                            - local request
//   i_rsp_valid, i_rsp_resp, i_rsp_rdata                - local response
//
// Latency: the request is presented 1 cycle after the last of its AXI channels is accepted; the
// response appears on B / R 1 cycle after i_rsp_valid.
module axil_slave_port #(
    parameter int ADDR_W = 32
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_awvalid,
    output logic              o_awready,
    input  logic [ADDR_W-1:0] i_awaddr,
    input  logic              i_wvalid,
    output logic              o_wready,
    input  logic [      31:0] i_wdata,
    input  logic [       3:0] i_wstrb,
    output logic              o_bvalid,
    input  logic              i_bready,
    output logic [       1:0] o_bresp,
    input  logic              i_arvalid,
    output logic              o_arready,
    input  logic [ADDR_W-1:0] i_araddr,
    output logic              o_rvalid,
    input  logic              i_rready,
    output logic [      31:0] o_rdata,
    output logic [       1:0] o_rresp,
    output logic              o_req_valid,
    input  logic              i_req_ready,
    output logic              o_req_we,
    output logic [ADDR_W-1:0] o_req_addr,
    output logic [      31:0] o_req_wdata,
    output logic [       3:0] o_req_wstrb,
    input  logic              i_rsp_valid,
    input  logic [       1:0] i_rsp_resp,
    input  logic [      31:0] i_rsp_rdata
);

  typedef enum logic [1:0] {
    S_IDLE,  // waiting for a complete write (AW + W) or a read (AR)
    S_REQ,   // presenting the request
    S_WAIT,  // request accepted, waiting for the response
    S_RESP   // presenting B (write) or R (read)
  } state_t;

  state_t state_q, state_d;
  logic aw_full_q, w_full_q, ar_full_q;
  logic [ADDR_W-1:0] awaddr_q, araddr_q;
  logic [31:0] wdata_q, rdata_q;
  logic [3:0] wstrb_q;
  logic [1:0] resp_q;
  logic we_q;  // the transaction in progress is a write

  logic aw_hs, w_hs, ar_hs, b_hs, r_hs, req_hs, rsp_take;
  logic aw_full_d, w_full_d, ar_full_d;
  assign aw_hs     = i_awvalid && o_awready;
  assign w_hs      = i_wvalid && o_wready;
  assign ar_hs     = i_arvalid && o_arready;
  assign b_hs      = o_bvalid && i_bready;
  assign r_hs      = o_rvalid && i_rready;
  assign req_hs    = o_req_valid && i_req_ready;
  // A response counts when it arrives with the acceptance or while waiting for it.
  assign rsp_take  = i_rsp_valid && (req_hs || state_q == S_WAIT);

  // Buffer occupancy after this cycle's AXI handshakes (used to start a transaction without an
  // extra idle cycle).
  assign aw_full_d = aw_full_q || aw_hs;
  assign w_full_d  = w_full_q || w_hs;
  assign ar_full_d = ar_full_q || ar_hs;

  always_comb begin
    state_d = state_q;
    case (state_q)
      S_IDLE:  if ((aw_full_d && w_full_d) || ar_full_d) state_d = S_REQ;
      S_REQ: begin
        if (req_hs && rsp_take) state_d = S_RESP;
        else if (req_hs) state_d = S_WAIT;
      end
      S_WAIT:  if (rsp_take) state_d = S_RESP;
      S_RESP:  if (b_hs || r_hs) state_d = S_IDLE;
      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q   <= S_IDLE;
      aw_full_q <= 1'b0;
      w_full_q  <= 1'b0;
      ar_full_q <= 1'b0;
      we_q      <= 1'b0;
    end else begin
      state_q <= state_d;
      if (state_q == S_IDLE) begin
        we_q <= aw_full_d && w_full_d;
      end
      if (b_hs) begin
        aw_full_q <= 1'b0;
        w_full_q  <= 1'b0;
      end else begin
        aw_full_q <= aw_full_d;
        w_full_q  <= w_full_d;
      end
      ar_full_q <= r_hs ? 1'b0 : ar_full_d;
    end
  end

  // Channel and response registers (no reset: each is used only with its valid/full flag).
  always_ff @(posedge clk) begin
    if (aw_hs) awaddr_q <= i_awaddr;
    if (w_hs) begin
      wdata_q <= i_wdata;
      wstrb_q <= i_wstrb;
    end
    if (ar_hs) araddr_q <= i_araddr;
    if (rsp_take) begin
      resp_q  <= i_rsp_resp;
      rdata_q <= we_q ? 32'd0 : i_rsp_rdata;
    end
  end

  assign o_awready   = !aw_full_q;
  assign o_wready    = !w_full_q;
  assign o_arready   = !ar_full_q;
  assign o_bvalid    = state_q == S_RESP && we_q;
  assign o_bresp     = resp_q;
  assign o_rvalid    = state_q == S_RESP && !we_q;
  assign o_rdata     = rdata_q;
  assign o_rresp     = resp_q;

  assign o_req_valid = state_q == S_REQ;
  assign o_req_we    = we_q;
  assign o_req_addr  = we_q ? awaddr_q : araddr_q;
  assign o_req_wdata = wdata_q;
  assign o_req_wstrb = wstrb_q;

endmodule
