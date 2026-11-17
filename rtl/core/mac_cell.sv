// mac_cell: one processing element of the output-stationary systolic array.
//
// Each cycle with i_valid high the cell adds i_a * i_b to its accumulator and forwards
// the operands (A to the right, B downwards) together with the valid bit, one cycle later.
//
// Parameters:
//   DATA_W - operand width (signed)
//   ACC_W  - accumulator width (signed); wraps modulo 2^ACC_W (the golden model proves
//            the network never overflows it)
//
// Ports:
//   clk, rst  - clock, synchronous active-high reset (accumulator and valid cleared)
//   i_clear   - zero the accumulator; never asserted together with i_valid (spec §11.2)
//   i_valid   - operands valid this cycle
//   i_a, i_b  - signed operands
//   o_valid   - i_valid delayed by one cycle (to the right-hand neighbour)
//   o_a, o_b  - i_a / i_b delayed by one cycle (to the right / lower neighbours)
//   o_acc     - accumulator value
//
// Latency: o_acc includes a product one cycle after it is presented; o_valid/o_a/o_b lag
// their inputs by exactly one cycle.
module mac_cell #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     i_clear,
    input  logic                     i_valid,
    input  logic signed [DATA_W-1:0] i_a,
    input  logic signed [DATA_W-1:0] i_b,
    output logic                     o_valid,
    output logic signed [DATA_W-1:0] o_a,
    output logic signed [DATA_W-1:0] o_b,
    output logic signed [ ACC_W-1:0] o_acc
);

  localparam int PROD_W = 2 * DATA_W;

  logic signed [PROD_W-1:0] prod;
  logic signed [ ACC_W-1:0] prod_ext;
  logic signed [ ACC_W-1:0] acc_q;

  assign prod     = i_a * i_b;  // both operands signed: signed multiply
  assign prod_ext = $signed({{(ACC_W - PROD_W) {prod[PROD_W-1]}}, prod});

  always_ff @(posedge clk) begin
    if (rst || i_clear) begin
      acc_q <= '0;
    end else if (i_valid) begin
      acc_q <= acc_q + prod_ext;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      o_valid <= 1'b0;
    end else begin
      o_valid <= i_valid;
    end
  end

  // Operand forwarding needs no reset: consumers only use it when o_valid is high.
  always_ff @(posedge clk) begin
    o_a <= i_a;
    o_b <= i_b;
  end

  assign o_acc = acc_q;

endmodule
