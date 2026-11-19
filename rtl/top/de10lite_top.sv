// de10lite_top: the DE10-Lite demo (spec §12). Port names are Terasic's (DE10-Lite golden top).
//
//   MAX10_CLK1_50  50 MHz clock (the only clock)
//   KEY[1]         reset (active low), OR'd with a power-on reset (reset_gen)
//   KEY[0]         start (active low): synchronized, debounced, a press starts one inference of
//                  the image selected by SW[3:0]; ignored while busy
//   SW[3:0]        image index 0..15 (the 16 preloaded test images); SW[9:4] unused
//   HEX0           predicted digit when DONE, 'E' on ERROR, '-' while busy, blank before a run
//   HEX1           true label of the image (the last run's once DONE, else SW[3:0]'s)
//   HEX5..HEX2     min(CYC_TOTAL >> CYC_SHIFT, 0xFFFF) in hex (units of 2^CYC_SHIFT cycles)
//   LEDR[0]        busy; LEDR[1] done; LEDR[2] error; LEDR[9] cycle display saturated
// Segments are active low. Every SW and KEY input passes through a 2-FF synchronizer.
//
// Parameters:
//   IMG_INIT, WGT_INIT, PARAM_INIT, DESC_INIT, LABEL_INIT - init files (model/artifacts/mem;
//                 fpga/de10lite/build.tcl passes them; "" = none)
//   POR_CYCLES  - power-on reset length (cycles)
//   DEBOUNCE_W  - start-button debounce: 2^DEBOUNCE_W stable cycles (2^20: 21 ms)
//   CYC_SHIFT   - cycle-count display shift
//
// Latency: an inference takes about 47k cycles (under 1 ms) after the debounced press.
module de10lite_top #(
    parameter     IMG_INIT   = "",
    parameter     WGT_INIT   = "",
    parameter     PARAM_INIT = "",
    parameter     DESC_INIT  = "",
    parameter     LABEL_INIT = "",
    parameter int POR_CYCLES = 256,
    parameter int DEBOUNCE_W = 20,
    parameter int CYC_SHIFT  = 4
) (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    // Lint waiver: SW[9:4] are not used by the demo.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [9:0] SW,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [7:0] HEX0,
    output logic [7:0] HEX1,
    output logic [7:0] HEX2,
    output logic [7:0] HEX3,
    output logic [7:0] HEX4,
    output logic [7:0] HEX5,
    output logic [9:0] LEDR
);

  logic clk, rst;
  assign clk = MAX10_CLK1_50;

  reset_gen #(
      .POR_CYCLES(POR_CYCLES)
  ) u_reset_gen (
      .clk        (clk),
      .i_key_rst_n(KEY[1]),
      .o_rst      (rst)
  );

  // ---------------------------------------------------------------- inputs
  logic [3:0] img_sel;
  logic key0_n, start;

  sync_2ff #(
      .W    (4),
      .RESET(0)
  ) u_sync_2ff_sw (
      .clk    (clk),
      .rst    (rst),
      .i_async(SW[3:0]),
      .o_sync (img_sel)
  );

  sync_2ff #(
      .W    (1),
      .RESET(1)
  ) u_sync_2ff_key0 (
      .clk    (clk),
      .rst    (rst),
      .i_async(KEY[0]),
      .o_sync (key0_n)
  );

  // Lint waiver: the debounced level is not needed, only the press pulse.
  /* verilator lint_off UNUSEDSIGNAL */
  logic key0_level_n;
  /* verilator lint_on UNUSEDSIGNAL */
  debounce #(
      .CNT_W(DEBOUNCE_W)
  ) u_debounce_key0 (
      .clk      (clk),
      .rst      (rst),
      .i_key_n  (key0_n),
      .o_level_n(key0_level_n),
      .o_press  (start)
  );

  // ---------------------------------------------------------------- core (host side tied off)
  logic busy, done, error;
  // Lint waiver: the host side is unused on the board; RESULT is 0..9 (low nibble shown).
  /* verilator lint_off UNUSEDSIGNAL */
  logic host_csr_ready, host_csr_rvalid, host_mem_ready, host_mem_rvalid;
  logic [31:0] host_csr_rdata;
  logic [63:0] host_mem_rdata;
  logic [7:0] result;
  logic [3:0] run_sel;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] cyc_total;
  logic [3:0] label;

  fpga_core #(
      .IMG_INIT  (IMG_INIT),
      .WGT_INIT  (WGT_INIT),
      .PARAM_INIT(PARAM_INIT),
      .DESC_INIT (DESC_INIT),
      .LABEL_INIT(LABEL_INIT)
  ) u_fpga_core (
      .clk              (clk),
      .rst              (rst),
      .i_start          (start),
      .i_img_sel        (img_sel),
      .i_host_csr_valid (1'b0),
      .o_host_csr_ready (host_csr_ready),
      .i_host_csr_we    (1'b0),
      .i_host_csr_addr  (12'd0),
      .i_host_csr_wdata (32'd0),
      .o_host_csr_rvalid(host_csr_rvalid),
      .o_host_csr_rdata (host_csr_rdata),
      .i_host_mem_valid (1'b0),
      .o_host_mem_ready (host_mem_ready),
      .i_host_mem_we    (1'b0),
      .i_host_mem_sel   (3'd0),
      .i_host_mem_addr  (16'd0),
      .i_host_mem_wdata (64'd0),
      .o_host_mem_rvalid(host_mem_rvalid),
      .o_host_mem_rdata (host_mem_rdata),
      .o_busy           (busy),
      .o_done           (done),
      .o_error          (error),
      .o_result         (result),
      .o_cyc_total      (cyc_total),
      .o_run_sel        (run_sel),
      .o_label          (label)
  );

  // ---------------------------------------------------------------- displays
  localparam logic [4:0] CODE_BLANK = 5'd16;
  localparam logic [4:0] CODE_DASH = 5'd17;
  localparam logic [4:0] CODE_E = 5'd18;

  // Cycle count in units of 2^CYC_SHIFT, saturated to 4 hex digits.
  logic [31:0] cyc_shifted;
  logic cyc_sat;
  logic [15:0] cyc_disp;
  assign cyc_shifted = cyc_total >> CYC_SHIFT;
  assign cyc_sat     = (cyc_shifted > 32'h0000_FFFF);
  assign cyc_disp    = cyc_sat ? 16'hFFFF : cyc_shifted[15:0];

  // HEX0: '-' while busy, 'E' on an error, the digit when done, blank before the first run.
  logic [4:0] code0;
  assign code0 = busy ? CODE_DASH
               : (done && error) ? CODE_E
               : done ? {1'b0, result[3:0]}
               : CODE_BLANK;

  hex7seg u_hex7seg_0 (.i_code(code0), .o_seg(HEX0));
  hex7seg u_hex7seg_1 (.i_code({1'b0, label}), .o_seg(HEX1));
  hex7seg u_hex7seg_2 (.i_code({1'b0, cyc_disp[3:0]}), .o_seg(HEX2));
  hex7seg u_hex7seg_3 (.i_code({1'b0, cyc_disp[7:4]}), .o_seg(HEX3));
  hex7seg u_hex7seg_4 (.i_code({1'b0, cyc_disp[11:8]}), .o_seg(HEX4));
  hex7seg u_hex7seg_5 (.i_code({1'b0, cyc_disp[15:12]}), .o_seg(HEX5));

  assign LEDR = {cyc_sat, 6'b0, error, done, busy};

endmodule
