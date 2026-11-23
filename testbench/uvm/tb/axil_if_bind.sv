// Binds the AXI4-Lite channel checks to the UVM bench's interface (axil_if): the same modules
// axil_slave_port_bind.sv binds to every axil_slave_port in the cocotb and SoC tests, so one
// checker states the rules of spec §13.3 for every bench.
//   u_aw_vr_sva, u_w_vr_sva, u_ar_vr_sva  the master's VALID and payload held until READY
//   u_b_vr_sva, u_r_vr_sva                the slave's BVALID / RVALID, response and data held
//   u_order_sva                           B only after its AW and W, R only after its AR; covers
//                                         of each AW / W arrival order
bind axil_if valid_ready_sva #(
    .W(ADDR_W)
) u_aw_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (awvalid),
    .ready  (awready),
    .payload(awaddr)
);

bind axil_if valid_ready_sva #(
    .W(36)
) u_w_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (wvalid),
    .ready  (wready),
    .payload({wstrb, wdata})
);

bind axil_if valid_ready_sva #(
    .W(2)
) u_b_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (bvalid),
    .ready  (bready),
    .payload(bresp)
);

bind axil_if valid_ready_sva #(
    .W(ADDR_W)
) u_ar_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (arvalid),
    .ready  (arready),
    .payload(araddr)
);

bind axil_if valid_ready_sva #(
    .W(34)
) u_r_vr_sva (
    .clk    (clk),
    .rst    (rst),
    .valid  (rvalid),
    .ready  (rready),
    .payload({rresp, rdata})
);

bind axil_if axil_resp_order_sva u_order_sva (
    .clk    (clk),
    .rst    (rst),
    .awvalid(awvalid),
    .awready(awready),
    .wvalid (wvalid),
    .wready (wready),
    .bvalid (bvalid),
    .bready (bready),
    .arvalid(arvalid),
    .arready(arready),
    .rvalid (rvalid),
    .rready (rready)
);
