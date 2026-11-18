// Binds the buffer ownership assertions into the unit-test harness (Verilator --assert runs only).
bind buf_port_mux_tb buf_port_mux_sva #(
    .NUM_OWNERS(NUM_OWNERS)
) u_sva (
    .clk    (clk),
    .rst    (rst),
    .i_owner(i_owner),
    .i_re   (i_re),
    .i_we   (i_we)
);
