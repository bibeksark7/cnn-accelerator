// accel_top_if_sva: handshake assertions on accel_top's host interfaces (spec §10.1, §10.3).
// Bound by accel_top_bind.sv (Verilator --assert runs only). Uses only accel_top ports.
//
// Master obligations (the CSR and memory-port masters, i.e. the testbench or the FPGA top):
//   a_csr_req_stable        once i_csr_valid is high, it stays high with i_csr_we, i_csr_addr and
//                           i_csr_wdata unchanged until the request is accepted (o_csr_ready)
//   a_mem_req_stable        once i_mem_valid is high, it stays high with i_mem_we, i_mem_sel,
//                           i_mem_addr and i_mem_wdata unchanged until accepted (o_mem_ready)
// Slave obligations (accel_top):
//   a_mem_rvalid_pulse      o_mem_rvalid is a one-cycle pulse (there is no backpressure on it)
//   a_mem_rvalid_for_read   o_mem_rvalid only while an accepted read has not returned yet
//   a_mem_one_read          a read is accepted only when no earlier read is still outstanding
//                           (or it returns in that same cycle)
//   a_mem_not_ready_busy    o_mem_ready is low while BUSY
// A reset drops an outstanding read (no o_mem_rvalid follows); the tracker is reset with it.
module accel_top_if_sva (
    input logic        clk,
    input logic        rst,
    input logic        i_csr_valid,
    input logic        i_csr_we,
    input logic [11:0] i_csr_addr,
    input logic [31:0] i_csr_wdata,
    input logic        o_csr_ready,
    input logic        i_mem_valid,
    input logic        o_mem_ready,
    input logic        i_mem_we,
    input logic [ 2:0] i_mem_sel,
    input logic [15:0] i_mem_addr,
    input logic [63:0] i_mem_wdata,
    input logic        o_mem_rvalid,
    input logic        o_busy
);

  // Outstanding-read tracker: set by an accepted read, cleared by its o_mem_rvalid.
  logic mem_rd_accept, rd_out_q;
  assign mem_rd_accept = i_mem_valid && o_mem_ready && !i_mem_we;

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_out_q <= 1'b0;
    end else if (mem_rd_accept) begin
      rd_out_q <= 1'b1;
    end else if (o_mem_rvalid) begin
      rd_out_q <= 1'b0;
    end
  end

  a_csr_req_stable :
  assert property (@(posedge clk) disable iff (rst)
      (i_csr_valid && !o_csr_ready)
      |=> (i_csr_valid && $stable({i_csr_we, i_csr_addr, i_csr_wdata})));

  a_mem_req_stable :
  assert property (@(posedge clk) disable iff (rst)
      (i_mem_valid && !o_mem_ready)
      |=> (i_mem_valid && $stable({i_mem_we, i_mem_sel, i_mem_addr, i_mem_wdata})));

  a_mem_rvalid_pulse :
  assert property (@(posedge clk) disable iff (rst) o_mem_rvalid |=> !o_mem_rvalid);

  a_mem_rvalid_for_read :
  assert property (@(posedge clk) disable iff (rst) o_mem_rvalid |-> rd_out_q);

  a_mem_one_read :
  assert property (@(posedge clk) disable iff (rst) mem_rd_accept |-> (!rd_out_q || o_mem_rvalid));

  a_mem_not_ready_busy :
  assert property (@(posedge clk) disable iff (rst) o_busy |-> !o_mem_ready);

endmodule
