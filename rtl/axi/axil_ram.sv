// axil_ram: the SoC RAM as an AXI4-Lite slave (spec §13.5): BYTES of synchronous RAM, preloaded
// from INIT_FILE, with byte, halfword and word writes through WSTRB (WSTRB = 0 changes nothing).
// Every access gets OKAY. Address bits above the RAM size are not decoded here (the
// interconnect sends only RAM addresses); bits [1:0] are ignored.
//
// Parameters:
//   BYTES     - RAM size in bytes (a power of two, at least 8)
//   INIT_FILE - $readmemh image, 32-bit little-endian words from address 0 ("" = none)
//
// Ports:
//   clk, rst                          - clock, synchronous active-high reset (contents survive)
//   i_awvalid ... o_rresp             - AXI4-Lite slave (axil_slave_port), ADDR_W = log2(BYTES)
//
// Latency: a write is answered in the cycle its request is accepted, a read one cycle later
// (plus axil_slave_port's buffering).
module axil_ram #(
    parameter int BYTES     = 65536,
    parameter     INIT_FILE = ""
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     i_awvalid,
    output logic                     o_awready,
    input  logic [$clog2(BYTES)-1:0] i_awaddr,
    input  logic                     i_wvalid,
    output logic                     o_wready,
    input  logic [             31:0] i_wdata,
    input  logic [              3:0] i_wstrb,
    output logic                     o_bvalid,
    input  logic                     i_bready,
    output logic [              1:0] o_bresp,
    input  logic                     i_arvalid,
    output logic                     o_arready,
    input  logic [$clog2(BYTES)-1:0] i_araddr,
    output logic                     o_rvalid,
    input  logic                     i_rready,
    output logic [             31:0] o_rdata,
    output logic [              1:0] o_rresp
);

  localparam int ADDR_W = $clog2(BYTES);
  localparam int WORDS = BYTES / 4;

  logic req_valid, req_we, rsp_valid;
  logic [ADDR_W-1:0] req_addr;
  logic [31:0] req_wdata, rdata;
  logic [3:0] req_wstrb;
  logic rd_pend_q;

  axil_slave_port #(
      .ADDR_W(ADDR_W)
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
      .i_req_ready(1'b1),
      .o_req_we   (req_we),
      .o_req_addr (req_addr),
      .o_req_wdata(req_wdata),
      .o_req_wstrb(req_wstrb),
      .i_rsp_valid(rsp_valid),
      .i_rsp_resp (2'b00),
      .i_rsp_rdata(rdata)
  );

  // Lint waiver: address bits [1:0] select a byte within the word; WSTRB already says which.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ADDR_W-1:0] word_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  assign word_addr = req_addr;

  sram_be #(
      .WORDS    (WORDS),
      .LANES    (4),
      .INIT_FILE(INIT_FILE)
  ) u_sram_be (
      .clk    (clk),
      .i_we   (req_valid && req_we),
      .i_be   (req_wstrb),
      .i_waddr(word_addr[ADDR_W-1:2]),
      .i_wdata(req_wdata),
      .i_re   (req_valid && !req_we),
      .i_raddr(word_addr[ADDR_W-1:2]),
      .o_rdata(rdata)
  );

  // A write is done in its acceptance cycle; a read's data is there one cycle later.
  always_ff @(posedge clk) begin
    if (rst) rd_pend_q <= 1'b0;
    else rd_pend_q <= req_valid && !req_we;
  end
  assign rsp_valid = (req_valid && req_we) || rd_pend_q;

endmodule
