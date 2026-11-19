// demo_ctrl: the FPGA demo's CSR master. A start press (i_start, one-cycle pulse) while the
// accelerator is idle writes IMG_SEL = i_img_sel and then CTRL.START = 1 through the CSR stage,
// and latches the image index for the display. Presses while busy, during that sequence, or
// while the host side has a request are ignored.
//
// The CSR stage (csr_slice) is shared with a host master (bring-up and tests; tied off on the
// board): the host owns it whenever the controller is idle, and sees o_host_ready low while the
// controller runs its two-write sequence, so neither master's request is changed or dropped.
//
// Ports:
//   clk, rst                                     - clock, synchronous active-high reset
//   i_start                                      - start press (one-cycle pulse)
//   i_img_sel                                    - image index (synchronized switches)
//   i_busy                                       - STATUS.BUSY (accel_top o_busy)
//   o_run_sel                                    - IMG_SEL of the last run the controller started
//   i_host_valid, o_host_ready, i_host_we, i_host_addr, i_host_wdata - host CSR requests
//   o_valid, i_ready, o_we, o_addr, o_wdata      - to the CSR stage (csr_slice front side)
//
// Latency: the START write leaves the controller 2 or more accepted requests after the press.
module demo_ctrl (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_start,
    input  logic [ 3:0] i_img_sel,
    input  logic        i_busy,
    output logic [ 3:0] o_run_sel,
    input  logic        i_host_valid,
    output logic        o_host_ready,
    input  logic        i_host_we,
    input  logic [11:0] i_host_addr,
    input  logic [31:0] i_host_wdata,
    output logic        o_valid,
    input  logic        i_ready,
    output logic        o_we,
    output logic [11:0] o_addr,
    output logic [31:0] o_wdata
);

  localparam logic [11:0] CTRL = 12'h010;
  localparam logic [11:0] IMG_SEL = 12'h018;

  typedef enum logic [1:0] {
    C_IDLE,
    C_SEL,
    C_GO
  } cstate_t;

  cstate_t state_q;
  logic [3:0] sel_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= C_IDLE;
      sel_q   <= '0;
    end else begin
      case (state_q)
        C_IDLE: begin
          if (i_start && !i_busy && !i_host_valid) begin
            sel_q   <= i_img_sel;
            state_q <= C_SEL;
          end
        end
        C_SEL: begin
          if (i_ready) state_q <= C_GO;  // IMG_SEL write accepted
        end
        C_GO: begin
          if (i_ready) state_q <= C_IDLE;  // START write accepted
        end
        default: state_q <= C_IDLE;
      endcase
    end
  end

  always_comb begin
    if (state_q == C_IDLE) begin  // the host owns the stage
      o_valid = i_host_valid;
      o_we    = i_host_we;
      o_addr  = i_host_addr;
      o_wdata = i_host_wdata;
    end else begin
      o_valid = 1'b1;
      o_we    = 1'b1;
      o_addr  = (state_q == C_SEL) ? IMG_SEL : CTRL;
      o_wdata = (state_q == C_SEL) ? 32'(sel_q) : 32'd1;
    end
  end

  assign o_host_ready = (state_q == C_IDLE) && i_ready;
  assign o_run_sel    = sel_q;

endmodule
