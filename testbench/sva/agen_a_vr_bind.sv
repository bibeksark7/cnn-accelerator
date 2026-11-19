// agen_a's address stream (o_valid / i_ready) obeys the valid/ready rule (valid_ready_sva).
bind agen_a valid_ready_sva #(
    .W($bits(o_addr) + $bits(o_bank) + $bits(o_kpos) + 1)
) u_out_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_valid),
    .ready  (i_ready),
    .payload({o_addr, o_bank, o_kpos, o_last})
);
