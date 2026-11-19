// gemm_engine_impl_sva: implementation assertions for rtl/core/gemm_engine.sv.
//
// Refers to engine-internal signals, so it is specific to this implementation. Bound by
// gemm_engine_bind.sv, which also binds the shared unit contract (unit_if_sva). Simulation-only
// (Verilator --assert).
//
//   a_write_port_matches      CONV writes only activations, FC writes only logits
//   a_padded_rows_zero        every array step presents 0 on the A lanes of padded rows
//                             (rows outside the tile's row mask; spec §5)
//   a_load_starts_idle        the A-load block starts only when it is idle
//   a_stream_starts_idle      the stream block starts only when it is idle
//   a_drain_starts_idle       the drain block starts only when it is idle
//   a_stream_after_load_done  streaming starts only on the cycle the chunk's last byte is staged
//   a_drain_after_last_chunk  the drain starts only after the last K chunk of an output tile
//   a_one_block_active        at most one of A-load, stream and drain is active (v1.0 schedule)
//   a_pp_out_never_stalled    postproc's output is never backpressured: its i_ready is high (the
//                             write ports accept a write every cycle)
//   a_pp_in_never_stalled     so the row register never waits for postproc: pp_valid |-> pp_ready
// (the two engine-internal stalls the coverage report lists as unreachable)
module gemm_engine_impl_sva #(
    parameter int N      = 8,
    parameter int DATA_W = 8
) (
    input logic                clk,
    input logic                rst,
    input logic                i_fc,
    input logic                o_dst_we,
    input logic                o_logit_we,
    input logic                arr_valid,
    input logic [N*DATA_W-1:0] arr_a,
    input logic [       N-1:0] mask_q,
    input logic                load_start,
    input logic                load_busy_q,
    input logic                wr_v_q,
    input logic                load_done,
    input logic                stream_start,
    input logic                stream_busy_q,
    input logic                step_v_q,
    input logic                drain_start,
    input logic                drain_active,  // drain FSM not in D_IDLE (bound in engine scope)
    input logic                last_chunk,
    input logic                pp_valid,
    input logic                pp_ready,
    input logic                pp_out_ready  // postproc's i_ready (tied high in the engine)
);

  // Lanes of padded rows: all DATA_W bits of lane i set when mask_q[i] is low.
  logic [N*DATA_W-1:0] padded_lanes;
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_lane
      assign padded_lanes[gi*DATA_W+:DATA_W] = {DATA_W{!mask_q[gi]}};
    end
  endgenerate

  logic load_active, stream_active;
  assign load_active   = load_busy_q || wr_v_q;
  assign stream_active = stream_busy_q || step_v_q;

  a_write_port_matches :
  assert property (@(posedge clk) disable iff (rst) !(o_dst_we && i_fc) && !(o_logit_we && !i_fc));

  a_padded_rows_zero :
  assert property (@(posedge clk) disable iff (rst) arr_valid |-> ((arr_a & padded_lanes) == '0));

  a_load_starts_idle :
  assert property (@(posedge clk) disable iff (rst) load_start |-> !load_active);

  a_stream_starts_idle :
  assert property (@(posedge clk) disable iff (rst) stream_start |-> !stream_active);

  a_drain_starts_idle :
  assert property (@(posedge clk) disable iff (rst) drain_start |-> !drain_active);

  a_stream_after_load_done :
  assert property (@(posedge clk) disable iff (rst) stream_start |-> load_done);

  a_drain_after_last_chunk :
  assert property (@(posedge clk) disable iff (rst) drain_start |-> last_chunk);

  a_one_block_active :
  assert property (@(posedge clk) disable iff (rst)
      $onehot0({load_active, stream_active, drain_active}));

  a_pp_out_never_stalled :
  assert property (@(posedge clk) disable iff (rst) pp_out_ready);

  a_pp_in_never_stalled :
  assert property (@(posedge clk) disable iff (rst) pp_valid |-> pp_ready);

endmodule
