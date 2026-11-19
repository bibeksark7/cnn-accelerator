// postproc's two links obey the valid/ready rule (valid_ready_sva): the input (the producer's
// obligation: in gemm_engine, the row register) and the output (postproc's obligation).
bind postproc valid_ready_sva #(
    .W(2 * ACC_W + 16 + 6 + 2 + TAG_W)
) u_in_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_valid),
    .ready  (o_ready),
    .payload({i_acc, i_bias, i_m, i_s, i_requant_en, i_relu_en, i_tag})
);

bind postproc valid_ready_sva #(
    .W(8 + ACC_W + TAG_W)
) u_out_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_valid),
    .ready  (i_ready),
    .payload({o_q8, o_y, o_tag})
);
