// unit_if_sva: start/busy/done and buffer-access contract shared by the layer units
// (gemm_engine, pool_unit, argmax_unit). Bound to each by its *_bind.sv file. Simulation-only
// (Verilator --assert); Icarus does not support concurrent assertions.
//
// A unit is started with a one-cycle i_start while idle, holds o_busy until it is finished,
// pulses o_done in its last busy cycle, and touches no buffer port while idle. Its configuration
// inputs are held stable by the layer sequencer while it is busy.
//
// Parameters:
//   CFG_W - width of the concatenated configuration inputs (cfg)
//   RD_W  - number of other read enables (rd); tie unused bits to 0
//   WR_W  - number of other write enables (wr); tie unused bits to 0
//
// Producer (layer sequencer) obligations:
//   a_start_only_when_idle   i_start only while o_busy is low
//   a_cfg_stable_while_busy  cfg does not change while busy
// Unit obligations:
//   a_done_is_pulse          o_done lasts one cycle
//   a_done_ends_busy         o_busy is low the cycle after o_done
//   a_done_only_when_busy    o_done only while o_busy
//   a_busy_ends_with_done    o_busy only falls right after o_done (or because of a reset: a
//                            one-cycle reset clears o_busy without a done pulse)
//   a_quiet_when_idle        no read or write of any port while idle
//   a_src_re_only_busy       o_src_re |-> o_busy (the main source read port)
//   a_dst_we_only_busy       o_dst_we |-> o_busy (the main destination write port)
module unit_if_sva #(
    parameter int CFG_W = 1,
    parameter int RD_W  = 1,
    parameter int WR_W  = 1
) (
    input logic             clk,
    input logic             rst,
    input logic             i_start,
    input logic             o_busy,
    input logic             o_done,
    input logic [CFG_W-1:0] cfg,
    input logic             o_src_re,
    input logic             o_dst_we,
    input logic [ RD_W-1:0] rd,
    input logic [ WR_W-1:0] wr
);

  a_start_only_when_idle :
  assert property (@(posedge clk) disable iff (rst) i_start |-> !o_busy);

  a_cfg_stable_while_busy :
  assert property (@(posedge clk) disable iff (rst) (o_busy && $past(o_busy)) |-> $stable(cfg));

  a_done_is_pulse :
  assert property (@(posedge clk) disable iff (rst) o_done |=> !o_done);

  a_done_ends_busy :
  assert property (@(posedge clk) disable iff (rst) o_done |=> !o_busy);

  a_done_only_when_busy :
  assert property (@(posedge clk) disable iff (rst) o_done |-> o_busy);

  a_busy_ends_with_done :
  assert property (@(posedge clk) disable iff (rst)
      ($fell(o_busy) && !$past(rst)) |-> $past(o_done));

  a_quiet_when_idle :
  assert property (@(posedge clk) disable iff (rst)
      !o_busy |-> !(o_src_re || o_dst_we || (|rd) || (|wr)));

  a_src_re_only_busy :
  assert property (@(posedge clk) disable iff (rst) o_src_re |-> o_busy);

  a_dst_we_only_busy :
  assert property (@(posedge clk) disable iff (rst) o_dst_we |-> o_busy);

endmodule
