// Binds the accel_top assertions (Verilator --assert runs only): scheduling and ownership
// (accel_top_sva), the host-interface handshakes (accel_top_if_sva) and one buf_port_mux_sva per
// buffer multiplexer, sampled on accel_top's clock.
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
    .mem_we      (mem_we),
    .src         (src),
    .dst         (dst)
);

bind accel_top accel_top_if_sva u_accel_top_if_sva (
    .clk         (clk),
    .rst         (rst),
    .i_csr_valid (i_csr_valid),
    .i_csr_we    (i_csr_we),
    .i_csr_addr  (i_csr_addr),
    .i_csr_wdata (i_csr_wdata),
    .o_csr_ready (o_csr_ready),
    .i_mem_valid (i_mem_valid),
    .o_mem_ready (o_mem_ready),
    .i_mem_we    (i_mem_we),
    .i_mem_sel   (i_mem_sel),
    .i_mem_addr  (i_mem_addr),
    .i_mem_wdata (i_mem_wdata),
    .o_mem_rvalid(o_mem_rvalid),
    .o_busy      (o_busy)
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
