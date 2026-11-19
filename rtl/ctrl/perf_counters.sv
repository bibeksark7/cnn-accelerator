// perf_counters: performance counters of spec §10.2 (docs/decisions.md D-027, D-028).
//
// All counters are cleared by i_clear (START), count only while i_busy, hold their values
// afterwards, and saturate at 2^PERF_W - 1.
//
// Input register (timing, docs/decisions.md D-024): i_busy, i_mac_active, i_rd and i_wr are
// registered before the saturating adds, so the buffer multiplexers' request logic and the adds
// are in different cycles. An event in cycle t is added at the end of cycle t + 1 and shows in the
// outputs in cycle t + 2, one cycle later than the layer counters. i_clear also clears the input
// register, so events in the clear cycle are not counted (as without the register). CYC_TOTAL and
// the other three counters therefore reach their final values one cycle after BUSY falls.
//   cyc_total     cycles with i_busy high (START to DONE)
//   cyc_mac       cycles with i_mac_active high (the array consumed a reduction step)
//   buf_rd        buffer reads: each cycle adds the number of set bits of i_rd (0 .. RD_N)
//   buf_wr        buffer writes: each cycle adds the number of set bits of i_wr (0 .. WR_N)
//   layer_cyc[L]  cycles of layer L, from the cycle i_layer_start is high through the cycle
//                 i_layer_done is high, inclusive (layers that never start stay 0)
// i_rd and i_wr are the request outputs of the per-buffer port multiplexers, so only the §5
// buffers are counted (not the staging banks, the LOGIT registers or the descriptor table).
//
// Parameters:
//   PERF_W     - counter width (spec: 32)
//   DESC_DEPTH - number of layer counters
//   RD_N, WR_N - number of read / write request bits (at most 15 each)
//
// Ports:
//   clk, rst                      - clock, synchronous active-high reset (all counters 0)
//   i_clear                       - clear every counter (has priority over counting)
//   i_busy                        - the accelerator is running
//   i_mac_active                  - GEMM engine o_mac_active
//   i_rd, i_wr                    - buffer read / write requests this cycle
//   i_layer_start, i_layer_done   - pulses: the sequencer starts layer i_layer_idx; its unit
//                                   reports done (i_layer_idx is held between the two)
//   i_layer_idx                   - index of the running layer
//   o_cyc_total, o_cyc_mac, o_buf_rd, o_buf_wr - counter values
//   o_layer_cyc                   - layer counter L at [L*PERF_W +: PERF_W]
//
// Latency: cyc_total, cyc_mac, buf_rd, buf_wr: an event shows in the outputs two cycles later;
// layer_cyc: one cycle later.
module perf_counters #(
    parameter int PERF_W     = 32,
    parameter int DESC_DEPTH = 8,
    parameter int RD_N       = 5,
    parameter int WR_N       = 2
) (
    input  logic                         clk,
    input  logic                         rst,
    input  logic                         i_clear,
    input  logic                         i_busy,
    input  logic                         i_mac_active,
    input  logic [             RD_N-1:0] i_rd,
    input  logic [             WR_N-1:0] i_wr,
    input  logic                         i_layer_start,
    input  logic                         i_layer_done,
    input  logic [(DESC_DEPTH > 1 ? $clog2(DESC_DEPTH) : 1)-1:0] i_layer_idx,
    output logic [           PERF_W-1:0] o_cyc_total,
    output logic [           PERF_W-1:0] o_cyc_mac,
    output logic [           PERF_W-1:0] o_buf_rd,
    output logic [           PERF_W-1:0] o_buf_wr,
    output logic [DESC_DEPTH*PERF_W-1:0] o_layer_cyc
);

  localparam int INC_W = 4;  // holds 0 .. 15 requests per cycle
  localparam logic [PERF_W-1:0] MAX = '1;

  // Input register: the events of the previous cycle.
  logic busy_q, mac_q;
  logic [RD_N-1:0] rd_q;
  logic [WR_N-1:0] wr_q;
  always_ff @(posedge clk) begin
    if (rst || i_clear) begin
      busy_q <= 1'b0;
      mac_q  <= 1'b0;
      rd_q   <= '0;
      wr_q   <= '0;
    end else begin
      busy_q <= i_busy;
      mac_q  <= i_mac_active;
      rd_q   <= i_rd;
      wr_q   <= i_wr;
    end
  end

  // Number of set bits in the registered request vectors.
  logic [INC_W-1:0] rd_inc, wr_inc;
  always_comb begin
    rd_inc = '0;
    for (int i = 0; i < RD_N; i++) begin
      rd_inc = rd_inc + INC_W'(rd_q[i]);
    end
    wr_inc = '0;
    for (int i = 0; i < WR_N; i++) begin
      wr_inc = wr_inc + INC_W'(wr_q[i]);
    end
  end

  // Saturating sums: one extra bit catches the carry out.
  logic [PERF_W:0] tot_sum, mac_sum, rd_sum, wr_sum, lay_sum;
  logic [PERF_W-1:0] cyc_total_q, cyc_mac_q, buf_rd_q, buf_wr_q, lay_q;
  logic lay_run_q;
  logic [PERF_W-1:0] layer_cyc_q[DESC_DEPTH];

  assign tot_sum = {1'b0, cyc_total_q} + (PERF_W + 1)'(1);
  assign mac_sum = {1'b0, cyc_mac_q} + (PERF_W + 1)'(1);
  assign rd_sum  = {1'b0, buf_rd_q} + (PERF_W + 1)'(rd_inc);
  assign wr_sum  = {1'b0, buf_wr_q} + (PERF_W + 1)'(wr_inc);
  assign lay_sum = {1'b0, lay_q} + (PERF_W + 1)'(1);  // this cycle's count including it

  always_ff @(posedge clk) begin
    if (rst || i_clear) begin
      cyc_total_q <= '0;
      cyc_mac_q   <= '0;
      buf_rd_q    <= '0;
      buf_wr_q    <= '0;
      lay_q       <= '0;
      lay_run_q   <= 1'b0;
      for (int l = 0; l < DESC_DEPTH; l++) begin
        layer_cyc_q[l] <= '0;
      end
    end else begin
      if (busy_q) begin
        cyc_total_q <= tot_sum[PERF_W] ? MAX : tot_sum[PERF_W-1:0];
        if (mac_q) begin
          cyc_mac_q <= mac_sum[PERF_W] ? MAX : mac_sum[PERF_W-1:0];
        end
        buf_rd_q <= rd_sum[PERF_W] ? MAX : rd_sum[PERF_W-1:0];
        buf_wr_q <= wr_sum[PERF_W] ? MAX : wr_sum[PERF_W-1:0];
      end
      // Layer counter: lay_q counts the cycles of the running layer before the current one.
      if (i_layer_start) begin
        lay_q     <= PERF_W'(1);
        lay_run_q <= 1'b1;
      end else if (lay_run_q) begin
        lay_q <= lay_sum[PERF_W] ? MAX : lay_sum[PERF_W-1:0];
      end
      if (lay_run_q && i_layer_done) begin
        lay_run_q                <= 1'b0;
        layer_cyc_q[i_layer_idx] <= lay_sum[PERF_W] ? MAX : lay_sum[PERF_W-1:0];
      end
    end
  end

  assign o_cyc_total = cyc_total_q;
  assign o_cyc_mac   = cyc_mac_q;
  assign o_buf_rd    = buf_rd_q;
  assign o_buf_wr    = buf_wr_q;

  genvar gl;
  generate
    for (gl = 0; gl < DESC_DEPTH; gl = gl + 1) begin : g_layer
      assign o_layer_cyc[gl*PERF_W+:PERF_W] = layer_cyc_q[gl];
    end
  endgenerate

endmodule
