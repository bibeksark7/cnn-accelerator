// Binds the shared unit contract (unit_if_sva) to argmax_unit (Verilator --assert runs only).
// The logit read port is the unit's source port; argmax writes no buffer.
bind argmax_unit unit_if_sva #(
    .CFG_W(2 * IDX_W),
    .RD_W (1),
    .WR_W (1)
) u_unit_if_sva (
    .clk     (clk),
    .rst     (rst),
    .i_start (i_start),
    .o_busy  (o_busy),
    .o_done  (o_done),
    .cfg     ({i_base, i_count}),
    .o_src_re(o_rd_en),
    .o_dst_we(1'b0),
    .rd      (1'b0),
    .wr      (1'b0)
);
