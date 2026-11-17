// postproc: bias add, requantization, saturation and ReLU (spec §3, §3.1).
//
//   y   = acc + bias                                    (ACC_W, wraps; never overflows in use)
//   p   = $signed(y) * $signed({1'b0, M})               (ACC_W + 17 bits, value fits 48)
//   r   = (p + (1 <<< (S - 1))) >>> S                   (signed, >= 49 bits)
//   q8  = clamp(r, -128, 127); if relu_en: max(q8, 0)
//
// With i_requant_en = 0 (FC) only o_y is meaningful (o_q8 is don't-care) and relu_en is ignored.
//
// Parameters:
//   ACC_W - accumulator / bias width
//   TAG_W - width of a sideband tag carried alongside each element (e.g. its write address)
//
// Ports (valid/ready stream in, valid/ready stream out):
//   clk, rst          - clock, synchronous active-high reset (pipeline emptied)
//   i_valid, o_ready  - input handshake
//   i_acc, i_bias     - signed accumulator and bias
//   i_m               - unsigned multiplier M in [2^15, 2^16 - 1]
//   i_s               - shift S in [1, 47] (0 only when requantization is disabled)
//   i_requant_en      - 1: produce o_q8; 0: bypass (only o_y used)
//   i_relu_en         - clamp o_q8 at 0 (only when i_requant_en)
//   i_tag             - sideband, returned unchanged with the result
//   o_valid, i_ready  - output handshake
//   o_q8              - requantized int8 result
//   o_y               - acc + bias (int32), for FC logits
//   o_tag             - i_tag of this element
//
// Latency: four register stages (y/M/S; multiply; round/shift; saturate/ReLU). The multiply
// stage has registered operands and a registered product so it maps onto DSP multipliers.
// Order is preserved. The latency is not part of any interface; consumers use the handshake.
module postproc #(
    parameter int ACC_W = 32,
    parameter int TAG_W = 16
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_valid,
    output logic             o_ready,
    input  logic [ACC_W-1:0] i_acc,
    input  logic [ACC_W-1:0] i_bias,
    input  logic [     15:0] i_m,
    input  logic [      5:0] i_s,
    input  logic             i_requant_en,
    input  logic             i_relu_en,
    input  logic [TAG_W-1:0] i_tag,
    output logic             o_valid,
    input  logic             i_ready,
    output logic [      7:0] o_q8,
    output logic [ACC_W-1:0] o_y,
    output logic [TAG_W-1:0] o_tag
);

  localparam int P_W = ACC_W + 17;  // signed ACC_W x signed 17-bit product
  localparam int R_W = (P_W > 49) ? P_W : 49;  // rounding intermediate, >= 49 bits
  localparam logic signed [R_W-1:0] SAT_MAX = 127;  // int8 saturation bounds at R_W bits
  localparam logic signed [R_W-1:0] SAT_MIN = -128;

  // Elastic pipeline: a stage loads when it is empty or the next stage is taking its data.
  logic v1_q, v2_q, v3_q, v4_q;
  logic ready1, ready2, ready3, ready4;

  assign ready4  = !v4_q || i_ready;
  assign ready3  = !v3_q || ready4;
  assign ready2  = !v2_q || ready3;
  assign ready1  = !v1_q || ready2;
  assign o_ready = ready1;

  always_ff @(posedge clk) begin
    if (rst) begin
      v1_q <= 1'b0;
      v2_q <= 1'b0;
      v3_q <= 1'b0;
      v4_q <= 1'b0;
    end else begin
      if (ready1) v1_q <= i_valid;
      if (ready2) v2_q <= v1_q;
      if (ready3) v3_q <= v2_q;
      if (ready4) v4_q <= v3_q;
    end
  end

  // ---------------------------------------------------------------- stage 1: y, M, S
  logic signed [ACC_W-1:0] y1_q;
  logic        [     15:0] m1_q;
  logic        [      5:0] s1_q;
  logic                    rq1_q, relu1_q;
  logic        [TAG_W-1:0] tag1_q;

  always_ff @(posedge clk) begin
    if (ready1 && i_valid) begin
      y1_q    <= $signed(i_acc) + $signed(i_bias);
      m1_q    <= i_m;
      s1_q    <= i_s;
      rq1_q   <= i_requant_en;
      relu1_q <= i_relu_en;
      tag1_q  <= i_tag;
    end
  end

  // ---------------------------------------------------------------- stage 2: p = y * M
  logic signed [  P_W-1:0] p2_q;
  logic signed [ACC_W-1:0] y2_q;
  logic        [      5:0] s2_q;
  logic                    rq2_q, relu2_q;
  logic        [TAG_W-1:0] tag2_q;

  always_ff @(posedge clk) begin
    if (ready2 && v1_q) begin
      p2_q    <= y1_q * $signed({1'b0, m1_q});  // M zero-extended, then signed (spec §3.1)
      y2_q    <= y1_q;
      s2_q    <= s1_q;
      rq2_q   <= rq1_q;
      relu2_q <= relu1_q;
      tag2_q  <= tag1_q;
    end
  end

  // ---------------------------------------------------------------- stage 3: round, shift
  logic signed [R_W-1:0] p_ext, rnd, r_in;

  assign p_ext = R_W'(p2_q);  // sign-extending: p2_q is signed
  assign rnd   = (s2_q == 6'd0) ? '0 : ($signed(R_W'(1)) <<< (s2_q - 6'd1));
  assign r_in  = (p_ext + rnd) >>> s2_q;  // signed operand: arithmetic shift

  logic signed [  R_W-1:0] r3_q;
  logic signed [ACC_W-1:0] y3_q;
  logic                    rq3_q, relu3_q;
  logic        [TAG_W-1:0] tag3_q;

  always_ff @(posedge clk) begin
    if (ready3 && v2_q) begin
      r3_q    <= r_in;
      y3_q    <= y2_q;
      rq3_q   <= rq2_q;
      relu3_q <= relu2_q;
      tag3_q  <= tag2_q;
    end
  end

  // ---------------------------------------------------------------- stage 4: saturate, ReLU
  logic       sat_hi, sat_lo;
  logic [7:0] sat_val, q_val;

  assign sat_hi  = r3_q > SAT_MAX;
  assign sat_lo  = r3_q < SAT_MIN;
  assign sat_val = sat_hi ? 8'h7F : (sat_lo ? 8'h80 : r3_q[7:0]);
  assign q_val   = (relu3_q && sat_val[7]) ? 8'h00 : sat_val;

  logic [      7:0] q4_q;
  logic [ACC_W-1:0] y4_q;
  logic [TAG_W-1:0] tag4_q;

  always_ff @(posedge clk) begin
    if (ready4 && v3_q) begin
      q4_q   <= rq3_q ? q_val : 8'h00;
      y4_q   <= y3_q;
      tag4_q <= tag3_q;
    end
  end

  assign o_valid = v4_q;
  assign o_q8    = q4_q;
  assign o_y     = y4_q;
  assign o_tag   = tag4_q;

endmodule
