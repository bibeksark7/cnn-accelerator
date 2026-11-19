// argmax_unit_props: formal properties of rtl/post/argmax_unit.sv (SymbiYosys, testbench/formal/).
//
// The LOGIT register file is a free constant (any 2^IDX_W signed values, fixed for the whole
// trace) behind a 1-cycle read port, as in accel_top. i_base and i_count are free at every start.
// Ports-only properties (open-source Yosys: immediate assertions, no hierarchical references):
//   at o_done, for the window w[i] = LOGIT[(base + i) mod 2^IDX_W], i < count, of that start:
//     p_count0       count = 0 gives result 0
//     p_in_window    result < count
//     p_is_max       w[i] <= w[result] for every i < count, and o_max = w[result]
//     p_lowest_tie   w[i] <  w[result] for every i < result (ties go to the lowest index)
//   p_done_busy      o_done only while o_busy
//   p_reads_window   every read is inside the window, and only while o_busy
// Assumption (unit contract): i_start only while o_busy is low.
// Widths: proved at VAL_W = 4, IDX_W = 3 (8 logits, windows of 0..7, wrapping bases); the RTL
// is parameterized and these widths exercise every comparison and wrap case. At VAL_W = 6
// neither PDR (8 min) nor k-induction (15 min) finished.
module argmax_unit_props #(
    parameter int VAL_W = 4,
    parameter int IDX_W = 3
) (
    input logic             clk,
    input logic             rst,
    input logic             i_start,
    input logic [IDX_W-1:0] i_base,
    input logic [IDX_W-1:0] i_count
);

  localparam int DEPTH = 1 << IDX_W;

  (* anyconst *) logic [DEPTH*VAL_W-1:0] logits;

  logic o_busy, o_done, o_rd_en;
  logic [IDX_W-1:0] o_result, o_rd_idx;
  logic [VAL_W-1:0] o_max, rd_data_q;

  argmax_unit #(
      .VAL_W(VAL_W),
      .IDX_W(IDX_W)
  ) u_argmax_unit (
      .clk      (clk),
      .rst      (rst),
      .i_start  (i_start),
      .i_base   (i_base),
      .i_count  (i_count),
      .o_busy   (o_busy),
      .o_done   (o_done),
      .o_result (o_result),
      .o_max    (o_max),
      .o_rd_en  (o_rd_en),
      .o_rd_idx (o_rd_idx),
      .i_rd_data(rd_data_q)
  );

  // Constant-index mux (a variable part-select would give x bits out of range).
  function automatic logic signed [VAL_W-1:0] logit(input logic [IDX_W-1:0] idx);
    logit = '0;
    for (int k = 0; k < DEPTH; k++) begin
      if (idx == IDX_W'(k)) logit = logits[k*VAL_W+:VAL_W];
    end
  endfunction

  // 1-cycle read port.
  always @(posedge clk) rd_data_q <= logit(o_rd_idx);

  // The window of the run in progress, latched at its start.
  logic [IDX_W-1:0] base_q, count_q;
  logic run_q;
  always @(posedge clk) begin
    if (rst) begin
      run_q <= 1'b0;
    end else if (i_start && !o_busy) begin
      run_q   <= 1'b1;
      base_q  <= i_base;
      count_q <= i_count;
    end else if (o_done) begin
      run_q <= 1'b0;
    end
  end

  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;

  always @(*) begin
    assume (!(i_start && o_busy));
    if (!past_valid) assume (rst);
  end

  logic signed [VAL_W-1:0] best;
  assign best = logit(base_q + o_result);

  // Over the window: no element above the result's value, none equal to it before it.
  logic none_above, none_equal_before;
  always @(*) begin
    none_above        = 1'b1;
    none_equal_before = 1'b1;
    for (int i = 0; i < DEPTH; i++) begin
      if ((i < count_q) && (logit(base_q + IDX_W'(i)) > best)) none_above = 1'b0;
      if ((i < o_result) && (logit(base_q + IDX_W'(i)) >= best)) none_equal_before = 1'b0;
    end
  end

  always @(*) begin
    if (!rst) begin
      p_done_busy : assert (!o_done || o_busy);
      if (o_rd_en) begin
        p_reads_busy : assert (o_busy && run_q);
        p_reads_window : assert (IDX_W'(o_rd_idx - base_q) < count_q);
      end
      if (o_done && run_q) begin
        if (count_q == '0) begin
          p_count0 : assert (o_result == '0);
        end else begin
          p_in_window : assert (o_result < count_q);
          p_max_value : assert ($signed(o_max) == best);
          p_is_max : assert (none_above);
          p_lowest_tie : assert (none_equal_before);
        end
      end
    end
  end

endmodule
