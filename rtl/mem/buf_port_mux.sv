// buf_port_mux: connects one of several requesters ("owners") to a buffer's read and write ports.
//
// Each §5 buffer (IMG, ACT0, ACT1, WGT, PARAM) has one read port and one write port, and several
// possible users: the host memory port (only while idle), the GEMM engine and the pool unit. The
// layer sequencer decides who owns each buffer and drives i_owner (one-hot, or all zero for no
// owner). Only the owner's requests reach the RAM; requests from other inputs are ignored. Read
// data is not multiplexed: the RAM's o_rdata goes to every requester, and only the owner uses it.
//
// One owner covers both ports because a layer never reads and writes the same buffer (spec §9).
//
// Parameters:
//   NUM_OWNERS - number of requesters
//   WIDTH      - data width
//   AW         - address width
//
// Ports:
//   i_owner                      - one-hot owner select (all zero: no owner)
//   i_re, i_raddr                - per-owner read requests (owner k at [k*AW +: AW])
//   i_we, i_waddr, i_wdata       - per-owner write requests
//   o_re, o_raddr                - to the RAM read port
//   o_we, o_waddr, o_wdata       - to the RAM write port
//
// Latency: combinational (the RAM adds its own 1-cycle read latency).
module buf_port_mux #(
    parameter int NUM_OWNERS = 3,
    parameter int WIDTH      = 8,
    parameter int AW         = 13
) (
    input  logic [   NUM_OWNERS-1:0] i_owner,
    input  logic [   NUM_OWNERS-1:0] i_re,
    input  logic [NUM_OWNERS*AW-1:0] i_raddr,
    input  logic [   NUM_OWNERS-1:0] i_we,
    input  logic [NUM_OWNERS*AW-1:0] i_waddr,
    input  logic [NUM_OWNERS*WIDTH-1:0] i_wdata,
    output logic                     o_re,
    output logic [           AW-1:0] o_raddr,
    output logic                     o_we,
    output logic [           AW-1:0] o_waddr,
    output logic [        WIDTH-1:0] o_wdata
);

  // AND-OR multiplexer: with a one-hot (or zero) owner, exactly the owner's fields pass.
  always_comb begin
    o_re    = 1'b0;
    o_raddr = '0;
    o_we    = 1'b0;
    o_waddr = '0;
    o_wdata = '0;
    for (int k = 0; k < NUM_OWNERS; k++) begin
      o_re    = o_re | (i_owner[k] & i_re[k]);
      o_raddr = o_raddr | (i_raddr[k*AW+:AW] & {AW{i_owner[k]}});
      o_we    = o_we | (i_owner[k] & i_we[k]);
      o_waddr = o_waddr | (i_waddr[k*AW+:AW] & {AW{i_owner[k]}});
      o_wdata = o_wdata | (i_wdata[k*WIDTH+:WIDTH] & {WIDTH{i_owner[k]}});
    end
  end

endmodule
