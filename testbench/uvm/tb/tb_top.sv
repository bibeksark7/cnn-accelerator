// tb_top: the UVM bench's top level. accel_axil_tb (accel_axil_slave driving an accel_top, the
// same pairing as the cocotb system test) with its AXI4-Lite port on axil_if and its status
// outputs on accel_status_if. No init files: the tests load the network and images through the
// bus, as firmware does. 50 MHz clock; reset held from time 0 until the test's first reset_dut.
module tb_top;
  import uvm_pkg::*;
  import accel_pkg::*;

  logic clk = 1'b0;
  always #10ns clk = ~clk;

  axil_if #(.ADDR_W(23)) aif (clk);
  accel_status_if sif (clk);

  initial aif.rst = 1'b1;
  assign sif.rst = aif.rst;

  accel_axil_tb u_dut (
      .clk      (clk),
      .rst      (aif.rst),
      .i_awvalid(aif.awvalid),
      .o_awready(aif.awready),
      .i_awaddr (aif.awaddr),
      .i_wvalid (aif.wvalid),
      .o_wready (aif.wready),
      .i_wdata  (aif.wdata),
      .i_wstrb  (aif.wstrb),
      .o_bvalid (aif.bvalid),
      .i_bready (aif.bready),
      .o_bresp  (aif.bresp),
      .i_arvalid(aif.arvalid),
      .o_arready(aif.arready),
      .i_araddr (aif.araddr),
      .o_rvalid (aif.rvalid),
      .i_rready (aif.rready),
      .o_rdata  (aif.rdata),
      .o_rresp  (aif.rresp),
      .o_busy   (sif.busy),
      .o_done   (sif.done),
      .o_error  (sif.error),
      .o_result (sif.result)
  );

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env*", "vif", aif);
    uvm_config_db#(virtual accel_status_if)::set(null, "uvm_test_top.env*", "status_vif", sif);
    run_test();
  end
endmodule
