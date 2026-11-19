// argmax_unit_full_props: argmax_unit at full width (VAL_W = 32, IDX_W = 8, as in accel_top),
// with symbolic indices (SymbiYosys, testbench/formal/; ports only).
//
// Storing 256 symbolic logits is too large for the solvers, so the logit file is described by
// two free positions j and k of the window with free constant values vj and vk; every other
// read returns an arbitrary value (each position is read once per run, so this covers every
// logit file). Because j and k are arbitrary, a property proved for them holds for every
// position. At o_done, for the run's window (base, count):
//   p_count0         count = 0 gives result 0
//   p_in_window      result < count
//   p_j_not_above    if j < count: w[j] <= o_max                      (o_max is a maximum)
//   p_j_before_lower if j < result: w[j] < o_max                       (lowest index on ties)
//   p_k_is_result    if k = result: o_max = w[k]           (o_max is the result's own value)
//   p_done_on_time   o_done exactly count + 2 cycles after the start (1 for count = 0)
//   p_reads_window   every read is inside the window, and only during a run
// Cover (task cover): a done with count = 10 where j and k hold equal maxima, j < k.
module argmax_unit_full_props #(
    parameter int VAL_W     = 32,
    parameter int IDX_W     = 8,
    parameter int MAX_COUNT = 10  // windows of at most this many logits (the network uses 10)
) (
    input logic             clk,
    input logic             rst,
    input logic             i_start,
    input logic [IDX_W-1:0] i_base,
    input logic [IDX_W-1:0] i_count
);

  (* anyconst *) logic [IDX_W-1:0] j, k;
  (* anyconst *) logic signed [VAL_W-1:0] vj, vk;
  (* anyseq *) logic signed [VAL_W-1:0] other;

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

  // The run's window, latched at its start, and the cycles since then.
  logic [IDX_W-1:0] base_q, count_q;
  logic run_q;
  logic [IDX_W+1:0] cyc_q, due;
  always @(posedge clk) begin
    if (rst) begin
      run_q <= 1'b0;
      cyc_q <= '0;
    end else if (i_start && !o_busy) begin
      run_q   <= 1'b1;
      base_q  <= i_base;
      count_q <= i_count;
      cyc_q   <= (IDX_W + 2)'(1);
    end else begin
      if (o_done) run_q <= 1'b0;
      if (run_q) cyc_q <= cyc_q + (IDX_W + 2)'(1);
    end
  end
  assign due = (count_q == '0) ? (IDX_W + 2)'(1) : (IDX_W + 2)'(count_q) + (IDX_W + 2)'(2);

  // Read port (1-cycle latency): position j returns vj, position k returns vk (j wins if j = k),
  // anything else an arbitrary value.
  logic [IDX_W-1:0] pos;
  logic signed [VAL_W-1:0] wk;
  assign pos = o_rd_idx - base_q;
  assign wk  = (k == j) ? vj : vk;
  always @(posedge clk) rd_data_q <= (pos == j) ? vj : ((pos == k) ? vk : other);

  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;

  always @(*) begin
    assume (!(i_start && o_busy));
    if (i_start && !o_busy) assume (32'(i_count) <= MAX_COUNT);
    if (!past_valid) assume (rst);
  end

  always @(*) begin
    if (!rst) begin
      if (o_rd_en) begin
        p_reads_busy : assert (o_busy && run_q);
        p_reads_window : assert (pos < count_q);
      end
      if (run_q && (cyc_q == due)) begin
        p_done_on_time : assert (o_done);
      end
      if (run_q && o_done) begin
        p_done_not_early : assert (cyc_q == due);
        if (count_q == '0) begin
          p_count0 : assert (o_result == '0);
        end else begin
          p_in_window : assert (o_result < count_q);
          if (j < count_q) begin
            p_j_not_above : assert (vj <= $signed(o_max));
          end
          if (j < o_result) begin
            p_j_before_lower : assert (vj < $signed(o_max));
          end
          if (k == o_result) begin
            p_k_is_result : assert ($signed(o_max) == wk);
          end
        end
      end
    end
  end

  always @(posedge clk) begin
    if (!rst) begin
      c_tie_count10 : cover (o_done && run_q && (count_q == IDX_W'(10)) && (j < k) && (k < count_q)
                             && (vj == vk) && ($signed(o_max) == vj) && (o_result == j));
    end
  end

endmodule
