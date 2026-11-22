// accel_axil_tb: accel_axil_slave driving an accel_top (system test of spec §13.4). The AXI
// ports are the slave's (23-bit offsets in the accelerator's region); accel_top's status
// outputs are brought out for the test's monitors.
module accel_axil_tb #(
    parameter IMG_INIT   = "",
    parameter WGT_INIT   = "",
    parameter PARAM_INIT = "",
    parameter DESC_INIT  = ""
) (
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
    output logic        o_busy,
    output logic        o_done,
    output logic        o_error,
    output logic [ 7:0] o_result
);

  logic csr_valid, csr_ready, csr_we;
  logic [11:0] csr_addr;
  logic [31:0] csr_wdata, csr_rdata, cyc_total;
  logic mem_valid, mem_ready, mem_we, mem_rvalid;
  logic [2:0] mem_sel;
  logic [15:0] mem_addr;
  logic [63:0] mem_wdata, mem_rdata;

  accel_axil_slave u_accel_axil_slave (
      .clk         (clk),
      .rst         (rst),
      .i_awvalid   (i_awvalid),
      .o_awready   (o_awready),
      .i_awaddr    (i_awaddr),
      .i_wvalid    (i_wvalid),
      .o_wready    (o_wready),
      .i_wdata     (i_wdata),
      .i_wstrb     (i_wstrb),
      .o_bvalid    (o_bvalid),
      .i_bready    (i_bready),
      .o_bresp     (o_bresp),
      .i_arvalid   (i_arvalid),
      .o_arready   (o_arready),
      .i_araddr    (i_araddr),
      .o_rvalid    (o_rvalid),
      .i_rready    (i_rready),
      .o_rdata     (o_rdata),
      .o_rresp     (o_rresp),
      .o_csr_valid (csr_valid),
      .i_csr_ready (csr_ready),
      .o_csr_we    (csr_we),
      .o_csr_addr  (csr_addr),
      .o_csr_wdata (csr_wdata),
      .i_csr_rdata (csr_rdata),
      .o_mem_valid (mem_valid),
      .i_mem_ready (mem_ready),
      .o_mem_we    (mem_we),
      .o_mem_sel   (mem_sel),
      .o_mem_addr  (mem_addr),
      .o_mem_wdata (mem_wdata),
      .i_mem_rvalid(mem_rvalid),
      .i_mem_rdata (mem_rdata)
  );

  accel_top #(
      .IMG_INIT  (IMG_INIT),
      .WGT_INIT  (WGT_INIT),
      .PARAM_INIT(PARAM_INIT),
      .DESC_INIT (DESC_INIT)
  ) u_accel_top (
      .clk         (clk),
      .rst         (rst),
      .i_csr_valid (csr_valid),
      .i_csr_we    (csr_we),
      .i_csr_addr  (csr_addr),
      .i_csr_wdata (csr_wdata),
      .o_csr_ready (csr_ready),
      .o_csr_rdata (csr_rdata),
      .i_mem_valid (mem_valid),
      .o_mem_ready (mem_ready),
      .i_mem_we    (mem_we),
      .i_mem_sel   (mem_sel),
      .i_mem_addr  (mem_addr),
      .i_mem_wdata (mem_wdata),
      .o_mem_rvalid(mem_rvalid),
      .o_mem_rdata (mem_rdata),
      .o_busy      (o_busy),
      .o_done      (o_done),
      .o_error     (o_error),
      .o_result    (o_result),
      .o_cyc_total (cyc_total)
  );

  // Lint waiver: CYC_TOTAL is read through the CSR window.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] unused_cyc_total;
  /* verilator lint_on UNUSEDSIGNAL */
  assign unused_cyc_total = cyc_total;

endmodule
