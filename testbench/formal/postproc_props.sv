// postproc_props: formal handshake properties of rtl/post/postproc.sv, the design's valid/ready
// pipeline (four elastic stages). SymbiYosys, testbench/formal/; ports only.
//
// Every accepted input is numbered (i_tag = its sequence number, i_acc a function of it,
// i_bias = 0), so each output can be traced back to the input it came from. For any input and
// backpressure pattern:
//   p_in_order     an output is always the oldest element not yet delivered: nothing is lost,
//                  duplicated or reordered (checked on the tag and on o_y, which carries i_acc)
//   p_not_empty    no output without an element inside
//   p_bounded      at most four elements inside
//   p_ready_room   o_ready is high whenever fewer than four elements are inside
//   p_stable       an output not accepted (o_valid && !i_ready) stays valid with the same tag and
//                  data (o_tag, o_y, o_q8) in the next cycle
// Assumption (producer side of the handshake): a request not accepted stays valid and stable.
module postproc_props #(
    parameter int ACC_W = 8,
    parameter int TAG_W = 4
) (
    input logic             clk,
    input logic             rst,
    input logic             i_valid,
    input logic [     15:0] i_m,
    input logic [      5:0] i_s,
    input logic             i_requant_en,
    input logic             i_relu_en,
    input logic             i_ready
);

  logic o_ready, o_valid;
  logic [7:0] o_q8;
  logic [ACC_W-1:0] o_y;
  logic [TAG_W-1:0] o_tag;
  logic [TAG_W-1:0] in_cnt_q, out_cnt_q;
  logic [2:0] occ_q;

  // Input i_acc is derived from the sequence number, so o_y identifies the element too.
  function automatic logic [ACC_W-1:0] acc_of(input logic [TAG_W-1:0] n);
    acc_of = ACC_W'(n) ^ ACC_W'(8'h5A);
  endfunction

  postproc #(
      .ACC_W(ACC_W),
      .TAG_W(TAG_W)
  ) u_postproc (
      .clk         (clk),
      .rst         (rst),
      .i_valid     (i_valid),
      .o_ready     (o_ready),
      .i_acc       (acc_of(in_cnt_q)),
      .i_bias      ('0),
      .i_m         (i_m),
      .i_s         (i_s),
      .i_requant_en(i_requant_en),
      .i_relu_en   (i_relu_en),
      .i_tag       (in_cnt_q),
      .o_valid     (o_valid),
      .i_ready     (i_ready),
      .o_q8        (o_q8),
      .o_y         (o_y),
      .o_tag       (o_tag)
  );

  logic in_fire, out_fire;
  assign in_fire  = i_valid && o_ready;
  assign out_fire = o_valid && i_ready;

  always @(posedge clk) begin
    if (rst) begin
      in_cnt_q  <= '0;
      out_cnt_q <= '0;
      occ_q     <= '0;
    end else begin
      in_cnt_q  <= in_cnt_q + TAG_W'(in_fire);
      out_cnt_q <= out_cnt_q + TAG_W'(out_fire);
      occ_q     <= occ_q + 3'(in_fire) - 3'(out_fire);
    end
  end

  logic past_valid = 1'b0;
  always @(posedge clk) past_valid <= 1'b1;

  always @(*) if (!past_valid) assume (rst);

  // Producer: a request that was not accepted is held with the same side inputs.
  always @(posedge clk) begin
    if (past_valid && !$past(rst) && $past(i_valid && !o_ready)) begin
      assume (i_valid && $stable({i_m, i_s, i_requant_en, i_relu_en}));
    end
  end

  always @(*) begin
    if (!rst) begin
      p_bounded : assert (occ_q <= 3'd4);
      p_ready_room : assert ((occ_q == 3'd4) || o_ready);
      if (o_valid) begin
        p_not_empty : assert (occ_q != 3'd0);
        p_in_order : assert ((o_tag == out_cnt_q) && (o_y == acc_of(out_cnt_q)));
      end
    end
  end

  always @(posedge clk) begin
    if (past_valid && !rst && !$past(rst) && $past(o_valid && !i_ready)) begin
      p_stable : assert (o_valid && $stable({o_tag, o_y, o_q8}));
    end
  end

endmodule
