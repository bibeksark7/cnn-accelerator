// Binds the systolic_array assertions (Verilator --assert runs only):
//   systolic_array_if_sva  interface properties (reusable for any implementation)
//   systolic_array_os_sva  output-stationary implementation properties
bind systolic_array systolic_array_if_sva #(
    .N    (N),
    .ACC_W(ACC_W)
) u_if_sva (
    .clk        (clk),
    .rst        (rst),
    .i_clear    (i_clear),
    .i_valid    (i_valid),
    .i_drain    (i_drain),
    .o_row_valid(o_row_valid),
    .i_row_ready(i_row_ready),
    .o_row_data (o_row_data),
    .o_row_last (o_row_last),
    .o_idle     (o_idle)
);

bind systolic_array systolic_array_os_sva #(
    .N(N)
) u_os_sva (
    .clk     (clk),
    .rst     (rst),
    .o_idle  (o_idle),
    .pe_v_out(pe_v_out),
    .v_dly_q (v_dly_q)
);
