// sram_be: inferred block RAM with byte write enables, one write port and one synchronous read
// port (the SoC RAM, spec §13.5).
//
// Word w holds bytes 4w .. 4w+3 of the byte address space, byte l in bits [8l+7 : 8l]
// (little-endian); the init file has one hex word per line, word 0 first.
//
// Parameters:
//   WORDS     - number of words
//   LANES     - bytes per word
//   INIT_FILE - optional $readmemh file ("" = none); the initial block exists only when given
//
// Ports:
//   clk     - clock (no reset: contents survive rst, spec §13.1)
//   i_we    - write enable
//   i_be    - byte enables (lane l written when i_we && i_be[l])
//   i_waddr - write word address
//   i_wdata - write data
//   i_re    - read enable
//   i_raddr - read word address
//   o_rdata - read data: mem[i_raddr] one cycle after i_re; holds its value while i_re is low
//
// Latency: 1 cycle from i_re to o_rdata. A read and a write of the same word in the same cycle
// return unspecified data; the SoC never does this (one bus transaction at a time).
module sram_be #(
    parameter int WORDS     = 1024,
    parameter int LANES     = 4,
    parameter     INIT_FILE = ""
) (
    input  logic                     clk,
    input  logic                     i_we,
    input  logic [        LANES-1:0] i_be,
    input  logic [$clog2(WORDS)-1:0] i_waddr,
    input  logic [      8*LANES-1:0] i_wdata,
    input  logic                     i_re,
    input  logic [$clog2(WORDS)-1:0] i_raddr,
    output logic [      8*LANES-1:0] o_rdata
);

  // Quartus: byte-enabled M9K (packed byte lanes); no_rw_check as in sram_1r1w.
  (* ramstyle = "M9K, no_rw_check" *) logic [LANES-1:0][7:0] mem[0:WORDS-1];

  generate
    if (INIT_FILE != "") begin : g_init
      initial begin
        $readmemh(INIT_FILE, mem);
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (i_we) begin
      for (int l = 0; l < LANES; l++) begin
        if (i_be[l]) mem[i_waddr][l] <= i_wdata[8*l+:8];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (i_re) begin
      o_rdata <= mem[i_raddr];
    end
  end

endmodule
