// argmax_unit: index of the largest signed logit, ties to the lowest index (spec §3, §9 ARGMAX).
//
// Reads i_count logits starting at i_base through a 1-cycle-latency read port (the LOGIT register
// file), one per cycle. The first value initializes the running maximum; a later value replaces
// it only if it is strictly greater (>), so the earliest of equal maxima wins, as np.argmax does.
//
// Parameters:
//   VAL_W - logit width (signed)
//   IDX_W - width of the logit index and of the result
//
// Ports:
//   clk, rst          - clock, synchronous active-high reset (result and maximum cleared to 0)
//   i_start           - pulse: start (only while o_busy is low)
//   i_base            - index of the first logit
//   i_count           - number of logits; 0 gives result 0
//   o_busy            - high from i_start through the o_done cycle
//   o_done            - one-cycle pulse when o_result and o_max are final
//   o_result          - position (0 .. i_count-1) of the first maximum; held until the next start
//   o_max             - the maximum value; held until the next start
//   o_rd_en, o_rd_idx - logit read port (data on i_rd_data one cycle later)
//   i_rd_data         - logit read data
//
// Latency: i_count + 2 cycles from i_start to o_done. Not part of any interface.
module argmax_unit #(
    parameter int VAL_W = 32,
    parameter int IDX_W = 8
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_start,
    input  logic [IDX_W-1:0] i_base,
    input  logic [IDX_W-1:0] i_count,
    output logic             o_busy,
    output logic             o_done,
    output logic [IDX_W-1:0] o_result,
    output logic [VAL_W-1:0] o_max,
    output logic             o_rd_en,
    output logic [IDX_W-1:0] o_rd_idx,
    input  logic [VAL_W-1:0] i_rd_data
);

  typedef enum logic [1:0] {
    A_IDLE,
    A_READ,
    A_LAST,
    A_DONE
  } astate_t;

  astate_t state_q;
  logic [IDX_W-1:0] pos_q;  // position of the logit being requested
  logic [IDX_W-1:0] count_q, base_q;
  logic rd_v_q;  // read data valid this cycle
  logic [IDX_W-1:0] rd_pos_q;  // position of the data on i_rd_data
  logic signed [VAL_W-1:0] best_q;
  logic [IDX_W-1:0] best_idx_q;

  assign o_rd_en  = (state_q == A_READ);
  assign o_rd_idx = base_q + pos_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q    <= A_IDLE;
      rd_v_q     <= 1'b0;
      best_q     <= '0;
      best_idx_q <= '0;
    end else begin
      rd_v_q   <= (state_q == A_READ);
      rd_pos_q <= pos_q;
      // Compare: first element initializes; later ones replace only if strictly greater.
      if (rd_v_q && ((rd_pos_q == '0) || ($signed(i_rd_data) > best_q))) begin
        best_q     <= $signed(i_rd_data);
        best_idx_q <= rd_pos_q;
      end
      case (state_q)
        A_IDLE: begin
          if (i_start) begin
            base_q     <= i_base;
            count_q    <= i_count;
            pos_q      <= '0;
            best_q     <= '0;
            best_idx_q <= '0;
            state_q    <= (i_count == '0) ? A_DONE : A_READ;
          end
        end
        A_READ: begin  // one read per cycle
          if (pos_q == count_q - IDX_W'(1)) begin
            state_q <= A_LAST;
          end else begin
            pos_q <= pos_q + IDX_W'(1);
          end
        end
        A_LAST: begin  // the last read's data is compared this cycle
          state_q <= A_DONE;
        end
        A_DONE: begin
          state_q <= A_IDLE;
        end
        default: state_q <= A_IDLE;
      endcase
    end
  end

  assign o_busy   = (state_q != A_IDLE);
  assign o_done   = (state_q == A_DONE);
  assign o_result = best_idx_q;
  assign o_max    = best_q;

endmodule
