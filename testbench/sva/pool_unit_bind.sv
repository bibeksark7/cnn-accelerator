// Binds the shared unit contract (unit_if_sva) to pool_unit (Verilator --assert runs only).
bind pool_unit unit_if_sva #(
    .CFG_W(2 * ADDR_W + 3 * DIM_W),
    .RD_W (1),
    .WR_W (1)
) u_unit_if_sva (
    .clk     (clk),
    .rst     (rst),
    .i_start (i_start),
    .o_busy  (o_busy),
    .o_done  (o_done),
    .cfg     ({i_src_base, i_dst_base, i_h, i_w, i_c}),
    .o_src_re(o_src_re),
    .o_dst_we(o_dst_we),
    .rd      (1'b0),
    .wr      (1'b0)
);
