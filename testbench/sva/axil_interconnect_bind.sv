// Binds the AXI4-Lite checks to the interconnect's master-side port (Verilator --assert runs):
// valid_ready_sva on the five channels (AW, W, AR: the master's obligation; B, R: the
// interconnect's) and axil_resp_order_sva on the response order. The slave-side links are
// checked by each slave's own axil_slave_port bind.
bind axil_interconnect valid_ready_sva #(
    .W(32)
) u_aw_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_s_awvalid),
    .ready  (o_s_awready),
    .payload(i_s_awaddr)
);

bind axil_interconnect valid_ready_sva #(
    .W(36)
) u_w_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_s_wvalid),
    .ready  (o_s_wready),
    .payload({i_s_wstrb, i_s_wdata})
);

bind axil_interconnect valid_ready_sva #(
    .W(2)
) u_b_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_s_bvalid),
    .ready  (i_s_bready),
    .payload(o_s_bresp)
);

bind axil_interconnect valid_ready_sva #(
    .W(32)
) u_ar_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_s_arvalid),
    .ready  (o_s_arready),
    .payload(i_s_araddr)
);

bind axil_interconnect valid_ready_sva #(
    .W(34)
) u_r_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_s_rvalid),
    .ready  (i_s_rready),
    .payload({o_s_rresp, o_s_rdata})
);

bind axil_interconnect axil_resp_order_sva u_order_sva (
    .clk    (clk),
    .rst    (rst),
    .awvalid(i_s_awvalid),
    .awready(o_s_awready),
    .wvalid (i_s_wvalid),
    .wready (o_s_wready),
    .bvalid (o_s_bvalid),
    .bready (i_s_bready),
    .arvalid(i_s_arvalid),
    .arready(o_s_arready),
    .rvalid (o_s_rvalid),
    .rready (i_s_rready)
);
