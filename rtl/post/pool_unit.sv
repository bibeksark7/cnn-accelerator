// pool_unit: 2x2 / stride-2 signed max pool over an HWC int8 tensor (spec §9, POOL).
//
// agen_pool supplies the four source addresses of each window (c fastest) and the destination
// address. Each address is read from the source buffer (1-cycle latency); the data returns with
// the window flags one cycle later and updates a running signed maximum. On the window's last
// read the maximum is written to the destination one cycle after that (registered write port).
//
// Parameters:
//   ADDR_W - buffer address width
//   DIM_W  - width of h, w, c
//   DATA_W - element width (signed)
//
// Ports:
//   clk, rst                     - clock, synchronous active-high reset
//   i_start                      - pulse: start pooling (only while o_busy is low)
//   o_busy                       - high from i_start through the o_done cycle
//   o_done                       - one-cycle pulse after the last output is written (also for
//                                  shapes with no output: H or W below 2, or C = 0)
//   i_src_base, i_dst_base       - source / destination base addresses
//   i_h, i_w, i_c                - input shape (held stable while busy)
//   o_src_re, o_src_addr         - source read port (data on i_src_rdata one cycle later)
//   i_src_rdata                  - source read data
//   o_dst_we, o_dst_addr, o_dst_wdata - destination write port
//
// Latency: about W cycles of address setup, then 4 cycles per output element. Not part of any
// interface.
module pool_unit #(
    parameter int ADDR_W = 16,
    parameter int DIM_W  = 8,
    parameter int DATA_W = 8
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_start,
    output logic              o_busy,
    output logic              o_done,
    input  logic [ADDR_W-1:0] i_src_base,
    input  logic [ADDR_W-1:0] i_dst_base,
    input  logic [ DIM_W-1:0] i_h,
    input  logic [ DIM_W-1:0] i_w,
    input  logic [ DIM_W-1:0] i_c,
    output logic              o_src_re,
    output logic [ADDR_W-1:0] o_src_addr,
    input  logic [DATA_W-1:0] i_src_rdata,
    output logic              o_dst_we,
    output logic [ADDR_W-1:0] o_dst_addr,
    output logic [DATA_W-1:0] o_dst_wdata
);

  // ---------------------------------------------------------------- address generator
  logic agen_busy, agen_valid, agen_first, agen_last;
  logic [ADDR_W-1:0] agen_addr, agen_dst;
  logic agen_start;

  // Lint waiver: o_end (last read of the layer) is not needed. Completion is detected from the
  // empty pipeline instead, which also covers shapes that produce no reads at all.
  /* verilator lint_off PINCONNECTEMPTY */
  agen_pool #(
      .ADDR_W(ADDR_W),
      .DIM_W (DIM_W)
  ) u_agen_pool (
      .clk       (clk),
      .rst       (rst),
      .i_start   (agen_start),
      .i_src_base(i_src_base),
      .i_dst_base(i_dst_base),
      .i_h       (i_h),
      .i_w       (i_w),
      .i_c       (i_c),
      .o_busy    (agen_busy),
      .o_valid   (agen_valid),
      .i_ready   (1'b1),
      .o_addr    (agen_addr),
      .o_first   (agen_first),
      .o_last    (agen_last),
      .o_dst     (agen_dst),
      .o_end     ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // Every address is read as soon as it is offered (the source read port is always free).
  assign o_src_re   = agen_valid;
  assign o_src_addr = agen_addr;

  // ---------------------------------------------------------------- read-data stage
  logic rd_v_q, rd_first_q, rd_last_q;
  logic [ADDR_W-1:0] rd_dst_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_v_q <= 1'b0;
    end else begin
      rd_v_q <= agen_valid;
    end
  end

  always_ff @(posedge clk) begin
    if (agen_valid) begin
      rd_first_q <= agen_first;
      rd_last_q  <= agen_last;
      rd_dst_q   <= agen_dst;
    end
  end

  // Running signed maximum of the current window.
  logic signed [DATA_W-1:0] max_q, max_d, data;
  assign data  = $signed(i_src_rdata);
  assign max_d = (rd_first_q || (data > max_q)) ? data : max_q;

  always_ff @(posedge clk) begin
    if (rd_v_q) begin
      max_q <= max_d;
    end
  end

  // ---------------------------------------------------------------- write stage
  logic wr_v_q;
  logic [ADDR_W-1:0] wr_addr_q;
  logic [DATA_W-1:0] wr_data_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      wr_v_q <= 1'b0;
    end else begin
      wr_v_q <= rd_v_q && rd_last_q;
    end
  end

  always_ff @(posedge clk) begin
    if (rd_v_q && rd_last_q) begin
      wr_addr_q <= rd_dst_q;
      wr_data_q <= max_d;
    end
  end

  assign o_dst_we    = wr_v_q;
  assign o_dst_addr  = wr_addr_q;
  assign o_dst_wdata = wr_data_q;

  // ---------------------------------------------------------------- control
  typedef enum logic [1:0] {
    P_IDLE,
    P_RUN,
    P_DONE
  } pstate_t;

  pstate_t state_q;

  // agen_pool is busy from the cycle after it sees i_start until its last address is taken;
  // the read and write stages drain two cycles later.
  assign agen_start = (state_q == P_IDLE) && i_start;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= P_IDLE;
    end else begin
      case (state_q)
        P_IDLE: begin
          if (i_start) begin
            state_q <= P_RUN;
          end
        end
        P_RUN: begin
          if (!agen_busy && !rd_v_q && !wr_v_q) begin
            state_q <= P_DONE;
          end
        end
        P_DONE: begin
          state_q <= P_IDLE;
        end
        default: state_q <= P_IDLE;
      endcase
    end
  end

  assign o_busy = (state_q != P_IDLE);
  assign o_done = (state_q == P_DONE);

endmodule
