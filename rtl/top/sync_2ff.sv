// sync_2ff: two-flip-flop synchronizer for asynchronous inputs (board switches and keys).
//
// Each bit is synchronized independently; the bits of a multi-bit input are not coherent with
// each other, which is fine for static switches and for single-bit keys.
//
// Parameters:
//   W     - number of bits (<= 32)
//   RESET - value the stages take (and the output shows) during reset (an int: bit i resets
//           bit i)
//
// Ports:
//   clk, rst - clock, synchronous active-high reset
//   i_async  - asynchronous input
//   o_sync   - synchronized output
//
// Latency: 2 cycles.
//
// The first stage carries the Quartus assignment SYNCHRONIZER_IDENTIFICATION FORCED: the Timing
// Analyzer starts a synchronizer chain there, follows it through the second stage and reports
// its MTBF (report_metastability). Marking the second stage too would make it a chain of its own
// (one register long). Other tools ignore the attribute.
module sync_2ff #(
    parameter int W     = 1,
    parameter int RESET = 0
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [W-1:0] i_async,
    output logic [W-1:0] o_sync
);

  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) logic [W-1:0] meta_q;
  logic [W-1:0] sync_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      meta_q <= W'(RESET);
      sync_q <= W'(RESET);
    end else begin
      meta_q <= i_async;
      sync_q <= meta_q;
    end
  end

  assign o_sync = sync_q;

endmodule
