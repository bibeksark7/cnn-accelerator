// gemm_engine: the array's result rows into the row register obey the valid/ready rule
// (valid_ready_sva); the row register -> postproc link is checked by postproc_vr_bind.sv.
bind gemm_engine valid_ready_sva #(
    .W(N * ACC_W + 1)
) u_rows_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (arr_row_valid),
    .ready  (arr_row_ready),
    .payload({arr_row_data, arr_row_last})
);
