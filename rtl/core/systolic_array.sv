// systolic_array: N x N output-stationary systolic array (spec §11.2).
//
// Computes one N x N output tile C = A * B by streaming K reduction steps. Step k presents
// column k of A (i_a byte i = A[i][k]) and row k of B (i_b byte j = B[k][j]). Inputs are skewed
// internally: row i of A is delayed i cycles and column j of B j cycles, so A[i][k] and B[k][j]
// meet in PE (i, j). A and the valid bit move right, B moves down; each PE accumulates.
//
// Parameters:
//   N      - array dimension
//   DATA_W - operand width (signed)
//   ACC_W  - accumulator width (signed)
//
// Ports (all handshakes per spec §11.2):
//   clk, rst      - clock, synchronous active-high reset
//   i_clear       - zero all accumulators (only while idle; never with i_valid)
//   i_valid       - one reduction step this cycle; always accepted; may have gaps
//   i_a           - N signed bytes, byte i = A[i][k]
//   i_b           - N signed bytes, byte j = B[k][j]
//   i_drain       - pulse after the last step (never with the last i_valid)
//   o_row_valid   - result row available
//   i_row_ready   - consumer accepts the row
//   o_row_data    - N signed ACC_W words, word j = C[row][j]
//   o_row_last    - marks row N-1
//   o_idle        - no step in flight and no drain pending
//
// Latency: after i_drain the array waits until every step in flight has been accumulated
// (at most 2N-2 cycles after the last step), then emits rows 0..N-1, one per accepted
// handshake. Consumers must rely on the handshake, not on this latency.
module systolic_array #(
    parameter int N      = 8,
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
) (
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  i_clear,
    input  logic                  i_valid,
    input  logic [  N*DATA_W-1:0] i_a,
    input  logic [  N*DATA_W-1:0] i_b,
    input  logic                  i_drain,
    output logic                  o_row_valid,
    input  logic                  i_row_ready,
    output logic [   N*ACC_W-1:0] o_row_data,
    output logic                  o_row_last,
    output logic                  o_idle
);

  localparam int ROW_W = $clog2(N > 1 ? N : 2);
  localparam int DLY = (N > 1) ? N - 1 : 1;  // delay-line depth (taps 0..N-1)
  localparam logic [ROW_W-1:0] LAST_ROW = ROW_W'(N - 1);

  // ---------------------------------------------------------------- input skew
  // Stage s of each delay line holds the input from s+1 cycles ago. Row/column i taps
  // the input directly (i = 0) or stage i-1.
  logic [N*DATA_W-1:0] a_dly_q[DLY];
  logic [N*DATA_W-1:0] b_dly_q[DLY];
  logic [     DLY-1:0] v_dly_q;

  always_ff @(posedge clk) begin
    a_dly_q[0] <= i_a;
    b_dly_q[0] <= i_b;
    for (int s = 1; s < DLY; s++) begin
      a_dly_q[s] <= a_dly_q[s-1];
      b_dly_q[s] <= b_dly_q[s-1];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      v_dly_q <= '0;
    end else begin
      v_dly_q[0] <= i_valid;
      for (int s = 1; s < DLY; s++) begin
        v_dly_q[s] <= v_dly_q[s-1];
      end
    end
  end

  logic [N*DATA_W-1:0] a_edge;  // skewed A entering column 0, byte i for row i
  logic [N*DATA_W-1:0] b_edge;  // skewed B entering row 0, byte j for column j
  logic [       N-1:0] v_edge;  // skewed valid entering column 0, bit i for row i

  always_comb begin
    a_edge = '0;
    b_edge = '0;
    v_edge = '0;
    for (int i = 0; i < N; i++) begin
      if (i == 0) begin
        a_edge[i*DATA_W+:DATA_W] = i_a[i*DATA_W+:DATA_W];
        b_edge[i*DATA_W+:DATA_W] = i_b[i*DATA_W+:DATA_W];
        v_edge[i]                = i_valid;
      end else begin
        a_edge[i*DATA_W+:DATA_W] = a_dly_q[i-1][i*DATA_W+:DATA_W];
        b_edge[i*DATA_W+:DATA_W] = b_dly_q[i-1][i*DATA_W+:DATA_W];
        v_edge[i]                = v_dly_q[i-1];
      end
    end
  end

  // ---------------------------------------------------------------- PE grid
  // Flat busses indexed by PE (i, j) -> i*N + j.
  // Lint waiver: the last column's forwarded A and the last row's forwarded B leave the grid
  // and are intentionally unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [N*N*DATA_W-1:0] pe_a_out, pe_b_out;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [       N*N-1:0] pe_v_out;
  logic [ N*N*ACC_W-1:0] acc_flat;

  for (genvar i = 0; i < N; i++) begin : g_row
    for (genvar j = 0; j < N; j++) begin : g_col
      logic              v_in;
      logic [DATA_W-1:0] a_in, b_in;

      if (j == 0) begin : g_left
        assign v_in = v_edge[i];
        assign a_in = a_edge[i*DATA_W+:DATA_W];
      end else begin : g_inner_h
        assign v_in = pe_v_out[i*N+j-1];
        assign a_in = pe_a_out[(i*N+j-1)*DATA_W+:DATA_W];
      end

      if (i == 0) begin : g_top
        assign b_in = b_edge[j*DATA_W+:DATA_W];
      end else begin : g_inner_v
        assign b_in = pe_b_out[((i-1)*N+j)*DATA_W+:DATA_W];
      end

      mac_cell #(
          .DATA_W(DATA_W),
          .ACC_W (ACC_W)
      ) u_mac_cell (
          .clk    (clk),
          .rst    (rst),
          .i_clear(i_clear),
          .i_valid(v_in),
          .i_a    (a_in),
          .i_b    (b_in),
          .o_valid(pe_v_out[i*N+j]),
          .o_a    (pe_a_out[(i*N+j)*DATA_W+:DATA_W]),
          .o_b    (pe_b_out[(i*N+j)*DATA_W+:DATA_W]),
          .o_acc  (acc_flat[(i*N+j)*ACC_W+:ACC_W])
      );
    end
  end

  // A step is in flight while its valid bit is anywhere in the skew lines or the grid.
  logic in_flight;
  assign in_flight = i_valid || (|v_dly_q) || (|pe_v_out);

  // ---------------------------------------------------------------- drain
  typedef enum logic [1:0] {
    S_IDLE,
    S_FLUSH,
    S_EMIT
  } state_t;

  state_t state_q, state_d;
  logic [ROW_W-1:0] row_q, row_d;

  always_comb begin
    state_d = state_q;
    row_d   = row_q;
    case (state_q)
      S_IDLE: begin
        if (i_drain) begin
          state_d = S_FLUSH;
        end
      end
      S_FLUSH: begin
        if (!in_flight) begin
          state_d = S_EMIT;
          row_d   = '0;
        end
      end
      S_EMIT: begin
        if (i_row_ready) begin
          if (row_q == LAST_ROW) begin
            state_d = S_IDLE;
          end else begin
            row_d = row_q + 1'b1;
          end
        end
      end
      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      row_q   <= '0;
    end else begin
      state_q <= state_d;
      row_q   <= row_d;
    end
  end

  assign o_row_valid = (state_q == S_EMIT);
  assign o_row_last  = (state_q == S_EMIT) && (row_q == LAST_ROW);
  assign o_row_data  = acc_flat[row_q*N*ACC_W+:N*ACC_W];
  assign o_idle      = (state_q == S_IDLE) && !in_flight;

endmodule
