// csr_slice: register stage on the CSR bus between the FPGA top's masters and accel_top.
//
// Front side (master): a request is accepted when i_valid && o_ready and is held in a register
// that drives accel_top's CSR bus (spec §10.1) until accel_top accepts it; o_ready is high only
// while the register is empty, so requests are handled one at a time and in order. A read's data
// returns on o_rdata with a one-cycle o_rvalid pulse after accel_top accepts the read; a write
// has no response. Every signal crossing the stage is a register output, which takes the CSR
// decode out of the masters' timing paths.
//
// Ports:
//   clk, rst                                    - clock, synchronous active-high reset
//   i_valid, o_ready, i_we, i_addr, i_wdata,
//   o_rvalid, o_rdata                           - front side
//   o_csr_valid, i_csr_ready, o_csr_we, o_csr_addr, o_csr_wdata, i_csr_rdata - accel_top CSR bus
//
// Latency: at least 1 cycle from acceptance to accel_top; o_rvalid 1 cycle after accel_top
// accepts a read.
module csr_slice (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_valid,
    output logic        o_ready,
    input  logic        i_we,
    input  logic [11:0] i_addr,
    input  logic [31:0] i_wdata,
    output logic        o_rvalid,
    output logic [31:0] o_rdata,
    output logic        o_csr_valid,
    input  logic        i_csr_ready,
    output logic        o_csr_we,
    output logic [11:0] o_csr_addr,
    output logic [31:0] o_csr_wdata,
    input  logic [31:0] i_csr_rdata
);

  logic full_q, we_q, rvalid_q;
  logic [11:0] addr_q;
  logic [31:0] wdata_q, rdata_q;
  logic done;
  assign done = full_q && i_csr_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      full_q   <= 1'b0;
      rvalid_q <= 1'b0;
    end else begin
      rvalid_q <= done && !we_q;
      if (done) begin
        full_q <= 1'b0;
      end else if (i_valid && !full_q) begin
        full_q <= 1'b1;
      end
    end
  end

  // Request and response registers (no reset: used only with full_q / rvalid_q).
  always_ff @(posedge clk) begin
    if (i_valid && !full_q) begin
      we_q    <= i_we;
      addr_q  <= i_addr;
      wdata_q <= i_wdata;
    end
    if (done && !we_q) begin
      rdata_q <= i_csr_rdata;
    end
  end

  assign o_ready     = !full_q;
  assign o_rvalid    = rvalid_q;
  assign o_rdata     = rdata_q;
  assign o_csr_valid = full_q;
  assign o_csr_we    = we_q;
  assign o_csr_addr  = addr_q;
  assign o_csr_wdata = wdata_q;

endmodule
