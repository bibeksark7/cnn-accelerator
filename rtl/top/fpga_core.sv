// fpga_core: the board-independent part of the FPGA demo (spec §12): accel_top with its images,
// weights, parameters and descriptors preloaded, the demo controller, a register stage on the
// CSR bus and on the memory port, and the label ROM for the display.
//
// The demo controller writes IMG_SEL and CTRL.START on a start press. A host side (CSR and
// memory port, each through its register stage) gives a test or bring-up master full access;
// on the board it is tied off. Status comes straight from accel_top's status outputs.
//
// Parameters: accel_top's init files (IMG_INIT, WGT_INIT, PARAM_INIT, DESC_INIT) and LABEL_INIT
// (16 labels, one hex digit per line).
//
// Ports:
//   clk, rst                                   - clock, synchronous active-high reset
//   i_start                                    - start press (one-cycle pulse)
//   i_img_sel                                  - image index for the next run
//   i_host_csr_valid, o_host_csr_ready, i_host_csr_we, i_host_csr_addr, i_host_csr_wdata,
//   o_host_csr_rvalid, o_host_csr_rdata        - host CSR side (csr_slice front protocol)
//   i_host_mem_valid, o_host_mem_ready, i_host_mem_we, i_host_mem_sel, i_host_mem_addr,
//   i_host_mem_wdata, o_host_mem_rvalid, o_host_mem_rdata - host memory port (mem_slice front)
//   o_busy, o_done, o_error, o_result, o_cyc_total - accel_top status
//   o_run_sel                                  - image index of the last run started by a press
//   o_label                                    - label of the image shown: the last run's once
//                                                it is DONE, otherwise i_img_sel's (1 cycle)
//
// Latency: data-dependent (one inference is about 47k cycles); use o_done.
module fpga_core #(
    parameter IMG_INIT   = "",
    parameter WGT_INIT   = "",
    parameter PARAM_INIT = "",
    parameter DESC_INIT  = "",
    parameter LABEL_INIT = ""
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_start,
    input  logic [ 3:0] i_img_sel,
    input  logic        i_host_csr_valid,
    output logic        o_host_csr_ready,
    input  logic        i_host_csr_we,
    input  logic [11:0] i_host_csr_addr,
    input  logic [31:0] i_host_csr_wdata,
    output logic        o_host_csr_rvalid,
    output logic [31:0] o_host_csr_rdata,
    input  logic        i_host_mem_valid,
    output logic        o_host_mem_ready,
    input  logic        i_host_mem_we,
    input  logic [ 2:0] i_host_mem_sel,
    input  logic [15:0] i_host_mem_addr,
    input  logic [63:0] i_host_mem_wdata,
    output logic        o_host_mem_rvalid,
    output logic [63:0] o_host_mem_rdata,
    output logic        o_busy,
    output logic        o_done,
    output logic        o_error,
    output logic [ 7:0] o_result,
    output logic [31:0] o_cyc_total,
    output logic [ 3:0] o_run_sel,
    output logic [ 3:0] o_label
);

  // ---------------------------------------------------------------- CSR: controller + stage
  logic c_valid, c_ready, c_we;
  logic [11:0] c_addr;
  logic [31:0] c_wdata;
  logic csr_valid, csr_ready, csr_we;
  logic [11:0] csr_addr;
  logic [31:0] csr_wdata, csr_rdata;
  logic busy;

  demo_ctrl u_demo_ctrl (
      .clk         (clk),
      .rst         (rst),
      .i_start     (i_start),
      .i_img_sel   (i_img_sel),
      .i_busy      (busy),
      .o_run_sel   (o_run_sel),
      .i_host_valid(i_host_csr_valid),
      .o_host_ready(o_host_csr_ready),
      .i_host_we   (i_host_csr_we),
      .i_host_addr (i_host_csr_addr),
      .i_host_wdata(i_host_csr_wdata),
      .o_valid     (c_valid),
      .i_ready     (c_ready),
      .o_we        (c_we),
      .o_addr      (c_addr),
      .o_wdata     (c_wdata)
  );

  csr_slice u_csr_slice (
      .clk        (clk),
      .rst        (rst),
      .i_valid    (c_valid),
      .o_ready    (c_ready),
      .i_we       (c_we),
      .i_addr     (c_addr),
      .i_wdata    (c_wdata),
      .o_rvalid   (o_host_csr_rvalid),
      .o_rdata    (o_host_csr_rdata),
      .o_csr_valid(csr_valid),
      .i_csr_ready(csr_ready),
      .o_csr_we   (csr_we),
      .o_csr_addr (csr_addr),
      .o_csr_wdata(csr_wdata),
      .i_csr_rdata(csr_rdata)
  );

  // ---------------------------------------------------------------- memory port stage
  logic mem_valid, mem_ready, mem_we, mem_rvalid;
  logic [2:0] mem_sel;
  logic [15:0] mem_addr;
  logic [63:0] mem_wdata, mem_rdata;

  mem_slice u_mem_slice (
      .clk         (clk),
      .rst         (rst),
      .i_valid     (i_host_mem_valid),
      .o_ready     (o_host_mem_ready),
      .i_we        (i_host_mem_we),
      .i_sel       (i_host_mem_sel),
      .i_addr      (i_host_mem_addr),
      .i_wdata     (i_host_mem_wdata),
      .o_rvalid    (o_host_mem_rvalid),
      .o_rdata     (o_host_mem_rdata),
      .o_mem_valid (mem_valid),
      .i_mem_ready (mem_ready),
      .o_mem_we    (mem_we),
      .o_mem_sel   (mem_sel),
      .o_mem_addr  (mem_addr),
      .o_mem_wdata (mem_wdata),
      .i_mem_rvalid(mem_rvalid),
      .i_mem_rdata (mem_rdata)
  );

  // ---------------------------------------------------------------- accelerator
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
      .o_busy      (busy),
      .o_done      (o_done),
      .o_error     (o_error),
      .o_result    (o_result),
      .o_cyc_total (o_cyc_total)
  );
  assign o_busy = busy;

  // ---------------------------------------------------------------- label ROM (display)
  sram_1r1w #(
      .WIDTH    (4),
      .DEPTH    (16),
      .INIT_FILE(LABEL_INIT)
  ) u_sram_1r1w_label (
      .clk    (clk),
      .i_we   (1'b0),
      .i_waddr(4'd0),
      .i_wdata(4'd0),
      .i_re   (1'b1),
      .i_raddr(o_done ? o_run_sel : i_img_sel),
      .o_rdata(o_label)
  );

endmodule
