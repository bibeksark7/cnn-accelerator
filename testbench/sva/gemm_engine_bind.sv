// Binds the gemm_engine assertions (Verilator --assert runs only): interface properties
// (gemm_engine_if_sva) and implementation properties (gemm_engine_impl_sva).
bind gemm_engine gemm_engine_if_sva #(
    .ADDR_W(ADDR_W)
) u_if_sva (
    .clk         (clk),
    .rst         (rst),
    .i_start     (i_start),
    .o_busy      (o_busy),
    .o_done      (o_done),
    .i_fc        (i_fc),
    .i_relu_en   (i_relu_en),
    .i_requant_en(i_requant_en),
    .i_src_base  (i_src_base),
    .i_dst_base  (i_dst_base),
    .i_h         (i_h),
    .i_w         (i_w),
    .i_c_in      (i_c_in),
    .i_c_out     (i_c_out),
    .i_wgt_base  (i_wgt_base),
    .i_param_base(i_param_base),
    .o_src_re    (o_src_re),
    .o_wgt_re    (o_wgt_re),
    .o_prm_re    (o_prm_re),
    .o_dst_we    (o_dst_we),
    .o_logit_we  (o_logit_we)
);

// Implementation assertions (engine-internal signals).
bind gemm_engine gemm_engine_impl_sva #(
    .N     (N),
    .DATA_W(DATA_W)
) u_impl_sva (
    .clk          (clk),
    .rst          (rst),
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
    .dstate_q     (dstate_q),
    .last_chunk   (last_chunk)
);
