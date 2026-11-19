// mac_cell_props: formal properties of rtl/core/mac_cell.sv (SymbiYosys, testbench/formal/).
//
// Open-source Yosys reads immediate assertions with $past, not concurrent SVA or hierarchical
// references, so the properties use the cell's ports only. Proved for all inputs (k-induction).
//   accumulate  with i_valid (no reset, no clear) the accumulator gains exactly i_a * i_b
//               (signed, modulo 2^ACC_W)
//   clear       after rst or i_clear the accumulator is 0
//   hold        with neither i_valid nor i_clear it keeps its value
//   forward     o_valid, o_a, o_b are i_valid, i_a, i_b one cycle later (o_valid 0 after reset)
// Assumption (spec §11.2): i_clear and i_valid are never high in the same cycle.
module mac_cell_props #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input logic                     clk,
    input logic                     rst,
    input logic                     i_clear,
    input logic                     i_valid,
    input logic signed [DATA_W-1:0] i_a,
    input logic signed [DATA_W-1:0] i_b
);

  logic                     o_valid;
  logic signed [DATA_W-1:0] o_a, o_b;
  logic signed [ ACC_W-1:0] o_acc;

  mac_cell #(
      .DATA_W(DATA_W),
      .ACC_W (ACC_W)
  ) u_mac_cell (
      .clk    (clk),
      .rst    (rst),
      .i_clear(i_clear),
      .i_valid(i_valid),
      .i_a    (i_a),
      .i_b    (i_b),
      .o_valid(o_valid),
      .o_a    (o_a),
      .o_b    (o_b),
      .o_acc  (o_acc)
  );

  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;

  // The product at ACC_W bits, computed independently of the RTL's expression.
  logic signed [ACC_W-1:0] a_ext, b_ext, prod;
  assign a_ext = {{(ACC_W - DATA_W) {i_a[DATA_W-1]}}, i_a};
  assign b_ext = {{(ACC_W - DATA_W) {i_b[DATA_W-1]}}, i_b};
  assign prod  = a_ext * b_ext;

  always @(*) assume (!(i_clear && i_valid));

  always @(posedge clk) begin
    if (past_valid) begin
      if ($past(rst) || $past(i_clear)) begin
        p_clear : assert (o_acc == '0);
      end else if ($past(i_valid)) begin
        p_accumulate : assert (o_acc == $past(o_acc) + $past(prod));
      end else begin
        p_hold : assert (o_acc == $past(o_acc));
      end
      if ($past(rst)) begin
        p_valid_reset : assert (!o_valid);
      end else begin
        p_valid_forward : assert (o_valid == $past(i_valid));
      end
      p_a_forward : assert (o_a == $past(i_a));
      p_b_forward : assert (o_b == $past(i_b));
    end
  end

endmodule
