// axil_interconnect: AXI4-Lite interconnect for one master and NS slaves (spec §13.3).
//
// Decode: slave s owns the addresses with (addr & MASK[s]) == BASE[s]; an address no slave owns
// goes to an internal decode-error responder (writes change nothing and get DECERR; reads return
// 0 with DECERR). Regions must not overlap.
//
// Routing: AW, W, AR, B and R pass through combinationally to the selected slave (no added
// cycles). Address and write data go to every slave; only the selected one sees VALID.
//   write  The slave is chosen from AWADDR while AWVALID is high (AWADDR is stable then) and
//          latched when AW is accepted. W is forwarded only once AW is valid or accepted, so a W
//          that arrives first waits for its address. After both AW and W are accepted, B comes
//          from the latched slave.
//   read   The slave is chosen from ARADDR, latched when AR is accepted; R comes from it.
// One write and one read may be outstanding at a time: no new AW (AR) is accepted until the
// write's B (the read's R) has been accepted by the master.
//
// Parameters:
//   NS   - number of slaves
//   BASE - packed NS x 32: base address of slave s in BASE[32s +: 32]
//   MASK - packed NS x 32: address bits compared for slave s in MASK[32s +: 32]
//
// Ports (master side i_s_* / o_s_*, the CPU's AXI4-Lite master connects here; slave side
// o_m_* / i_m_*, one bit or field per slave, slave s at index s):
//   clk, rst                                                     - clock, synchronous reset
//   i_s_awvalid, o_s_awready, i_s_awaddr                         - write address from the master
//   i_s_wvalid, o_s_wready, i_s_wdata, i_s_wstrb                 - write data from the master
//   o_s_bvalid, i_s_bready, o_s_bresp                            - write response to the master
//   i_s_arvalid, o_s_arready, i_s_araddr                         - read address from the master
//   o_s_rvalid, i_s_rready, o_s_rdata, o_s_rresp                 - read data to the master
//   o_m_awvalid, i_m_awready, o_m_awaddr                         - write address to the slaves
//   o_m_wvalid, i_m_wready, o_m_wdata, o_m_wstrb                 - write data to the slaves
//   i_m_bvalid, o_m_bready, i_m_bresp                            - write responses (2 bits each)
//   o_m_arvalid, i_m_arready, o_m_araddr                         - read address to the slaves
//   i_m_rvalid, o_m_rready, i_m_rdata, i_m_rresp                 - read data (32 / 2 bits each)
//
// Latency: none added (combinational routing, one cycle of bookkeeping between transactions).
module axil_interconnect #(
    parameter int              NS   = 3,
    parameter logic [NS*32-1:0] BASE = '0,
    parameter logic [NS*32-1:0] MASK = '0
) (
    input  logic           clk,
    input  logic           rst,
    input  logic           i_s_awvalid,
    output logic           o_s_awready,
    input  logic [   31:0] i_s_awaddr,
    input  logic           i_s_wvalid,
    output logic           o_s_wready,
    input  logic [   31:0] i_s_wdata,
    input  logic [    3:0] i_s_wstrb,
    output logic           o_s_bvalid,
    input  logic           i_s_bready,
    output logic [    1:0] o_s_bresp,
    input  logic           i_s_arvalid,
    output logic           o_s_arready,
    input  logic [   31:0] i_s_araddr,
    output logic           o_s_rvalid,
    input  logic           i_s_rready,
    output logic [   31:0] o_s_rdata,
    output logic [    1:0] o_s_rresp,
    output logic [ NS-1:0] o_m_awvalid,
    input  logic [ NS-1:0] i_m_awready,
    output logic [   31:0] o_m_awaddr,
    output logic [ NS-1:0] o_m_wvalid,
    input  logic [ NS-1:0] i_m_wready,
    output logic [   31:0] o_m_wdata,
    output logic [    3:0] o_m_wstrb,
    input  logic [ NS-1:0] i_m_bvalid,
    output logic [ NS-1:0] o_m_bready,
    input  logic [2*NS-1:0] i_m_bresp,
    output logic [ NS-1:0] o_m_arvalid,
    input  logic [ NS-1:0] i_m_arready,
    output logic [   31:0] o_m_araddr,
    input  logic [ NS-1:0] i_m_rvalid,
    output logic [ NS-1:0] o_m_rready,
    input  logic [32*NS-1:0] i_m_rdata,
    input  logic [2*NS-1:0] i_m_rresp
);

  localparam int SEL_W = $clog2(NS + 1);
  localparam logic [SEL_W-1:0] SEL_NONE = SEL_W'(NS);  // decode error
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // Slave index owning AWADDR / ARADDR, or SEL_NONE (the last matching region wins; regions
  // do not overlap).
  logic [SEL_W-1:0] aw_dec, ar_dec;
  always_comb begin
    aw_dec = SEL_NONE;
    ar_dec = SEL_NONE;
    for (int s = 0; s < NS; s++) begin
      if ((i_s_awaddr & MASK[32*s+:32]) == BASE[32*s+:32]) aw_dec = SEL_W'(s);
      if ((i_s_araddr & MASK[32*s+:32]) == BASE[32*s+:32]) ar_dec = SEL_W'(s);
    end
  end

  // ---------------------------------------------------------------- write channel
  logic aw_done_q, w_done_q;
  logic [SEL_W-1:0] wsel_q, wsel;
  logic aw_hs, w_hs, b_hs, aw_ready_sel, w_ready_sel, b_valid_sel;
  logic [1:0] b_resp_sel;

  assign wsel = aw_done_q ? wsel_q : aw_dec;

  always_comb begin
    aw_ready_sel = 1'b1;  // the decode-error responder accepts at once
    w_ready_sel  = 1'b1;
    b_valid_sel  = 1'b1;
    b_resp_sel   = RESP_DECERR;
    for (int s = 0; s < NS; s++) begin
      if (wsel == SEL_W'(s)) begin
        aw_ready_sel = i_m_awready[s];
        w_ready_sel  = i_m_wready[s];
        b_valid_sel  = i_m_bvalid[s];
        b_resp_sel   = i_m_bresp[2*s+:2];
      end
    end
  end

  logic aw_open, w_open, b_open;
  assign aw_open     = !aw_done_q;
  assign w_open      = !w_done_q && (aw_done_q || i_s_awvalid);
  assign b_open      = aw_done_q && w_done_q;

  assign o_s_awready = aw_open && aw_ready_sel;
  assign o_s_wready  = w_open && w_ready_sel;
  assign o_s_bvalid  = b_open && b_valid_sel;
  assign o_s_bresp   = b_resp_sel;
  assign aw_hs       = i_s_awvalid && o_s_awready;
  assign w_hs        = i_s_wvalid && o_s_wready;
  assign b_hs        = o_s_bvalid && i_s_bready;

  always_comb begin
    for (int s = 0; s < NS; s++) begin
      o_m_awvalid[s] = aw_open && i_s_awvalid && wsel == SEL_W'(s);
      o_m_wvalid[s]  = w_open && i_s_wvalid && wsel == SEL_W'(s);
      o_m_bready[s]  = b_open && i_s_bready && wsel == SEL_W'(s);
    end
  end
  assign o_m_awaddr = i_s_awaddr;
  assign o_m_wdata  = i_s_wdata;
  assign o_m_wstrb  = i_s_wstrb;

  always_ff @(posedge clk) begin
    if (rst) begin
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
    end else if (b_hs) begin
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
    end else begin
      if (aw_hs) aw_done_q <= 1'b1;
      if (w_hs) w_done_q <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (aw_hs) wsel_q <= wsel;
  end

  // ---------------------------------------------------------------- read channel
  logic ar_done_q;
  logic [SEL_W-1:0] rsel_q, rsel;
  logic ar_hs, r_hs, ar_ready_sel, r_valid_sel;
  logic [31:0] r_data_sel;
  logic [1:0] r_resp_sel;

  assign rsel = ar_done_q ? rsel_q : ar_dec;

  always_comb begin
    ar_ready_sel = 1'b1;
    r_valid_sel  = 1'b1;
    r_data_sel   = 32'd0;
    r_resp_sel   = RESP_DECERR;
    for (int s = 0; s < NS; s++) begin
      if (rsel == SEL_W'(s)) begin
        ar_ready_sel = i_m_arready[s];
        r_valid_sel  = i_m_rvalid[s];
        r_data_sel   = i_m_rdata[32*s+:32];
        r_resp_sel   = i_m_rresp[2*s+:2];
      end
    end
  end

  assign o_s_arready = !ar_done_q && ar_ready_sel;
  assign o_s_rvalid  = ar_done_q && r_valid_sel;
  assign o_s_rdata   = r_data_sel;
  assign o_s_rresp   = r_resp_sel;
  assign ar_hs       = i_s_arvalid && o_s_arready;
  assign r_hs        = o_s_rvalid && i_s_rready;

  always_comb begin
    for (int s = 0; s < NS; s++) begin
      o_m_arvalid[s] = !ar_done_q && i_s_arvalid && rsel == SEL_W'(s);
      o_m_rready[s]  = ar_done_q && i_s_rready && rsel == SEL_W'(s);
    end
  end
  assign o_m_araddr = i_s_araddr;

  always_ff @(posedge clk) begin
    if (rst) begin
      ar_done_q <= 1'b0;
    end else if (r_hs) begin
      ar_done_q <= 1'b0;
    end else if (ar_hs) begin
      ar_done_q <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (ar_hs) rsel_q <= rsel;
  end

endmodule
