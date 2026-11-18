// gemm_engine: executes one CONV or FC layer as tiled GEMMs on the systolic array (spec §4-§9).
//
// Structure (docs/decisions.md D-023): three FSMs linked by start/done handshakes and run one
// after another by a small sequencer, for each row tile, column tile and K chunk:
//   A load  - asks agen_a to stage the chunk, reads the source buffer (1-cycle latency) and
//             writes the staging banks (one byte-wide bank per tile row)
//   stream  - reads all banks plus one WGT word per step and presents N A-values and N
//             B-values per cycle to the array; banks of rows outside the tile are fed as zeros
//   drain   - prefetches the column tile's N parameter words, pulses i_drain, captures each
//             result row into a row register, and feeds the valid elements one per cycle to
//             postproc; results are written back to the destination buffer (CONV, int8) or the
//             logit register file (FC, int32)
// The row register sits between the array's row multiplexer and postproc, so the drain path is
// registered at the array boundary.
//
// Addresses use only adders:
//   WGT word   = wgt_base + nt*K + k0 + kpos   (nt*K and k0 accumulated per column tile/chunk)
//   PARAM word = param_base + nt*N + j
//   output     = dst_base + m*C_out + nt*N + j (m*C_out accumulated per row, N*C_out per tile)
//
// Parameters:
//   N, DATA_W, ACC_W - systolic array size and widths (spec §1)
//   K_TILE           - staging bank depth (K chunk length)
//   ADDR_W           - buffer address width (descriptor base fields)
//   WGT_DEPTH        - WGT buffer depth (words of N*DATA_W bits)
//   PARAM_DEPTH      - PARAM buffer depth (64-bit words)
//
// Ports:
//   clk, rst          - clock, synchronous active-high reset (aborts the layer)
//   i_start           - pulse: start the layer described by the i_cfg_* inputs (only when idle)
//   o_busy            - high from i_start through the o_done cycle
//   o_done            - one-cycle pulse when every result of the layer has been written
//   i_fc              - 1: FC (linear A, int32 logits); 0: CONV (im2col A, int8 activations)
//   i_relu_en         - ReLU after requantization (CONV)
//   i_requant_en      - requantize to int8 (CONV); 0 bypasses (FC)
//   i_src_base        - effective source base (the sequencer adds IMG_SEL * IMG_SIZE)
//   i_dst_base        - destination base (ACT byte address, or LOGIT index for FC)
//   i_h, i_w, i_c_in  - input shape
//   i_c_out           - output channels (GEMM Ncols)
//   i_wgt_base        - WGT word address of the layer's packed B
//   i_param_base      - PARAM word address of channel 0
//     (all i_cfg inputs must stay stable while o_busy is high)
//   o_src_re/addr, i_src_rdata  - source buffer read port (1-cycle latency, spec §5)
//   o_wgt_re/addr, i_wgt_rdata  - WGT read port (1-cycle latency)
//   o_prm_re/addr, i_prm_rdata  - PARAM read port (1-cycle latency)
//   o_dst_we/addr/wdata         - destination activation write port (CONV)
//   o_logit_we/idx/wdata        - logit register write port (FC)
//   o_mac_active                - the array consumes a reduction step this cycle (perf counter)
//
// Latency: data-dependent (tile counts, chunking, staging); not part of any interface.
module gemm_engine #(
    parameter int N           = 8,
    parameter int DATA_W      = 8,
    parameter int ACC_W       = 32,
    parameter int K_TILE      = 128,
    parameter int ADDR_W      = 16,
    parameter int WGT_DEPTH   = 1024,
    parameter int PARAM_DEPTH = 64
) (
    input  logic                             clk,
    input  logic                             rst,
    input  logic                             i_start,
    output logic                             o_busy,
    output logic                             o_done,
    input  logic                             i_fc,
    input  logic                             i_relu_en,
    input  logic                             i_requant_en,
    input  logic [               ADDR_W-1:0] i_src_base,
    input  logic [               ADDR_W-1:0] i_dst_base,
    input  logic [                      7:0] i_h,
    input  logic [                      7:0] i_w,
    input  logic [                      7:0] i_c_in,
    input  logic [                      7:0] i_c_out,
    input  logic [                     15:0] i_wgt_base,
    input  logic [                      7:0] i_param_base,
    output logic                             o_src_re,
    output logic [               ADDR_W-1:0] o_src_addr,
    input  logic [               DATA_W-1:0] i_src_rdata,
    output logic                             o_wgt_re,
    output logic [   $clog2(WGT_DEPTH)-1:0]  o_wgt_addr,
    input  logic [             N*DATA_W-1:0] i_wgt_rdata,
    output logic                             o_prm_re,
    output logic [ $clog2(PARAM_DEPTH)-1:0]  o_prm_addr,
    input  logic [                     63:0] i_prm_rdata,
    output logic                             o_dst_we,
    output logic [               ADDR_W-1:0] o_dst_addr,
    output logic [                      7:0] o_dst_wdata,
    output logic                             o_logit_we,
    output logic [               ADDR_W-1:0] o_logit_idx,
    output logic [                     31:0] o_logit_wdata,
    output logic                             o_mac_active
);

  localparam int K_W = 16;
  localparam int KP_W = $clog2(K_TILE);
  localparam int ROW_W = $clog2(N > 1 ? N : 2);
  localparam int WGT_AW = $clog2(WGT_DEPTH);
  localparam int PRM_AW = $clog2(PARAM_DEPTH);
  localparam logic [ROW_W-1:0] LAST_ROW = ROW_W'(N - 1);
  localparam logic [K_W-1:0] K_TILE_W = K_W'(K_TILE);
  localparam logic [1:0] CMD_STAGE = 2'd0;
  localparam logic [1:0] CMD_NEXT_CHUNK = 2'd1;
  localparam logic [1:0] CMD_REWIND_K = 2'd2;
  localparam logic [1:0] CMD_NEXT_TILE = 2'd3;

  // ================================================================ shared datapath
  // ---------------------------------------------------------------- address generator
  logic agen_init, agen_cmd_ready, agen_cmd_valid, agen_tile_valid;
  logic [1:0] agen_cmd;
  logic [K_W-1:0] agen_kc_len, k_len;
  logic [N-1:0] agen_mask;
  logic agen_valid, agen_ready, agen_last;
  logic [ADDR_W-1:0] agen_addr;
  logic [ROW_W-1:0] agen_bank;
  // Lint waiver: a position inside a chunk is always < K_TILE, so only its low KP_W bits
  // address a staging bank; the generator keeps K_W bits because K itself needs them.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [K_W-1:0] agen_kpos;
  /* verilator lint_on UNUSEDSIGNAL */

  agen_a #(
      .N     (N),
      .ADDR_W(ADDR_W),
      .DIM_W (8),
      .K_W   (K_W)
  ) u_agen_a (
      .clk         (clk),
      .rst         (rst),
      .i_init      (agen_init),
      .i_fc        (i_fc),
      .i_base      (i_src_base),
      .i_h         (i_h),
      .i_w         (i_w),
      .i_c         (i_c_in),
      .o_cmd_ready (agen_cmd_ready),
      .i_cmd_valid (agen_cmd_valid),
      .i_cmd       (agen_cmd),
      .i_kc_len    (agen_kc_len),
      .o_k_len     (k_len),
      .o_tile_valid(agen_tile_valid),
      .o_row_mask  (agen_mask),
      .o_valid     (agen_valid),
      .i_ready     (agen_ready),
      .o_addr      (agen_addr),
      .o_bank      (agen_bank),
      .o_kpos      (agen_kpos),
      .o_last      (agen_last)
  );

  // ---------------------------------------------------------------- staging banks
  logic [N-1:0] bank_we;
  logic [KP_W-1:0] bank_waddr, bank_raddr;
  logic [DATA_W-1:0] bank_wdata;
  logic bank_re;
  logic [N*DATA_W-1:0] bank_rdata;

  genvar gi;
  generate
    for (gi = 0; gi < N; gi = gi + 1) begin : g_bank
      sram_1r1w #(
          .WIDTH(DATA_W),
          .DEPTH(K_TILE)
      ) u_sram_1r1w (
          .clk    (clk),
          .i_we   (bank_we[gi]),
          .i_waddr(bank_waddr),
          .i_wdata(bank_wdata),
          .i_re   (bank_re),
          .i_raddr(bank_raddr),
          .o_rdata(bank_rdata[gi*DATA_W+:DATA_W])
      );
    end
  endgenerate

  // ---------------------------------------------------------------- systolic array
  logic arr_clear, arr_valid, arr_drain, arr_row_valid, arr_row_ready, arr_row_last, arr_idle;
  logic [N*DATA_W-1:0] arr_a, arr_b;
  logic [ N*ACC_W-1:0] arr_row_data;

  systolic_array #(
      .N     (N),
      .DATA_W(DATA_W),
      .ACC_W (ACC_W)
  ) u_systolic_array (
      .clk        (clk),
      .rst        (rst),
      .i_clear    (arr_clear),
      .i_valid    (arr_valid),
      .i_a        (arr_a),
      .i_b        (arr_b),
      .i_drain    (arr_drain),
      .o_row_valid(arr_row_valid),
      .i_row_ready(arr_row_ready),
      .o_row_data (arr_row_data),
      .o_row_last (arr_row_last),
      .o_idle     (arr_idle)
  );

  // ---------------------------------------------------------------- post-processing
  logic pp_valid, pp_ready, pp_out_valid;
  logic [ACC_W-1:0] pp_acc, pp_bias, pp_y;
  logic [15:0] pp_m;
  logic [5:0] pp_s;
  logic [ADDR_W-1:0] pp_tag, pp_out_tag;
  logic [7:0] pp_q8;

  postproc #(
      .ACC_W(ACC_W),
      .TAG_W(ADDR_W)
  ) u_postproc (
      .clk         (clk),
      .rst         (rst),
      .i_valid     (pp_valid),
      .o_ready     (pp_ready),
      .i_acc       (pp_acc),
      .i_bias      (pp_bias),
      .i_m         (pp_m),
      .i_s         (pp_s),
      .i_requant_en(i_requant_en),
      .i_relu_en   (i_relu_en),
      .i_tag       (pp_tag),
      .o_valid     (pp_out_valid),
      .i_ready     (1'b1),
      .o_q8        (pp_q8),
      .o_y         (pp_y),
      .o_tag       (pp_out_tag)
  );

  // Write-back: no backpressure on the destination ports.
  assign o_dst_we      = pp_out_valid && !i_fc;
  assign o_dst_addr    = pp_out_tag;
  assign o_dst_wdata   = pp_q8;
  assign o_logit_we    = pp_out_valid && i_fc;
  assign o_logit_idx   = pp_out_tag;
  assign o_logit_wdata = pp_y;

  // ================================================================ sequencer state shared by FSMs
  logic [N-1:0] mask_q;  // valid rows of the current row tile
  logic [K_W-1:0] k0_q, kc_len_q;  // current K chunk
  logic [7:0] col_base_q;  // nt * N
  logic [15:0] wgt_tile_q;  // wgt_base + nt * K
  logic [ADDR_W-1:0] tile_out_q;  // dst_base + m0 * C_out

  // ================================================================ FSM 1: A load
  logic load_start, load_done;
  logic load_busy_q;
  logic wr_v_q, wr_last_q;
  logic [ROW_W-1:0] wr_bank_q;
  logic [KP_W-1:0] wr_kpos_q;

  assign agen_ready = load_busy_q;
  assign o_src_re   = load_busy_q && agen_valid;
  assign o_src_addr = agen_addr;

  always_ff @(posedge clk) begin
    if (rst) begin
      load_busy_q <= 1'b0;
      wr_v_q      <= 1'b0;
    end else begin
      if (load_start) begin
        load_busy_q <= 1'b1;
      end else if (load_busy_q && agen_valid && agen_last) begin
        load_busy_q <= 1'b0;
      end
      wr_v_q <= load_busy_q && agen_valid;
    end
  end

  always_ff @(posedge clk) begin
    if (load_busy_q && agen_valid) begin
      wr_bank_q <= agen_bank;
      wr_kpos_q <= KP_W'(agen_kpos);
      wr_last_q <= agen_last;
    end
  end

  // Source data returns one cycle after the read: write it into the bank of its tile row.
  always_comb begin
    bank_we = '0;
    if (wr_v_q) begin
      bank_we[wr_bank_q] = 1'b1;
    end
  end
  assign bank_waddr = wr_kpos_q;
  assign bank_wdata = i_src_rdata;
  assign load_done  = wr_v_q && wr_last_q;

  // ================================================================ FSM 2: stream
  logic stream_start, stream_done;
  logic stream_busy_q, step_v_q, step_last_q;
  logic [K_W-1:0] kpos_q;
  logic stream_last_issue;

  assign stream_last_issue = (kpos_q == kc_len_q - K_W'(1));
  assign bank_re = stream_busy_q;
  assign bank_raddr = KP_W'(kpos_q);
  assign o_wgt_re = stream_busy_q;
  assign o_wgt_addr = WGT_AW'(wgt_tile_q + k0_q + kpos_q);

  always_ff @(posedge clk) begin
    if (rst) begin
      stream_busy_q <= 1'b0;
      step_v_q      <= 1'b0;
      step_last_q   <= 1'b0;
    end else begin
      step_v_q    <= stream_busy_q;
      step_last_q <= stream_busy_q && stream_last_issue;
      if (stream_start) begin
        stream_busy_q <= 1'b1;
        kpos_q        <= '0;
      end else if (stream_busy_q) begin
        if (stream_last_issue) begin
          stream_busy_q <= 1'b0;
        end
        kpos_q <= kpos_q + K_W'(1);
      end
    end
  end

  // Bank and WGT data arrive one cycle after the reads: present them as one step.
  genvar gr;
  generate
    for (gr = 0; gr < N; gr = gr + 1) begin : g_amask
      assign arr_a[gr*DATA_W+:DATA_W] = mask_q[gr] ? bank_rdata[gr*DATA_W+:DATA_W] : '0;
    end
  endgenerate
  assign arr_b        = i_wgt_rdata;
  assign arr_valid    = step_v_q;
  assign o_mac_active = step_v_q;
  assign stream_done  = step_last_q;

  // ================================================================ FSM 3: drain
  typedef enum logic [2:0] {
    D_IDLE,
    D_PRM,
    D_PULSE,
    D_ROW,
    D_ELEM,
    D_FLUSH
  } dstate_t;

  dstate_t dstate_q;
  logic drain_start, drain_done;
  logic [ROW_W-1:0] prm_idx_q, prm_wr_idx_q, row_idx_q, col_q;
  logic prm_wr_q;
  logic [63:0] prm_q[N];
  logic [N*ACC_W-1:0] row_q;  // row register between the array and postproc
  logic row_last_q;
  logic [ADDR_W-1:0] row_out_q;  // dst_base + m * C_out for the current row
  logic [3:0] inflight_q;
  logic elem_valid, pp_push, pp_pop;
  logic [7:0] col_n;

  assign o_prm_re   = (dstate_q == D_PRM);
  assign o_prm_addr = PRM_AW'(i_param_base + col_base_q + 8'(prm_idx_q));

  assign arr_drain     = (dstate_q == D_PULSE);
  assign arr_row_ready = (dstate_q == D_ROW);

  assign col_n      = col_base_q + 8'(col_q);
  assign elem_valid = mask_q[row_idx_q] && (col_n < i_c_out);
  assign pp_valid   = (dstate_q == D_ELEM) && elem_valid;
  assign pp_push    = pp_valid && pp_ready;
  assign pp_pop     = pp_out_valid;  // write-back always accepts
  assign pp_acc     = row_q[col_q*ACC_W+:ACC_W];
  assign pp_bias    = prm_q[col_q][31:0];
  assign pp_m       = prm_q[col_q][47:32];
  assign pp_s       = prm_q[col_q][53:48];
  assign pp_tag     = row_out_q + ADDR_W'(col_n);

  always_ff @(posedge clk) begin
    if (rst) begin
      dstate_q   <= D_IDLE;
      prm_wr_q   <= 1'b0;
      inflight_q <= '0;
    end else begin
      prm_wr_q <= (dstate_q == D_PRM);
      if (pp_push && !pp_pop) begin
        inflight_q <= inflight_q + 4'd1;
      end else if (!pp_push && pp_pop) begin
        inflight_q <= inflight_q - 4'd1;
      end
      case (dstate_q)
        D_IDLE: begin
          if (drain_start) begin
            dstate_q  <= D_PRM;
            prm_idx_q <= '0;
            row_idx_q <= '0;
            row_out_q <= tile_out_q;
          end
        end
        D_PRM: begin  // prefetch the column tile's N parameter words (one per cycle)
          prm_wr_idx_q <= prm_idx_q;
          if (prm_idx_q == LAST_ROW) begin
            dstate_q <= D_PULSE;
          end else begin
            prm_idx_q <= prm_idx_q + ROW_W'(1);
          end
        end
        D_PULSE: begin
          dstate_q <= D_ROW;
        end
        D_ROW: begin
          if (arr_row_valid) begin
            row_q      <= arr_row_data;
            row_last_q <= arr_row_last;
            col_q      <= '0;
            dstate_q   <= D_ELEM;
          end
        end
        D_ELEM: begin
          if (!elem_valid || pp_ready) begin
            if (col_q == LAST_ROW) begin
              row_out_q <= row_out_q + ADDR_W'(i_c_out);
              if (row_last_q) begin
                dstate_q <= D_FLUSH;
              end else begin
                row_idx_q <= row_idx_q + ROW_W'(1);
                dstate_q  <= D_ROW;
              end
            end else begin
              col_q <= col_q + ROW_W'(1);
            end
          end
        end
        D_FLUSH: begin
          if (inflight_q == '0 && !pp_out_valid) begin
            dstate_q <= D_IDLE;
          end
        end
        default: dstate_q <= D_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (prm_wr_q) begin
      prm_q[prm_wr_idx_q] <= i_prm_rdata;
    end
  end

  assign drain_done = (dstate_q == D_FLUSH) && (inflight_q == '0) && !pp_out_valid;

  // ================================================================ sequencer
  typedef enum logic [3:0] {
    Q_IDLE,
    Q_SETUP,
    Q_TILE,
    Q_CLEAR,
    Q_STAGE,
    Q_LOAD,
    Q_STREAM,
    Q_CMD,
    Q_DRAIN,
    Q_NEXT,
    Q_DONE
  } qstate_t;

  qstate_t qstate_q;
  logic [1:0] next_cmd_q;
  logic last_chunk, last_col;
  logic [K_W-1:0] k_rem;

  assign k_rem      = k_len - k0_q;
  assign last_chunk = (k0_q + kc_len_q == k_len);
  assign last_col   = ({1'b0, col_base_q} + 9'(N) >= {1'b0, i_c_out});

  assign agen_init      = (qstate_q == Q_IDLE) && i_start;
  assign agen_cmd_valid = (qstate_q == Q_STAGE) || (qstate_q == Q_CMD);
  assign agen_cmd       = (qstate_q == Q_STAGE) ? CMD_STAGE : next_cmd_q;
  assign agen_kc_len    = kc_len_q;

  assign arr_clear    = (qstate_q == Q_CLEAR) && arr_idle;
  assign load_start   = (qstate_q == Q_STAGE) && agen_cmd_ready;
  assign stream_start = (qstate_q == Q_LOAD) && load_done;
  assign drain_start  = (qstate_q == Q_CMD) && agen_cmd_ready && last_chunk;

  always_ff @(posedge clk) begin
    if (rst) begin
      qstate_q <= Q_IDLE;
    end else begin
      case (qstate_q)
        Q_IDLE: begin
          if (i_start) begin
            qstate_q   <= Q_SETUP;
            tile_out_q <= i_dst_base;
          end
        end
        Q_SETUP, Q_NEXT: begin  // wait for agen setup / tile scan / chunk command
          if (agen_cmd_ready) begin
            qstate_q <= Q_TILE;
          end
        end
        Q_TILE: begin  // start a row tile (or finish the layer)
          if (!agen_tile_valid || (i_c_out == '0)) begin
            qstate_q <= Q_DONE;
          end else begin
            mask_q     <= agen_mask;
            col_base_q <= '0;
            wgt_tile_q <= i_wgt_base;
            k0_q       <= '0;
            kc_len_q   <= (k_len > K_TILE_W) ? K_TILE_W : k_len;
            qstate_q   <= Q_CLEAR;
          end
        end
        Q_CLEAR: begin  // new output tile: clear the accumulators once the array is idle
          if (arr_idle) begin
            qstate_q <= Q_STAGE;
          end
        end
        Q_STAGE: begin
          if (agen_cmd_ready) begin
            qstate_q <= Q_LOAD;
          end
        end
        Q_LOAD: begin
          if (load_done) begin
            qstate_q <= Q_STREAM;
          end
        end
        Q_STREAM: begin
          if (stream_done) begin
            qstate_q <= Q_CMD;
            if (!last_chunk) begin
              next_cmd_q <= CMD_NEXT_CHUNK;
            end else if (!last_col) begin
              next_cmd_q <= CMD_REWIND_K;
            end else begin
              next_cmd_q <= CMD_NEXT_TILE;
            end
          end
        end
        Q_CMD: begin
          if (agen_cmd_ready) begin
            if (!last_chunk) begin
              k0_q     <= k0_q + kc_len_q;
              kc_len_q <= (k_rem - kc_len_q > K_TILE_W) ? K_TILE_W : (k_rem - kc_len_q);
              qstate_q <= Q_STAGE;
            end else begin
              qstate_q <= Q_DRAIN;
            end
          end
        end
        Q_DRAIN: begin
          if (drain_done) begin
            k0_q     <= '0;
            kc_len_q <= (k_len > K_TILE_W) ? K_TILE_W : k_len;
            if (!last_col) begin
              col_base_q <= col_base_q + 8'(N);
              wgt_tile_q <= wgt_tile_q + k_len;
              qstate_q   <= Q_CLEAR;
            end else begin
              tile_out_q <= row_out_q;  // dst_base + (m0 + N) * C_out
              qstate_q   <= Q_NEXT;
            end
          end
        end
        Q_DONE: begin
          qstate_q <= Q_IDLE;
        end
        default: qstate_q <= Q_IDLE;
      endcase
    end
  end

  assign o_busy = (qstate_q != Q_IDLE);
  assign o_done = (qstate_q == Q_DONE);

endmodule
