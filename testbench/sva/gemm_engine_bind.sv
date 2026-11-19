// Binds the gemm_engine assertions (Verilator --assert runs only): the shared unit contract
// (unit_if_sva) and the engine's implementation properties (gemm_engine_impl_sva).
// Port expressions are evaluated in gemm_engine's scope, so D_IDLE is the engine's own enum value.
bind gemm_engine unit_if_sva #(
    .CFG_W(3 + 2 * ADDR_W + 5 * 8 + 16),
    .RD_W (2),
    .WR_W (1)
) u_unit_if_sva (
    .clk     (clk),
    .rst     (rst),
    .i_start (i_start),
    .o_busy  (o_busy),
    .o_done  (o_done),
    .cfg     ({
      i_fc,
      i_relu_en,
      i_requant_en,
      i_src_base,
      i_dst_base,
      i_h,
      i_w,
      i_c_in,
      i_c_out,
      i_wgt_base,
      i_param_base
    }),
    .o_src_re(o_src_re),
    .o_dst_we(o_dst_we),
    .rd      ({o_wgt_re, o_prm_re}),
    .wr      (o_logit_we)
);

bind gemm_engine gemm_engine_impl_sva #(
    .N     (N),
    .DATA_W(DATA_W)
) u_impl_sva (
    .clk          (clk),
    .rst          (rst),
    .i_fc         (i_fc),
    .o_dst_we     (o_dst_we),
    .o_logit_we   (o_logit_we),
    .arr_valid    (arr_valid),
    .arr_a        (arr_a),
    .mask_q       (mask_q),
    .load_start   (load_start),
    .load_busy_q  (load_busy_q),
    .wr_v_q       (wr_v_q),
    .load_done    (load_done),
    .stream_start (stream_start),
    .stream_busy_q(stream_busy_q),
    .step_v_q     (step_v_q),
    .drain_start  (drain_start),
    .drain_active (dstate_q != D_IDLE),
    .last_chunk   (last_chunk),
    .pp_valid     (pp_valid),
    .pp_ready     (pp_ready),
    .pp_out_ready (u_postproc.i_ready)
);
