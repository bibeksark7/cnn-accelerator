// soc_bus_sva: the CPU side of soc_top's bus (Verilator --assert runs of the SoC tests, bound by
// soc_bus_bind.sv). PicoRV32 ignores BRESP/RRESP, so an error response would pass silently on
// the board (D-040): here it fails the simulation. Also counts the CPU's transactions (writes_q,
// reads_q, never reset) for the test's log, without a per-cycle Python monitor.
//
//   a_no_write_error   a write response the CPU accepts is OKAY
//   a_no_read_error    a read response the CPU accepts is OKAY
//   a_no_trap          the CPU never traps
module soc_bus_sva (
    input logic       clk,
    input logic       rst,
    input logic       bvalid,
    input logic       bready,
    input logic [1:0] bresp,
    input logic       rvalid,
    input logic       rready,
    input logic [1:0] rresp,
    input logic       trap
);

  int unsigned writes_q = 0;
  int unsigned reads_q = 0;
  always_ff @(posedge clk) begin
    if (!rst) begin
      if (bvalid && bready) writes_q <= writes_q + 1;
      if (rvalid && rready) reads_q <= reads_q + 1;
    end
  end

  a_no_write_error :
  assert property (@(posedge clk) disable iff (rst) (bvalid && bready) |-> bresp == 2'b00);

  a_no_read_error :
  assert property (@(posedge clk) disable iff (rst) (rvalid && rready) |-> rresp == 2'b00);

  a_no_trap :
  assert property (@(posedge clk) disable iff (rst) !trap);

endmodule
