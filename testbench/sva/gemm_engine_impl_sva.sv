// gemm_engine_impl_sva: implementation assertions for rtl/core/gemm_engine.sv.
//
// Refers to engine-internal signals, so it is specific to this implementation. Bound by
// gemm_engine_bind.sv. Simulation-only (Verilator --assert).
//
//   a_padded_rows_zero        every array step presents 0 on the A lanes of padded rows
//                             (rows outside the tile's row mask; spec §5)
//   a_load_starts_idle        the A-load block starts only when it is idle
//   a_stream_starts_idle      the stream block starts only when it is idle
//   a_drain_starts_idle       the drain block starts only when it is idle
//   a_stream_after_load_done  streaming starts only on the cycle the chunk's last byte is staged
//   a_drain_after_last_chunk  the drain starts only after the last K chunk of an output tile
//   a_one_block_active        at most one of A-load, stream and drain is active (v1.0 schedule)
module gemm_engine_impl_sva #(
    parameter int N      = 8,
    parameter int DATA_W = 8
) (
    input logic                clk,
    input logic                rst,
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
    input logic [         2:0] dstate_q,
    input logic                last_chunk
);

  localparam logic [2:0] D_IDLE = 3'd0;  // must match gemm_engine's dstate_t encoding

  // Lanes of padded rows: all DATA_W bits of lane i set when mask_q[i] is low.
  logic [N*DATA_W-1:0] padded_lanes;
  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_lane
      assign padded_lanes[gi*DATA_W+:DATA_W] = {DATA_W{!mask_q[gi]}};
    end
  endgenerate

  logic load_active, stream_active, drain_active;
  assign load_active   = load_busy_q || wr_v_q;
  assign stream_active = stream_busy_q || step_v_q;
  assign drain_active  = (dstate_q != D_IDLE);

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

endmodule
