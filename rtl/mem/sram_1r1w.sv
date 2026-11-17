// sram_1r1w: inferred block RAM with one write port and one synchronous read port (spec §5).
//
// Parameters:
//   WIDTH     - word width in bits
//   DEPTH     - number of words
//   INIT_FILE - optional $readmemh file loaded at configuration/start of simulation ("" = none);
//               the initial block exists only when a file is given
//
// Ports:
//   clk     - clock (no reset: contents survive rst, spec §10.2)
//   i_we    - write enable
//   i_waddr - write address
//   i_wdata - write data
//   i_re    - read enable
//   i_raddr - read address
//   o_rdata - read data: mem[i_raddr] one cycle after i_re; holds its value while i_re is low
//
// Latency: exactly 1 cycle from i_re to o_rdata (part of the buffer interface, spec §5).
// A read and a write to the same address in the same cycle return unspecified data; the
// design never does this (a layer never reads and writes the same buffer).
module sram_1r1w #(
    parameter int WIDTH     = 8,
    parameter int DEPTH     = 1024,
    parameter     INIT_FILE = ""
) (
    input  logic                     clk,
    input  logic                     i_we,
    input  logic [$clog2(DEPTH)-1:0] i_waddr,
    input  logic [        WIDTH-1:0] i_wdata,
    input  logic                     i_re,
    input  logic [$clog2(DEPTH)-1:0] i_raddr,
    output logic [        WIDTH-1:0] o_rdata
);

  // Quartus: map to M9K blocks. no_rw_check drops the read-during-write bypass logic, which is
  // safe because the design never reads and writes the same address in one cycle.
  (* ramstyle = "M9K, no_rw_check" *) logic [WIDTH-1:0] mem[0:DEPTH-1];

  // Explicit generate/endgenerate: Quartus Prime Lite 22.1 rejects a bare generate-if here.
  generate
    if (INIT_FILE != "") begin : g_init
      initial begin
        $readmemh(INIT_FILE, mem);
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (i_we) begin
      mem[i_waddr] <= i_wdata;
    end
  end

  always_ff @(posedge clk) begin
    if (i_re) begin
      o_rdata <= mem[i_raddr];
    end
  end

endmodule
