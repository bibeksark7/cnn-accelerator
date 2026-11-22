// Binds the AXI4-Lite checks to every axil_slave_port (Verilator --assert runs):
// valid_ready_sva on the five AXI channels (AW, W, AR: the master's obligation; B, R: the
// port's), axil_resp_order_sva on the response order, and on the local side valid_ready_sva on
// the request (the port's obligation) and req_rsp_sva on the responses (the slave's).
bind axil_slave_port valid_ready_sva #(
    .W(ADDR_W)
) u_aw_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_awvalid),
    .ready  (o_awready),
    .payload(i_awaddr)
);

bind axil_slave_port valid_ready_sva #(
    .W(36)
) u_w_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_wvalid),
    .ready  (o_wready),
    .payload({i_wstrb, i_wdata})
);

bind axil_slave_port valid_ready_sva #(
    .W(2)
) u_b_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_bvalid),
    .ready  (i_bready),
    .payload(o_bresp)
);

bind axil_slave_port valid_ready_sva #(
    .W(ADDR_W)
) u_ar_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (i_arvalid),
    .ready  (o_arready),
    .payload(i_araddr)
);

bind axil_slave_port valid_ready_sva #(
    .W(34)
) u_r_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_rvalid),
    .ready  (i_rready),
    .payload({o_rresp, o_rdata})
);

bind axil_slave_port axil_resp_order_sva u_order_sva (
    .clk    (clk),
    .rst    (rst),
    .awvalid(i_awvalid),
    .awready(o_awready),
    .wvalid (i_wvalid),
    .wready (o_wready),
    .bvalid (o_bvalid),
    .bready (i_bready),
    .arvalid(i_arvalid),
    .arready(o_arready),
    .rvalid (o_rvalid),
    .rready (i_rready)
);

// The request's write data and strobes matter only for writes.
bind axil_slave_port valid_ready_sva #(
    .W(1 + ADDR_W + 36)
) u_req_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (o_req_valid),
    .ready  (i_req_ready),
    .payload({o_req_we, o_req_addr, o_req_we ? {o_req_wstrb, o_req_wdata} : 36'd0})
);

bind axil_slave_port req_rsp_sva u_req_rsp_sva (
    .clk      (clk),
    .rst      (rst),
    .req_valid(o_req_valid),
    .req_ready(i_req_ready),
    .rsp_valid(i_rsp_valid)
);
