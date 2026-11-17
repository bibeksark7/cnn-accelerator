// agen_pool: window-scan address generator for the 2x2 / stride-2 max pool (spec §9, POOL).
// Uses only incremental counters and adders (no multipliers).
//
// For oy < H/2, ox < W/2, c < C (c fastest, floor for odd H/W) it emits the four source
// addresses of the window, in the order (0,0) (0,1) (1,0) (1,1):
//   src_base + ((2oy + dy) * W + 2ox + dx) * C + c
// together with the destination address dst_base + (oy * W/2 + ox) * C + c, which is simply a
// running count because the HWC output is written in order.
//
// Because H/2 is a floor, i_h[0] never affects the output (Quartus reports it as an input that
// drives no logic).
//
// The row stride W*C is accumulated by repeated addition during setup. Inside a window the four
// offsets are 0, C, W*C and W*C + C; consecutive windows in a row are 2C apart, and each new
// output row starts 2*W*C after the previous one.
//
// Parameters:
//   ADDR_W - address width (descriptor base fields are 16 bits)
//   DIM_W  - width of h, w, c (descriptor fields are 8 bits)
//
// Ports:
//   clk, rst            - clock, synchronous active-high reset (returns to idle)
//   i_start             - pulse: latch the configuration and start (ignored while busy)
//   i_src_base          - source base address
//   i_dst_base          - destination base address
//   i_h, i_w, i_c       - input height, width, channels
//   o_busy              - setup or scan in progress (low again after the last address is taken)
//   o_valid, i_ready    - address stream handshake
//   o_addr              - source address
//   o_first, o_last     - first / last read of a window
//   o_dst               - destination address of the current window's output element
//   o_end               - marks the very last read of the layer
//
// Latency: setup takes about W cycles; then one address per cycle when not back-pressured.
// Not part of any interface.
module agen_pool #(
    parameter int ADDR_W = 16,
    parameter int DIM_W  = 8
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              i_start,
    input  logic [ADDR_W-1:0] i_src_base,
    input  logic [ADDR_W-1:0] i_dst_base,
    input  logic [ DIM_W-1:0] i_h,
    input  logic [ DIM_W-1:0] i_w,
    input  logic [ DIM_W-1:0] i_c,
    output logic              o_busy,
    output logic              o_valid,
    input  logic              i_ready,
    output logic [ADDR_W-1:0] o_addr,
    output logic              o_first,
    output logic              o_last,
    output logic [ADDR_W-1:0] o_dst,
    output logic              o_end
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_STRIDE,
    S_RUN
  } state_t;

  state_t state_q;

  logic [ADDR_W-1:0] src_base_q, dst_base_q;
  logic [ DIM_W-1:0] h_q, w_q, c_q, cnt_q;
  logic [ADDR_W-1:0] row_stride_q;  // W * C
  logic [ADDR_W-1:0] c_ext;
  logic [ DIM_W-1:0] h_out, w_out;

  assign c_ext = ADDR_W'(c_q);
  assign h_out = h_q >> 1;
  assign w_out = w_q >> 1;

  // Scan state.
  logic [ DIM_W-1:0] oy_q, ox_q, ci_q;
  logic [       1:0] phase_q;  // window position: 0 (0,0), 1 (0,1), 2 (1,0), 3 (1,1)
  logic [ADDR_W-1:0] row_start_q;  // offset of (2oy, 0)
  logic [ADDR_W-1:0] win_q;  // offset of (2oy, 2ox)
  logic [ADDR_W-1:0] out_idx_q;

  logic [ADDR_W-1:0] phase_off, cur_addr;
  logic last_c, last_ox, last_oy, elem_end, scan_end;

  always_comb begin
    case (phase_q)
      2'd0: phase_off = '0;
      2'd1: phase_off = c_ext;
      2'd2: phase_off = row_stride_q;
      default: phase_off = row_stride_q + c_ext;
    endcase
  end

  assign cur_addr = src_base_q + win_q + ADDR_W'(ci_q) + phase_off;
  assign last_c   = (ci_q == c_q - DIM_W'(1));
  assign last_ox  = (ox_q == w_out - DIM_W'(1));
  assign last_oy  = (oy_q == h_out - DIM_W'(1));
  assign elem_end = (phase_q == 2'd3);
  assign scan_end = elem_end && last_c && last_ox && last_oy;

  // ---------------------------------------------------------------- output register
  logic out_load;
  assign out_load = (state_q == S_RUN) && (!o_valid || i_ready);

  always_ff @(posedge clk) begin
    if (rst) begin
      o_valid <= 1'b0;
    end else if (out_load) begin
      o_valid <= 1'b1;
    end else if (i_ready) begin
      o_valid <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (out_load) begin
      o_addr  <= cur_addr;
      o_first <= (phase_q == 2'd0);
      o_last  <= elem_end;
      o_dst   <= dst_base_q + out_idx_q;
      o_end   <= scan_end;
    end
  end

  // ---------------------------------------------------------------- control
  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (i_start) begin
            state_q      <= S_STRIDE;
            src_base_q   <= i_src_base;
            dst_base_q   <= i_dst_base;
            h_q          <= i_h;
            w_q          <= i_w;
            c_q          <= i_c;
            cnt_q        <= '0;
            row_stride_q <= '0;
          end
        end
        S_STRIDE: begin  // row_stride = W * C by repeated addition
          if (cnt_q == w_q) begin
            if ((h_out == '0) || (w_out == '0) || (c_q == '0)) begin
              state_q <= S_IDLE;  // nothing to pool
            end else begin
              state_q     <= S_RUN;
              oy_q        <= '0;
              ox_q        <= '0;
              ci_q        <= '0;
              phase_q     <= '0;
              row_start_q <= '0;
              win_q       <= '0;
              out_idx_q   <= '0;
            end
          end else begin
            cnt_q        <= cnt_q + DIM_W'(1);
            row_stride_q <= row_stride_q + c_ext;
          end
        end
        S_RUN: begin
          if (out_load) begin
            phase_q <= phase_q + 2'd1;
            if (elem_end) begin
              out_idx_q <= out_idx_q + ADDR_W'(1);
              if (!last_c) begin
                ci_q <= ci_q + DIM_W'(1);
              end else begin
                ci_q <= '0;
                if (!last_ox) begin
                  ox_q  <= ox_q + DIM_W'(1);
                  win_q <= win_q + c_ext + c_ext;
                end else begin
                  ox_q        <= '0;
                  oy_q        <= oy_q + DIM_W'(1);
                  row_start_q <= row_start_q + row_stride_q + row_stride_q;
                  win_q       <= row_start_q + row_stride_q + row_stride_q;
                end
              end
              if (scan_end) begin
                state_q <= S_IDLE;
              end
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign o_busy = (state_q != S_IDLE) || o_valid;

endmodule
