// Binds the gemm_engine interface assertions (Verilator --assert runs only).
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
