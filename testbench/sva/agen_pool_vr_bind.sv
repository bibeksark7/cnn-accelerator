// agen_pool's window stream (o_valid / i_ready) obeys the valid/ready rule (valid_ready_sva).
bind agen_pool valid_ready_sva #(
    .W(2 * $bits(o_addr) + 3)
) u_out_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_valid),
    .ready  (i_ready),
    .payload({o_addr, o_first, o_last, o_dst, o_end})
);
