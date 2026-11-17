// agen_a: A-operand address generator for the GEMM engine (spec §4, §5): im2col for CONV,
// linear for FC. Uses only incremental counters and adders (no multipliers).
//
// The engine computes C = A * B in N-row tiles. For each (row tile, column tile, K chunk) it
// asks this block to "stage" the tile's A chunk: one source-buffer address per (row, k) pair,
// row by row, k fastest. Rows of the tile that lie beyond the last output pixel (m >= M) are
// never emitted; o_row_mask tells the engine which staging banks hold valid rows (it feeds
// zeros for the others).
//
//   CONV: A[m][k] at src_base + ((oy + ky) * W + (ox + kx)) * C + ci,
//         m = oy * W_out + ox, k = (ky * 3 + kx) * C + ci, W_out = W - 2, H_out = H - 2
//   FC:   A[0][k] at src_base + k for k < K = H * W * C; one row (M = 1)
//
// A layer with K = 0 (C = 0, or an empty FC input) has no valid tiles: o_tile_valid stays low.
//
// Products are formed without multipliers: the row stride W*C (and, for FC, K = H*W*C) is
// accumulated by repeated addition during setup; 9*C is (C << 3) + C. Within one kernel row the
// 3*C bytes are contiguous, so k advances the address by 1 except at kernel-row wraps.
//
// Command sequence (engine): i_init, wait for o_cmd_ready, then for each row tile with
// o_tile_valid: for each column tile: for each K chunk: CMD_STAGE (i_kc_len), then
// CMD_NEXT_CHUNK (more chunks), CMD_REWIND_K (next column tile) or CMD_NEXT_TILE (next tile).
//
// Parameters:
//   N      - tile rows (systolic array size)
//   ADDR_W - address width (descriptor base fields are 16 bits)
//   DIM_W  - width of h, w, c (descriptor fields are 8 bits)
//   K_W    - width of K and of the chunk length/position
//
// Ports:
//   clk, rst         - clock, synchronous active-high reset (returns to idle, no config)
//   i_init           - pulse: latch i_fc, i_base, i_h, i_w, i_c and start setup (any state)
//   i_fc             - 1: linear (FC) mode, 0: im2col (CONV) mode
//   i_base           - source base address (bytes)
//   i_h, i_w, i_c    - input height, width, channels
//   o_cmd_ready      - setup finished and no stage/scan in progress: a command may be issued
//   i_cmd_valid      - command handshake (accepted when i_cmd_valid && o_cmd_ready)
//   i_cmd            - CMD_STAGE, CMD_NEXT_CHUNK, CMD_REWIND_K, CMD_NEXT_TILE
//   i_kc_len         - chunk length for CMD_STAGE (1..K_TILE)
//   o_k_len          - K for this layer (valid when o_cmd_ready)
//   o_tile_valid     - the current row tile has at least one valid row (valid when o_cmd_ready)
//   o_row_mask       - bit i: row i of the current tile is a valid output row
//   o_valid, i_ready - address stream handshake
//   o_addr           - source address of A[row][k]
//   o_bank           - staging bank (tile row) index
//   o_kpos           - position within the chunk (staging bank address)
//   o_last           - last address of this stage
//
// Latency: setup takes about W (+ H for FC) cycles, a tile scan N cycles; a stage emits one
// address per cycle when not back-pressured. None of these latencies is part of an interface.
module agen_a #(
    parameter int N      = 8,
    parameter int ADDR_W = 16,
    parameter int DIM_W  = 8,
    parameter int K_W    = 16
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 i_init,
    input  logic                 i_fc,
    input  logic [   ADDR_W-1:0] i_base,
    input  logic [    DIM_W-1:0] i_h,
    input  logic [    DIM_W-1:0] i_w,
    input  logic [    DIM_W-1:0] i_c,
    output logic                 o_cmd_ready,
    input  logic                 i_cmd_valid,
    input  logic [          1:0] i_cmd,
    input  logic [      K_W-1:0] i_kc_len,
    output logic [      K_W-1:0] o_k_len,
    output logic                 o_tile_valid,
    output logic [        N-1:0] o_row_mask,
    output logic                 o_valid,
    input  logic                 i_ready,
    output logic [   ADDR_W-1:0] o_addr,
    output logic [$clog2(N > 1 ? N : 2)-1:0] o_bank,
    output logic [      K_W-1:0] o_kpos,
    output logic                 o_last
);

  localparam logic [1:0] CMD_STAGE = 2'd0;
  localparam logic [1:0] CMD_NEXT_CHUNK = 2'd1;
  localparam logic [1:0] CMD_REWIND_K = 2'd2;
  localparam logic [1:0] CMD_NEXT_TILE = 2'd3;

  localparam int ROW_W = $clog2(N > 1 ? N : 2);
  localparam logic [ROW_W-1:0] LAST_ROW = ROW_W'(N - 1);

  typedef enum logic [2:0] {
    S_IDLE,
    S_STRIDE,
    S_KLEN,
    S_SCAN,
    S_READY,
    S_STAGE
  } state_t;

  state_t state_q;

  // ---------------------------------------------------------------- configuration
  logic              fc_q;
  logic [ADDR_W-1:0] base_q;
  logic [ DIM_W-1:0] h_q, w_q, c_q;
  logic [ADDR_W-1:0] row_stride_q;  // W * C
  logic [   K_W-1:0] k_len_q;
  logic [ DIM_W-1:0] cnt_q;  // setup loop counter
  logic [ADDR_W-1:0] c_ext;
  logic [ DIM_W-1:0] h_out, w_out;
  logic              has_pixels;

  assign c_ext      = ADDR_W'(c_q);
  assign h_out      = h_q - DIM_W'(2);
  assign w_out      = w_q - DIM_W'(2);
  assign has_pixels = (h_q >= DIM_W'(3)) && (w_q >= DIM_W'(3)) && (c_q != '0);

  // ---------------------------------------------------------------- pixel cursor
  // A pixel position (oy, ox) and its offset (oy * W + ox) * C. Stepping moves to the next
  // output pixel in raster order: +C, or +3C at the end of an output row (W - W_out = 2).
  logic [DIM_W-1:0] t_oy_q, t_ox_q, n_oy_q, n_ox_q, r_oy_q, r_ox_q;
  logic [ADDR_W-1:0] t_pix_q, n_pix_q, r_pix_q;
  logic [ROW_W-1:0] r_idx_q;
  logic [N-1:0] mask_q;
  logic fc_tile_used_q;  // FC: the single row tile has been passed

  logic [DIM_W-1:0] step_oy, step_ox;
  logic [ADDR_W-1:0] step_pix;
  logic cur_valid;

  always_comb begin
    if (r_ox_q == w_out - DIM_W'(1)) begin
      step_ox  = '0;
      step_oy  = r_oy_q + DIM_W'(1);
      step_pix = r_pix_q + c_ext + c_ext + c_ext;
    end else begin
      step_ox  = r_ox_q + DIM_W'(1);
      step_oy  = r_oy_q;
      step_pix = r_pix_q + c_ext;
    end
  end

  assign cur_valid = fc_q ? (!fc_tile_used_q && (r_idx_q == '0) && (k_len_q != '0))
                          : (has_pixels && (r_oy_q < h_out));

  // ---------------------------------------------------------------- reduction-index cursor
  // k = (ky * 3 + kx) * C + ci; offset ky * W*C + kx * C + ci. FC: ci counts k linearly.
  logic [K_W-1:0] cs_ci_q, ce_ci_q, k_ci_q;  // chunk start / chunk end / current
  logic [1:0] cs_kx_q, ce_kx_q, k_kx_q;
  logic [1:0] cs_ky_q, ce_ky_q, k_ky_q;
  logic [ADDR_W-1:0] cs_kxo_q, ce_kxo_q, k_kxo_q;
  logic [ADDR_W-1:0] cs_kyo_q, ce_kyo_q, k_kyo_q;
  logic [K_W-1:0] kpos_q, kc_len_q;

  logic [K_W-1:0] kn_ci;
  logic [1:0] kn_kx, kn_ky;
  logic [ADDR_W-1:0] kn_kxo, kn_kyo;

  always_comb begin
    kn_ci  = k_ci_q + K_W'(1);
    kn_kx  = k_kx_q;
    kn_ky  = k_ky_q;
    kn_kxo = k_kxo_q;
    kn_kyo = k_kyo_q;
    if (!fc_q && (k_ci_q == K_W'(c_q) - K_W'(1))) begin
      kn_ci = '0;
      if (k_kx_q == 2'd2) begin
        kn_kx  = 2'd0;
        kn_kxo = '0;
        kn_ky  = k_ky_q + 2'd1;
        kn_kyo = k_kyo_q + row_stride_q;
      end else begin
        kn_kx  = k_kx_q + 2'd1;
        kn_kxo = k_kxo_q + c_ext;
      end
    end
  end

  // ---------------------------------------------------------------- output register
  logic out_load;
  logic row_end, stage_end;
  logic [ADDR_W-1:0] cur_addr;

  assign cur_addr  = base_q + r_pix_q + k_kyo_q + k_kxo_q + ADDR_W'(k_ci_q);
  assign row_end   = (kpos_q == kc_len_q - K_W'(1));
  assign stage_end = row_end && ((r_idx_q == LAST_ROW) || !mask_q[r_idx_q+ROW_W'(1)]);
  assign out_load  = (state_q == S_STAGE) && (!o_valid || i_ready);

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
      o_addr <= cur_addr;
      o_bank <= r_idx_q;
      o_kpos <= kpos_q;
      o_last <= stage_end;
    end
  end

  // ---------------------------------------------------------------- control
  logic cmd_fire;
  assign cmd_fire = i_cmd_valid && (state_q == S_READY);

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
    end else if (i_init) begin
      state_q      <= S_STRIDE;
      fc_q         <= i_fc;
      base_q       <= i_base;
      h_q          <= i_h;
      w_q          <= i_w;
      c_q          <= i_c;
      row_stride_q <= '0;
      cnt_q        <= '0;
      // First tile and K chunk start at pixel 0, k = 0.
      t_oy_q         <= '0;
      t_ox_q         <= '0;
      t_pix_q        <= '0;
      fc_tile_used_q <= 1'b0;
      cs_ci_q        <= '0;
      cs_kx_q        <= '0;
      cs_ky_q        <= '0;
      cs_kxo_q       <= '0;
      cs_kyo_q       <= '0;
    end else begin
      case (state_q)
        S_STRIDE: begin  // row_stride = W * C by repeated addition
          if (cnt_q == w_q) begin
            cnt_q   <= '0;
            k_len_q <= '0;
            if (fc_q) begin
              state_q <= S_KLEN;
            end else begin
              k_len_q <= (K_W'(c_q) << 3) + K_W'(c_q);  // K = 9 * C
              state_q <= S_SCAN;
              r_idx_q <= '0;
              r_oy_q  <= '0;
              r_ox_q  <= '0;
              r_pix_q <= '0;
            end
          end else begin
            cnt_q        <= cnt_q + DIM_W'(1);
            row_stride_q <= row_stride_q + c_ext;
          end
        end
        S_KLEN: begin  // FC: K = H * (W * C) by repeated addition
          if (cnt_q == h_q) begin
            state_q <= S_SCAN;
            r_idx_q <= '0;
            r_oy_q  <= '0;
            r_ox_q  <= '0;
            r_pix_q <= '0;
          end else begin
            cnt_q   <= cnt_q + DIM_W'(1);
            k_len_q <= k_len_q + K_W'(row_stride_q);
          end
        end
        S_SCAN: begin  // walk N rows from the tile start: row mask and next tile start
          mask_q[r_idx_q] <= cur_valid;
          r_oy_q          <= step_oy;
          r_ox_q          <= step_ox;
          r_pix_q         <= step_pix;
          if (r_idx_q == LAST_ROW) begin
            n_oy_q  <= step_oy;
            n_ox_q  <= step_ox;
            n_pix_q <= step_pix;
            state_q <= S_READY;
          end else begin
            r_idx_q <= r_idx_q + ROW_W'(1);
          end
        end
        S_READY: begin
          if (cmd_fire) begin
            case (i_cmd)
              CMD_STAGE: begin
                state_q  <= S_STAGE;
                kc_len_q <= i_kc_len;
                kpos_q   <= '0;
                r_idx_q  <= '0;
                r_oy_q   <= t_oy_q;
                r_ox_q   <= t_ox_q;
                r_pix_q  <= t_pix_q;
                k_ci_q   <= cs_ci_q;
                k_kx_q   <= cs_kx_q;
                k_ky_q   <= cs_ky_q;
                k_kxo_q  <= cs_kxo_q;
                k_kyo_q  <= cs_kyo_q;
              end
              CMD_NEXT_CHUNK: begin
                cs_ci_q  <= ce_ci_q;
                cs_kx_q  <= ce_kx_q;
                cs_ky_q  <= ce_ky_q;
                cs_kxo_q <= ce_kxo_q;
                cs_kyo_q <= ce_kyo_q;
              end
              CMD_REWIND_K: begin
                cs_ci_q  <= '0;
                cs_kx_q  <= '0;
                cs_ky_q  <= '0;
                cs_kxo_q <= '0;
                cs_kyo_q <= '0;
              end
              CMD_NEXT_TILE: begin
                t_oy_q         <= n_oy_q;
                t_ox_q         <= n_ox_q;
                t_pix_q        <= n_pix_q;
                fc_tile_used_q <= fc_q;
                cs_ci_q        <= '0;
                cs_kx_q        <= '0;
                cs_ky_q        <= '0;
                cs_kxo_q       <= '0;
                cs_kyo_q       <= '0;
                state_q        <= S_SCAN;
                r_idx_q        <= '0;
                r_oy_q         <= n_oy_q;
                r_ox_q         <= n_ox_q;
                r_pix_q        <= n_pix_q;
              end
            endcase
          end
        end
        S_STAGE: begin
          if (out_load) begin
            if (row_end) begin
              // Every row covers the same k range: remember where it ends for CMD_NEXT_CHUNK.
              ce_ci_q  <= kn_ci;
              ce_kx_q  <= kn_kx;
              ce_ky_q  <= kn_ky;
              ce_kxo_q <= kn_kxo;
              ce_kyo_q <= kn_kyo;
              kpos_q   <= '0;
              k_ci_q   <= cs_ci_q;
              k_kx_q   <= cs_kx_q;
              k_ky_q   <= cs_ky_q;
              k_kxo_q  <= cs_kxo_q;
              k_kyo_q  <= cs_kyo_q;
              r_idx_q  <= r_idx_q + ROW_W'(1);
              r_oy_q   <= step_oy;
              r_ox_q   <= step_ox;
              r_pix_q  <= step_pix;
              if (stage_end) begin
                state_q <= S_READY;
              end
            end else begin
              kpos_q  <= kpos_q + K_W'(1);
              k_ci_q  <= kn_ci;
              k_kx_q  <= kn_kx;
              k_ky_q  <= kn_ky;
              k_kxo_q <= kn_kxo;
              k_kyo_q <= kn_kyo;
            end
          end
        end
        default: ;  // S_IDLE: wait for i_init
      endcase
    end
  end

  assign o_cmd_ready  = (state_q == S_READY);
  assign o_k_len      = k_len_q;
  assign o_row_mask   = mask_q;
  assign o_tile_valid = mask_q[0];

endmodule
