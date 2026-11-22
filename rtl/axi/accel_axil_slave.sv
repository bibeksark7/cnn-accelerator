// accel_axil_slave: the accelerator's AXI4-Lite slave (spec §13.4). Drives accel_top's CSR bus
// (spec §10.1) and memory port (spec §10.3); accel_top itself is unchanged.
//
// Address (offset in the accelerator's 8 MB region, ADDR_W = 23):
//   a[22] = 0  CSR window: a[21:12] must be 0 (otherwise DECERR, nothing accessed); one AXI
//              access is one CSR access at byte offset a[11:0], write data = WDATA, read data =
//              the CSR bus read data in its accepting cycle.
//   a[22] = 1  buffer window: a[21:19] buffer select, a[18:3] word, a[2] half (0 low, 1 high),
//              a[1:0] ignored.
//              write, high half  WHI <= WDATA; no memory-port access
//              write, low half   one memory-port write of {WHI, WDATA}, then WHI <= 0
//              read, either half one memory-port read; returns that half of the word
// Writes must be full words: a write with WSTRB != 4'b1111 to a mapped address is not performed
// and gets SLVERR. Everything else gets OKAY (reserved buffer selects behave as §10.3).
//
// During a run: CSR accesses pass straight to accel_top, which answers them with the §10.1
// latency (registers at once; a descriptor read can wait for the sequencer's descriptor fetch);
// this module adds no wait that depends on BUSY. A WHI write is answered at once. A buffer-window
// read or low-half write waits for i_mem_ready, which accel_top holds low while BUSY, so it
// completes after the run.
//
// Ports:
//   clk, rst                                      - clock, synchronous active-high reset
//   i_awvalid ... o_rresp                         - AXI4-Lite slave (axil_slave_port), 23 bits
//   o_csr_valid, i_csr_ready, o_csr_we, o_csr_addr, o_csr_wdata, i_csr_rdata - CSR bus master
//   o_mem_valid, i_mem_ready, o_mem_we, o_mem_sel, o_mem_addr, o_mem_wdata,
//   i_mem_rvalid, i_mem_rdata                     - memory port master
//
// Latency: a CSR access or a WHI write is answered in the cycle it is accepted; a buffer write
// when the memory port accepts it; a buffer read when its data returns (o_mem_rvalid).
module accel_axil_slave (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_awvalid,
    output logic        o_awready,
    input  logic [22:0] i_awaddr,
    input  logic        i_wvalid,
    output logic        o_wready,
    input  logic [31:0] i_wdata,
    input  logic [ 3:0] i_wstrb,
    output logic        o_bvalid,
    input  logic        i_bready,
    output logic [ 1:0] o_bresp,
    input  logic        i_arvalid,
    output logic        o_arready,
    input  logic [22:0] i_araddr,
    output logic        o_rvalid,
    input  logic        i_rready,
    output logic [31:0] o_rdata,
    output logic [ 1:0] o_rresp,
    output logic        o_csr_valid,
    input  logic        i_csr_ready,
    output logic        o_csr_we,
    output logic [11:0] o_csr_addr,
    output logic [31:0] o_csr_wdata,
    input  logic [31:0] i_csr_rdata,
    output logic        o_mem_valid,
    input  logic        i_mem_ready,
    output logic        o_mem_we,
    output logic [ 2:0] o_mem_sel,
    output logic [15:0] o_mem_addr,
    output logic [63:0] o_mem_wdata,
    input  logic        i_mem_rvalid,
    input  logic [63:0] i_mem_rdata
);

  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10, RESP_DECERR = 2'b11;

  logic req_valid, req_ready, req_we, rsp_valid;
  logic [22:0] req_addr;
  logic [31:0] req_wdata, rsp_rdata;
  logic [3:0] req_wstrb;
  logic [1:0] rsp_resp;

  axil_slave_port #(
      .ADDR_W(23)
  ) u_axil_slave_port (
      .clk        (clk),
      .rst        (rst),
      .i_awvalid  (i_awvalid),
      .o_awready  (o_awready),
      .i_awaddr   (i_awaddr),
      .i_wvalid   (i_wvalid),
      .o_wready   (o_wready),
      .i_wdata    (i_wdata),
      .i_wstrb    (i_wstrb),
      .o_bvalid   (o_bvalid),
      .i_bready   (i_bready),
      .o_bresp    (o_bresp),
      .i_arvalid  (i_arvalid),
      .o_arready  (o_arready),
      .i_araddr   (i_araddr),
      .o_rvalid   (o_rvalid),
      .i_rready   (i_rready),
      .o_rdata    (o_rdata),
      .o_rresp    (o_rresp),
      .o_req_valid(req_valid),
      .i_req_ready(req_ready),
      .o_req_we   (req_we),
      .o_req_addr (req_addr),
      .o_req_wdata(req_wdata),
      .o_req_wstrb(req_wstrb),
      .i_rsp_valid(rsp_valid),
      .i_rsp_resp (rsp_resp),
      .i_rsp_rdata(rsp_rdata)
  );

  // ---------------------------------------------------------------- request decode
  logic is_buf, is_hole, partial, half;
  assign is_buf  = req_addr[22];
  assign is_hole = !req_addr[22] && req_addr[21:12] != '0;
  assign partial = req_we && req_wstrb != 4'b1111;
  assign half    = req_addr[2];

  logic do_csr, do_whi, do_mem;  // the request's action (only one is true)
  assign do_csr = req_valid && !is_buf && !is_hole && !partial;
  assign do_whi = req_valid && is_buf && !partial && req_we && half;
  assign do_mem = req_valid && is_buf && !partial && !(req_we && half);

  assign o_csr_valid = do_csr;
  assign o_csr_we    = req_we;
  assign o_csr_addr  = req_addr[11:0];
  assign o_csr_wdata = req_wdata;

  logic [31:0] whi_q;
  assign o_mem_valid = do_mem;
  assign o_mem_we    = req_we;
  assign o_mem_sel   = req_addr[21:19];
  assign o_mem_addr  = req_addr[18:3];
  assign o_mem_wdata = {whi_q, req_wdata};

  // ---------------------------------------------------------------- acceptance and response
  logic rd_wait_q, rd_half_q;  // a buffer read is waiting for its data / which half
  logic [31:0] mem_half;
  assign mem_half = rd_half_q ? i_mem_rdata[63:32] : i_mem_rdata[31:0];

  always_comb begin
    req_ready = 1'b1;
    rsp_valid = 1'b0;
    rsp_resp  = RESP_OKAY;
    rsp_rdata = 32'd0;
    if (req_valid) begin
      if (is_hole) begin
        rsp_valid = 1'b1;
        rsp_resp  = RESP_DECERR;
      end else if (partial) begin
        rsp_valid = 1'b1;
        rsp_resp  = RESP_SLVERR;
      end else if (do_csr) begin
        req_ready = i_csr_ready;
        rsp_valid = i_csr_ready;
        rsp_rdata = req_we ? 32'd0 : i_csr_rdata;
      end else if (do_whi) begin
        rsp_valid = 1'b1;
      end else begin  // do_mem
        req_ready = i_mem_ready;
        rsp_valid = i_mem_ready && req_we;  // a read is answered when its data returns
      end
    end
    if (rd_wait_q && i_mem_rvalid) begin
      rsp_valid = 1'b1;
      rsp_rdata = mem_half;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      whi_q     <= 32'd0;
      rd_wait_q <= 1'b0;
    end else begin
      if (do_whi) whi_q <= req_wdata;
      else if (do_mem && req_we && i_mem_ready) whi_q <= 32'd0;
      if (do_mem && !req_we && i_mem_ready) rd_wait_q <= 1'b1;
      else if (i_mem_rvalid) rd_wait_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (do_mem && !req_we && i_mem_ready) rd_half_q <= half;
  end

endmodule
