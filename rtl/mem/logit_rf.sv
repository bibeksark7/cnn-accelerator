// logit_rf: the LOGIT register file (spec §5): FC outputs, read by the argmax unit and the CSRs.
//
// Registers, not a RAM: the CSR block reads any entry combinationally (LOGIT[i], spec §10.2),
// while the argmax unit reads through a registered port with the 1-cycle latency of the buffers
// (docs/decisions.md D-028). Reset clears every entry (the CSR reset value is 0).
//
// Parameters:
//   DEPTH - number of entries (spec LOGIT_DEPTH; a power of two, so indices wrap)
//   WIDTH - entry width (int32 logits)
//
// Ports:
//   clk, rst                  - clock, synchronous active-high reset (clears all entries)
//   i_we, i_waddr, i_wdata    - write port (GEMM engine, FC layers)
//   i_re, i_raddr, o_rdata    - registered read port: o_rdata = entry one cycle after i_re,
//                               held while i_re is low (argmax unit)
//   i_csr_raddr, o_csr_rdata  - combinational read port (CSR block)
//
// Latency: write takes effect at the next edge; o_rdata 1 cycle; o_csr_rdata combinational.
module logit_rf #(
    parameter int DEPTH = 16,
    parameter int WIDTH = 32
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     i_we,
    input  logic [$clog2(DEPTH)-1:0] i_waddr,
    input  logic [        WIDTH-1:0] i_wdata,
    input  logic                     i_re,
    input  logic [$clog2(DEPTH)-1:0] i_raddr,
    output logic [        WIDTH-1:0] o_rdata,
    input  logic [$clog2(DEPTH)-1:0] i_csr_raddr,
    output logic [        WIDTH-1:0] o_csr_rdata
);

  logic [WIDTH-1:0] regs_q[DEPTH];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < DEPTH; i++) begin
        regs_q[i] <= '0;
      end
    end else if (i_we) begin
      regs_q[i_waddr] <= i_wdata;
    end
  end

  always_ff @(posedge clk) begin
    if (i_re) begin
      o_rdata <= regs_q[i_raddr];
    end
  end

  assign o_csr_rdata = regs_q[i_csr_raddr];

endmodule
