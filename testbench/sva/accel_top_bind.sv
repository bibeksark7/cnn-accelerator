// Binds the accel_top assertions (Verilator --assert runs only): scheduling and ownership
// (accel_top_sva) and one buf_port_mux_sva per buffer multiplexer, sampled on accel_top's clock.
// The unit, engine and array assertions are bound by their own bind files.
bind accel_top accel_top_sva u_accel_top_sva (
    .clk         (clk),
    .rst         (rst),
    .own_img     (own_img),
    .own_act0    (own_act0),
    .own_act1    (own_act1),
    .own_wgt     (own_wgt),
    .own_prm     (own_prm),
    .gemm_busy   (gemm_busy),
    .pool_busy   (pool_busy),
    .argmax_busy (argmax_busy),
    .gemm_start  (gemm_start),
    .pool_start  (pool_start),
    .argmax_start(argmax_start),
    .seq_busy    (seq_busy),
    .mem_re      (mem_re),
    .mem_we      (mem_we)
);

bind accel_top buf_port_mux_sva #(
    .NUM_OWNERS(3)
) u_img_mux_sva (
    .clk    (clk),
    .rst    (rst),
    .i_owner(own_img),
    .i_re   (img_req_re),
    .i_we   (img_req_we)
);

bind accel_top buf_port_mux_sva #(
    .NUM_OWNERS(3)
) u_act0_mux_sva (
    .clk    (clk),
    .rst    (rst),
    .i_owner(own_act0),
    .i_re   (act0_req_re),
    .i_we   (act0_req_we)
);

bind accel_top buf_port_mux_sva #(
    .NUM_OWNERS(3)
) u_act1_mux_sva (
    .clk    (clk),
    .rst    (rst),
    .i_owner(own_act1),
    .i_re   (act1_req_re),
    .i_we   (act1_req_we)
);

bind accel_top buf_port_mux_sva #(
    .NUM_OWNERS(2)
) u_wgt_mux_sva (
    .clk    (clk),
    .rst    (rst),
    .i_owner(own_wgt),
    .i_re   (wgt_req_re),
    .i_we   (wgt_req_we)
);

bind accel_top buf_port_mux_sva #(
    .NUM_OWNERS(2)
) u_prm_mux_sva (
    .clk    (clk),
    .rst    (rst),
    .i_owner(own_prm),
    .i_re   (prm_req_re),
    .i_we   (prm_req_we)
);
