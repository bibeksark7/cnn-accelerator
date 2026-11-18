// layer_seq: runs the descriptor table (spec §8, §9) and owns the buffer ports (D-028).
//
// On an accepted START (idle, no memory-port read pending) it clears the performance counters,
// latches IMG_SEL, sets BUSY and executes descriptors 0, 1, 2, ... For each one it:
//   1. reads the descriptor's four words from the table (1-cycle-latency RAM) into registers;
//      every unit configuration output comes from these registers, so it is stable while the
//      unit runs;
//   2. checks it (spec §9 errors): a reserved op; a CONV, POOL or FC with dst = IMG or with
//      src = dst; a CONV or POOL with src = LOGIT or dst = LOGIT. An error ends the run with ERROR = 1, DONE = 1, BUSY = 0, without starting the
//      layer; STATUS keeps its index;
//   3. computes the effective source base: src_base + IMG_SEL * IMG_SIZE when src = IMG. The
//      image offset is computed once at START by shift-and-add over the set bits of the
//      constant IMG_SIZE (784 = 512 + 256 + 16), not with a multiplier;
//   4. gives the buffer ports to the unit (registered one-hot owner vectors, below), then
//      starts the unit with a one-cycle pulse and waits for its done pulse;
//   5. takes the ports back, and either ends the run (last = 1), reports an error (the
//      DESC_DEPTH-th descriptor had last = 0), or moves to the next descriptor.
//
// Buffer ownership (owner bit 0: memory port, 1: GEMM engine, 2: pool unit; WGT and PARAM have
// only bits 0 and 1). While idle the memory port owns every buffer. During a run, CONV and FC
// give the engine their src buffer, WGT and PARAM, and CONV also its dst buffer; POOL gives the
// pool unit its src and dst buffers; ARGMAX needs none (it reads the LOGIT registers). Between
// layers nobody owns anything. The owner registers change only while every unit is idle: they
// are loaded the cycle before a unit is started and cleared the cycle after it is done.
// Requests of a non-owner never reach a buffer (buf_port_mux), and src = LOGIT for an FC reads 0
// (not detected, spec §9).
//
// Parameters:
//   DESC_DEPTH - descriptor table depth (layers, <= 16)
//   IMG_SIZE   - bytes per input image
//
// Ports:
//   clk, rst                                - clock, synchronous active-high reset (ends a run)
//   i_start                                 - CTRL.START written
//   i_mem_pending                           - a memory-port read is pending (START ignored)
//   i_img_sel                               - IMG_SEL register
//   o_busy, o_done, o_error, o_layer        - STATUS fields
//   o_clear                                 - one-cycle pulse at an accepted START
//   o_layer_start, o_layer_done             - a layer's unit is started / reports done
//   o_desc_re, o_desc_raddr, i_desc_rdata   - descriptor table read port
//   o_op, o_relu_en, o_requant_en, o_src, o_dst, o_src_base, o_dst_base, o_h, o_w, o_c_in,
//   o_c_out, o_wgt_base, o_param_base       - registered descriptor fields (o_src_base is the
//                                             effective base); o_src also selects the read data
//                                             returned to the units
//   o_gemm_start, o_pool_start, o_argmax_start - unit start pulses
//   i_gemm_done, i_pool_done, i_argmax_done - unit done pulses
//   o_own_img, o_own_act0, o_own_act1, o_own_wgt, o_own_prm - owner vectors (registered)
//
// Latency: about 6 cycles of descriptor handling per layer plus the unit's run time.
module layer_seq #(
    parameter int DESC_DEPTH = 8,
    parameter int IMG_SIZE   = 784
) (
    input  logic                                            clk,
    input  logic                                            rst,
    input  logic                                            i_start,
    input  logic                                            i_mem_pending,
    input  logic [                                     3:0] i_img_sel,
    output logic                                            o_busy,
    output logic                                            o_done,
    output logic                                            o_error,
    output logic [(DESC_DEPTH > 1 ? $clog2(DESC_DEPTH) : 1)-1:0] o_layer,
    output logic                                            o_clear,
    output logic                                            o_layer_start,
    output logic                                            o_layer_done,
    output logic                                            o_desc_re,
    output logic [                  $clog2(4*DESC_DEPTH)-1:0] o_desc_raddr,
    input  logic [                                    31:0] i_desc_rdata,
    output logic [                                     2:0] o_op,
    output logic                                            o_relu_en,
    output logic                                            o_requant_en,
    output logic [                                     1:0] o_src,
    output logic [                                     1:0] o_dst,
    output logic [                                    15:0] o_src_base,
    output logic [                                    15:0] o_dst_base,
    output logic [                                     7:0] o_h,
    output logic [                                     7:0] o_w,
    output logic [                                     7:0] o_c_in,
    output logic [                                     7:0] o_c_out,
    output logic [                                    15:0] o_wgt_base,
    output logic [                                     7:0] o_param_base,
    output logic                                            o_gemm_start,
    output logic                                            o_pool_start,
    output logic                                            o_argmax_start,
    input  logic                                            i_gemm_done,
    input  logic                                            i_pool_done,
    input  logic                                            i_argmax_done,
    output logic [                                     2:0] o_own_img,
    output logic [                                     2:0] o_own_act0,
    output logic [                                     2:0] o_own_act1,
    output logic [                                     1:0] o_own_wgt,
    output logic [                                     1:0] o_own_prm
);

  localparam int LIDX_W = (DESC_DEPTH > 1) ? $clog2(DESC_DEPTH) : 1;
  localparam int DESC_AW = $clog2(4 * DESC_DEPTH);
  localparam logic [LIDX_W-1:0] LAST_LAYER = LIDX_W'(DESC_DEPTH - 1);
  localparam logic [15:0] IMG_SIZE_W = 16'(IMG_SIZE);

  localparam logic [2:0] OP_CONV = 3'd0;
  localparam logic [2:0] OP_POOL = 3'd1;
  localparam logic [2:0] OP_FC = 3'd2;
  localparam logic [2:0] OP_ARGMAX = 3'd3;
  localparam logic [1:0] B_IMG = 2'd0;
  localparam logic [1:0] B_ACT0 = 2'd1;
  localparam logic [1:0] B_ACT1 = 2'd2;
  localparam logic [1:0] B_LOGIT = 2'd3;
  localparam logic [2:0] OWN_MEM = 3'b001;
  localparam logic [2:0] OWN_GEMM = 3'b010;
  localparam logic [2:0] OWN_POOL = 3'b100;

  typedef enum logic [2:0] {
    S_IDLE,
    S_FETCH,
    S_CHECK,
    S_GO,
    S_RUN,
    S_NEXT,
    S_END
  } state_t;

  state_t state_q;
  logic busy_q, done_q, error_q, err_q;
  logic [LIDX_W-1:0] layer_q;
  logic [2:0] fetch_q;  // descriptor word being requested (0..3), 4: last word arriving
  logic rd_v_q;
  logic [1:0] rd_w_q;
  // Lint waiver: reserved descriptor bits are not decoded (spec §8: reserved, must be 0).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] d0_q, d1_q, d2_q, d3_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0] img_off_q, img_off_d, src_base_q;
  logic [2:0] own_img_q, own_act0_q, own_act1_q;
  logic [1:0] own_wgt_q, own_prm_q;

  // ---------------------------------------------------------------- descriptor fields
  logic [2:0] op;
  logic last, uses_gemm, uses_pool, unit_op;
  logic [1:0] src, dst;
  assign op        = d0_q[2:0];
  assign last      = d0_q[5];
  assign src       = d0_q[9:8];
  assign dst       = d0_q[13:12];
  assign uses_gemm = (op == OP_CONV) || (op == OP_FC);
  assign uses_pool = (op == OP_POOL);
  assign unit_op   = uses_gemm || uses_pool;  // ops that read and write buffers

  assign o_op         = op;
  assign o_relu_en    = d0_q[3];
  assign o_requant_en = d0_q[4];
  assign o_src        = src;
  assign o_dst        = dst;
  assign o_src_base   = src_base_q;
  assign o_dst_base   = d1_q[31:16];
  assign o_h          = d2_q[7:0];
  assign o_w          = d2_q[15:8];
  assign o_c_in       = d2_q[23:16];
  assign o_c_out      = d2_q[31:24];
  assign o_wgt_base   = d3_q[15:0];
  assign o_param_base = d3_q[23:16];

  // IMG_SEL * IMG_SIZE by shift-and-add over the constant's set bits.
  always_comb begin
    img_off_d = '0;
    for (int b = 0; b < 16; b++) begin
      if (IMG_SIZE_W[b]) begin
        img_off_d = img_off_d + (16'(i_img_sel) << b);
      end
    end
  end

  // Owners for the current descriptor.
  logic [2:0] unit_own, own_img_d, own_act0_d, own_act1_d;
  logic writes_dst;
  assign unit_own   = uses_gemm ? OWN_GEMM : (uses_pool ? OWN_POOL : 3'b000);
  assign writes_dst = (op == OP_CONV) || uses_pool;  // FC writes the LOGIT registers instead
  assign own_img_d  = (src == B_IMG) ? unit_own : 3'b000;
  assign own_act0_d = ((src == B_ACT0) || (writes_dst && (dst == B_ACT0))) ? unit_own : 3'b000;
  assign own_act1_d = ((src == B_ACT1) || (writes_dst && (dst == B_ACT1))) ? unit_own : 3'b000;

  // §9 errors, checked before the layer starts. CONV and POOL are the ops that write dst.
  logic err_desc;
  assign err_desc = (op > OP_ARGMAX) || (unit_op && ((dst == B_IMG) || (src == dst)))
                 || (writes_dst && ((src == B_LOGIT) || (dst == B_LOGIT)));

  logic unit_done;
  assign unit_done = uses_gemm ? i_gemm_done : (uses_pool ? i_pool_done : i_argmax_done);

  // ---------------------------------------------------------------- control
  logic start_ok;
  assign start_ok = (state_q == S_IDLE) && i_start && !i_mem_pending;
  assign o_clear  = start_ok;

  assign o_desc_re    = (state_q == S_FETCH) && !fetch_q[2];
  assign o_desc_raddr = DESC_AW'({layer_q, fetch_q[1:0]});

  assign o_gemm_start   = (state_q == S_GO) && uses_gemm;
  assign o_pool_start   = (state_q == S_GO) && uses_pool;
  assign o_argmax_start = (state_q == S_GO) && (op == OP_ARGMAX);
  assign o_layer_start  = (state_q == S_GO);
  assign o_layer_done   = (state_q == S_RUN) && unit_done;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q    <= S_IDLE;
      busy_q     <= 1'b0;
      done_q     <= 1'b0;
      error_q    <= 1'b0;
      err_q      <= 1'b0;
      layer_q    <= '0;
      fetch_q    <= '0;
      rd_v_q     <= 1'b0;
      d0_q       <= '0;
      d1_q       <= '0;
      d2_q       <= '0;
      d3_q       <= '0;
      img_off_q  <= '0;
      src_base_q <= '0;
      own_img_q  <= OWN_MEM;
      own_act0_q <= OWN_MEM;
      own_act1_q <= OWN_MEM;
      own_wgt_q  <= OWN_MEM[1:0];
      own_prm_q  <= OWN_MEM[1:0];
    end else begin
      // Descriptor word capture: data arrives one cycle after each read.
      rd_v_q <= o_desc_re;
      rd_w_q <= fetch_q[1:0];
      if (rd_v_q) begin
        case (rd_w_q)
          2'd0: d0_q <= i_desc_rdata;
          2'd1: d1_q <= i_desc_rdata;
          2'd2: d2_q <= i_desc_rdata;
          default: d3_q <= i_desc_rdata;
        endcase
      end
      case (state_q)
        S_IDLE: begin
          if (start_ok) begin
            busy_q     <= 1'b1;
            done_q     <= 1'b0;
            error_q    <= 1'b0;
            err_q      <= 1'b0;
            layer_q    <= '0;
            fetch_q    <= '0;
            img_off_q  <= img_off_d;
            own_img_q  <= '0;
            own_act0_q <= '0;
            own_act1_q <= '0;
            own_wgt_q  <= '0;
            own_prm_q  <= '0;
            state_q    <= S_FETCH;
          end
        end
        S_FETCH: begin
          fetch_q <= fetch_q + 3'd1;
          if (fetch_q[2]) begin  // the last word is captured this cycle
            state_q <= S_CHECK;
          end
        end
        S_CHECK: begin
          if (err_desc) begin
            err_q   <= 1'b1;
            state_q <= S_END;
          end else begin
            src_base_q <= d1_q[15:0] + ((src == B_IMG) ? img_off_q : 16'd0);
            own_img_q  <= own_img_d;
            own_act0_q <= own_act0_d;
            own_act1_q <= own_act1_d;
            own_wgt_q  <= uses_gemm ? OWN_GEMM[1:0] : 2'b00;
            own_prm_q  <= uses_gemm ? OWN_GEMM[1:0] : 2'b00;
            state_q    <= S_GO;
          end
        end
        S_GO: begin
          state_q <= S_RUN;
        end
        S_RUN: begin
          if (unit_done) begin
            state_q <= S_NEXT;
          end
        end
        S_NEXT: begin  // the unit is idle now: take the ports back
          own_img_q  <= '0;
          own_act0_q <= '0;
          own_act1_q <= '0;
          own_wgt_q  <= '0;
          own_prm_q  <= '0;
          if (last) begin
            state_q <= S_END;
          end else if (layer_q == LAST_LAYER) begin
            err_q   <= 1'b1;  // DESC_DEPTH descriptors without last = 1
            state_q <= S_END;
          end else begin
            layer_q <= layer_q + LIDX_W'(1);
            fetch_q <= '0;
            state_q <= S_FETCH;
          end
        end
        S_END: begin
          busy_q     <= 1'b0;
          done_q     <= 1'b1;
          error_q    <= err_q;
          own_img_q  <= OWN_MEM;
          own_act0_q <= OWN_MEM;
          own_act1_q <= OWN_MEM;
          own_wgt_q  <= OWN_MEM[1:0];
          own_prm_q  <= OWN_MEM[1:0];
          state_q    <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign o_busy     = busy_q;
  assign o_done     = done_q;
  assign o_error    = error_q;
  assign o_layer    = layer_q;
  assign o_own_img  = own_img_q;
  assign o_own_act0 = own_act0_q;
  assign o_own_act1 = own_act1_q;
  assign o_own_wgt  = own_wgt_q;
  assign o_own_prm  = own_prm_q;

endmodule
