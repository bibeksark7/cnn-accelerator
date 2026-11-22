// axil_ram: the SoC RAM as an AXI4-Lite slave (spec §13.5): BYTES of synchronous RAM, preloaded
// from INIT_FILE, with byte, halfword and word writes through WSTRB (WSTRB = 0 changes nothing).
// Every access gets OKAY. Address bits above the RAM size are not decoded here (the
// interconnect sends only RAM addresses); bits [1:0] are ignored.
//
// The memory is a 32-bit sram_1r1w (the block-RAM template the accelerator's buffers use). A
// write with every strobe set is one RAM write; a write with only some strobes set is a
// read-modify-write: the word is read, the strobed bytes are replaced, and the word is written
// back one cycle later. (A byte-lane RAM with per-byte write enables is not inferred as block RAM
// by Quartus Prime Lite 22.1, D-042.)
//
// Parameters:
//   BYTES     - RAM size in bytes (a power of two, at least 8)
//   INIT_FILE - $readmemh image, 32-bit little-endian words from address 0 ("" = none)
//
// Ports:
//   clk, rst                          - clock, synchronous active-high reset (contents survive)
//   i_awvalid ... o_rresp             - AXI4-Lite slave (axil_slave_port), ADDR_W = log2(BYTES)
//
// Latency: a full-word write is answered in the cycle its request is accepted, a partial write
// one cycle later, a read one cycle after acceptance (plus axil_slave_port's buffering).
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
  logic rd_pend_q, req_ready;

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
      .i_req_ready(req_ready),
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

  localparam int WA = ADDR_W - 2;  // word address bits
  logic [WA-1:0] waddr;
  assign waddr = word_addr[ADDR_W-1:2];

  // Request kinds (only one holds while req_valid).
  logic full_wr, part_wr, no_wr, rd;
  assign full_wr = req_valid && req_we && req_wstrb == 4'b1111;
  assign no_wr   = req_valid && req_we && req_wstrb == 4'b0000;
  assign part_wr = req_valid && req_we && !full_wr && !no_wr;
  assign rd      = req_valid && !req_we;

  logic rmw_q;  // a partial write has read its word; it is merged and written this cycle
  logic [31:0] merged;
  always_comb begin
    for (int b = 0; b < 4; b++) begin
      merged[8*b+:8] = req_wstrb[b] ? req_wdata[8*b+:8] : rdata[8*b+:8];
    end
  end

  logic ram_we, ram_re;
  logic [31:0] ram_wdata;
  assign ram_we    = full_wr || (part_wr && rmw_q);
  assign ram_wdata = full_wr ? req_wdata : merged;
  assign ram_re    = rd || (part_wr && !rmw_q);

  sram_1r1w #(
      .WIDTH    (32),
      .DEPTH    (WORDS),
      .INIT_FILE(INIT_FILE)
  ) u_sram_1r1w (
      .clk    (clk),
      .i_we   (ram_we),
      .i_waddr(waddr),
      .i_wdata(ram_wdata),
      .i_re   (ram_re),
      .i_raddr(waddr),
      .o_rdata(rdata)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_pend_q <= 1'b0;
      rmw_q     <= 1'b0;
    end else begin
      rd_pend_q <= rd;
      rmw_q     <= part_wr && !rmw_q;
    end
  end

  // A partial write waits one cycle for its read; everything else is accepted at once.
  assign req_ready = !(part_wr && !rmw_q);
  assign rsp_valid = full_wr || no_wr || (part_wr && rmw_q) || rd_pend_q;

endmodule
