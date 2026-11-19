// debounce: debounces a synchronized, active-low push button and pulses on each press.
//
// The debounced level changes only after the input has held its new value for 2^CNT_W
// consecutive cycles. A press is the debounced level falling (1 -> 0): o_press is high for one
// cycle at that point.
//
// Parameters:
//   CNT_W - stable-time counter width (2^20 cycles = 21 ms at 50 MHz)
//
// Ports:
//   clk, rst  - clock, synchronous active-high reset (level reset to released, 1)
//   i_key_n   - button, active low, already synchronized to clk
//   o_level_n - debounced level, active low
//   o_press   - one-cycle pulse per debounced press
//
// Latency: o_press comes 2^CNT_W + 1 cycles after the input settles low.
module debounce #(
    parameter int CNT_W = 20
) (
    input  logic clk,
    input  logic rst,
    input  logic i_key_n,
    output logic o_level_n,
    output logic o_press
);

  logic [CNT_W-1:0] cnt_q;
  logic level_q, press_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt_q   <= '0;
      level_q <= 1'b1;
      press_q <= 1'b0;
    end else begin
      press_q <= 1'b0;
      if (i_key_n == level_q) begin
        cnt_q <= '0;  // input agrees with the debounced level: nothing pending
      end else if (cnt_q == '1) begin
        cnt_q   <= '0;
        level_q <= i_key_n;
        press_q <= !i_key_n;  // the level falls: a press
      end else begin
        cnt_q <= cnt_q + CNT_W'(1);
      end
    end
  end

  assign o_level_n = level_q;
  assign o_press   = press_q;

endmodule
