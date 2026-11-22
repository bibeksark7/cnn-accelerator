// de10lite_soc_top: the RISC-V SoC on the DE10-Lite (spec §13.7). Port names are Terasic's.
//
//   MAX10_CLK1_50  50 MHz clock (the only clock)
//   KEY[1]         reset (active low), OR'd with a power-on reset (reset_gen); the RAM and the
//                  accelerator's buffers keep their contents, the firmware restarts
//   KEY[0]         synchronized and debounced: level -> GPIO KEY, press pulse -> GPIO KEY_EVT
//   SW[9:0]        synchronized -> GPIO SW
//   HEX5..HEX0     hex7seg of the six GPIO HEX codes (segments active low, decimal points off)
//   LEDR[8:0]      GPIO LEDR
//   LEDR[9]        the CPU has trapped (a firmware fault), straight from soc_top
// What the displays show is the firmware's choice (the demo firmware: spec §13.8).
//
// Parameters:
//   RAM_INIT                                  - firmware image (fpga/de10lite_soc/build.tcl)
//   IMG_INIT, WGT_INIT, PARAM_INIT, DESC_INIT - accelerator init files (model/artifacts/mem)
//   POR_CYCLES                                - power-on reset length (cycles)
//   DEBOUNCE_W                                - KEY[0] debounce: 2^DEBOUNCE_W stable cycles
//
// Latency: not applicable (a board top).
module de10lite_soc_top #(
    parameter     RAM_INIT   = "",
    parameter     IMG_INIT   = "",
    parameter     WGT_INIT   = "",
    parameter     PARAM_INIT = "",
    parameter     DESC_INIT  = "",
    parameter int POR_CYCLES = 256,
    parameter int DEBOUNCE_W = 20
) (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    input  logic [9:0] SW,
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
  logic [9:0] sw_sync;
  logic key0_n, key0_level_n, key0_press;

  sync_2ff #(
      .W    (10),
      .RESET(0)
  ) u_sync_2ff_sw (
      .clk    (clk),
      .rst    (rst),
      .i_async(SW),
      .o_sync (sw_sync)
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

  debounce #(
      .CNT_W(DEBOUNCE_W)
  ) u_debounce_key0 (
      .clk      (clk),
      .rst      (rst),
      .i_key_n  (key0_n),
      .o_level_n(key0_level_n),
      .o_press  (key0_press)
  );

  // ---------------------------------------------------------------- SoC
  logic [8:0] gpio_ledr;
  logic [29:0] hex_code;
  logic trap;
  // Lint waiver: MAILBOX is the simulation tests' observation point; not connected on the board.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] mailbox_word;
  /* verilator lint_on UNUSEDSIGNAL */

  soc_top #(
      .RAM_INIT  (RAM_INIT),
      .IMG_INIT  (IMG_INIT),
      .WGT_INIT  (WGT_INIT),
      .PARAM_INIT(PARAM_INIT),
      .DESC_INIT (DESC_INIT)
  ) u_soc_top (
      .clk        (clk),
      .rst        (rst),
      .i_sw       (sw_sync),
      .i_key_level(!key0_level_n),
      .i_key_press(key0_press),
      .o_ledr     (gpio_ledr),
      .o_hex_code (hex_code),
      .o_mailbox  (mailbox_word),
      .o_trap     (trap)
  );

  // ---------------------------------------------------------------- outputs
  logic [5:0][7:0] hex_seg;  // hex_seg[d]: the segments of HEXd
  genvar d;
  generate
    for (d = 0; d < 6; d++) begin : g_hex
      hex7seg u_hex7seg (
          .i_code(hex_code[5*d+:5]),
          .o_seg (hex_seg[d])
      );
    end
  endgenerate

  assign HEX0 = hex_seg[0];
  assign HEX1 = hex_seg[1];
  assign HEX2 = hex_seg[2];
  assign HEX3 = hex_seg[3];
  assign HEX4 = hex_seg[4];
  assign HEX5 = hex_seg[5];
  assign LEDR = {trap, gpio_ledr};

endmodule
