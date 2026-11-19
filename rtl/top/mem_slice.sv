// mem_slice: register stage on the memory port between the FPGA top's host side and accel_top.
//
// Front side: a request is accepted when i_valid && o_ready and is held in a register that
// drives accel_top's memory port (spec §10.3) until accel_top accepts it; o_ready is high only
// while the register is empty. accel_top's read return (o_mem_rvalid / o_mem_rdata) is
// registered once more and comes back as a one-cycle o_rvalid pulse. Every signal crossing the
// stage is a register output.
//
// Ports:
//   clk, rst                                        - clock, synchronous active-high reset
//   i_valid, o_ready, i_we, i_sel, i_addr, i_wdata,
//   o_rvalid, o_rdata                               - front side
//   o_mem_valid, i_mem_ready, o_mem_we, o_mem_sel, o_mem_addr, o_mem_wdata,
//   i_mem_rvalid, i_mem_rdata                       - accel_top memory port
//
// Latency: at least 1 cycle to accel_top; o_rvalid 1 cycle after accel_top's o_mem_rvalid.
module mem_slice (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_valid,
    output logic        o_ready,
    input  logic        i_we,
    input  logic [ 2:0] i_sel,
    input  logic [15:0] i_addr,
    input  logic [63:0] i_wdata,
    output logic        o_rvalid,
    output logic [63:0] o_rdata,
    output logic        o_mem_valid,
    input  logic        i_mem_ready,
    output logic        o_mem_we,
    output logic [ 2:0] o_mem_sel,
    output logic [15:0] o_mem_addr,
    output logic [63:0] o_mem_wdata,
    input  logic        i_mem_rvalid,
    input  logic [63:0] i_mem_rdata
);

  logic full_q, we_q, rvalid_q;
  logic [2:0] sel_q;
  logic [15:0] addr_q;
  logic [63:0] wdata_q, rdata_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      full_q   <= 1'b0;
      rvalid_q <= 1'b0;
    end else begin
      rvalid_q <= i_mem_rvalid;
      if (full_q && i_mem_ready) begin
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
      sel_q   <= i_sel;
      addr_q  <= i_addr;
      wdata_q <= i_wdata;
    end
    if (i_mem_rvalid) begin
      rdata_q <= i_mem_rdata;
    end
  end

  assign o_ready     = !full_q;
  assign o_rvalid    = rvalid_q;
  assign o_rdata     = rdata_q;
  assign o_mem_valid = full_q;
  assign o_mem_we    = we_q;
  assign o_mem_sel   = sel_q;
  assign o_mem_addr  = addr_q;
  assign o_mem_wdata = wdata_q;

endmodule
