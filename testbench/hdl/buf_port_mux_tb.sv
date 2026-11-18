// buf_port_mux_tb: unit-test harness for buf_port_mux. Adds the clock and reset that the
// ownership assertions (bound by buf_port_mux_tb_bind.sv in Verilator runs) are sampled on.
module buf_port_mux_tb #(
    parameter int NUM_OWNERS = 3,
    parameter int WIDTH      = 8,
    parameter int AW         = 14
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic [      NUM_OWNERS-1:0] i_owner,
    input  logic [      NUM_OWNERS-1:0] i_re,
    input  logic [   NUM_OWNERS*AW-1:0] i_raddr,
    input  logic [      NUM_OWNERS-1:0] i_we,
    input  logic [   NUM_OWNERS*AW-1:0] i_waddr,
    input  logic [NUM_OWNERS*WIDTH-1:0] i_wdata,
    output logic                        o_re,
    output logic [              AW-1:0] o_raddr,
    output logic                        o_we,
    output logic [              AW-1:0] o_waddr,
    output logic [           WIDTH-1:0] o_wdata
);

  buf_port_mux #(
      .NUM_OWNERS(NUM_OWNERS),
      .WIDTH     (WIDTH),
      .AW        (AW)
  ) u_buf_port_mux (
      .i_owner(i_owner),
      .i_re   (i_re),
      .i_raddr(i_raddr),
      .i_we   (i_we),
      .i_waddr(i_waddr),
      .i_wdata(i_wdata),
      .o_re   (o_re),
      .o_raddr(o_raddr),
      .o_we   (o_we),
      .o_waddr(o_waddr),
      .o_wdata(o_wdata)
  );

endmodule
