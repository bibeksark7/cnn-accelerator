// counter: 8-bit free-running counter used only to check the toolchain
// (Icarus, Verilator, Yosys, cocotb). Removed once the core RTL has tests.
//
// Ports:
//   clk   - clock
//   rst   - synchronous active-high reset (count -> 0)
//   en    - count enable
//   count - current count, wraps from 255 to 0
//
// Latency: count updates one cycle after en is sampled high.
module counter (
    input  logic       clk,
    input  logic       rst,
    input  logic       en,
    output logic [7:0] count
);

  always_ff @(posedge clk) begin
    if (rst) begin
      count <= 8'd0;
    end else if (en) begin
      count <= count + 8'd1;
    end
  end

endmodule
