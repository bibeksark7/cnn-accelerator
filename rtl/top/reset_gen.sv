// reset_gen: board reset for the FPGA top. The reset is active
//   - after configuration, until a power-on counter reaches POR_CYCLES, and
//   - while the reset button (i_key_rst_n, active low, asynchronous) is pressed,
// and is released synchronously to clk.
//
// The power-on counter relies on the MAX 10 power-up state of its registers (0, Quartus's
// default power-up level), so it needs no reset of its own; simulations model power-up by
// depositing 0 into por_cnt_q. The button goes through a 2-FF synchronizer. o_rst is the request
// OR'd with the request delayed by two flip-flops: it rises with the request and falls two
// cycles after it, and every term is a register output.
//
// Parameters:
//   POR_CYCLES - cycles of power-on reset (>= 1)
//
// Ports:
//   clk          - board clock
//   i_key_rst_n  - reset button, active low, asynchronous
//   o_rst        - synchronous active-high reset for the design
//
// Latency: o_rst rises 2 cycles after a button press (the synchronizer) and falls 4 cycles after
// the release; at power-up it is high from the first cycle.
module reset_gen #(
    parameter int POR_CYCLES = 256
) (
    input  logic clk,
    input  logic i_key_rst_n,
    output logic o_rst
);

  localparam int CNT_W = $clog2(POR_CYCLES + 1);
  localparam logic [CNT_W-1:0] POR_LAST = CNT_W'(POR_CYCLES);

  // No reset by design: the counter starts from its power-up value 0.
  logic [CNT_W-1:0] por_cnt_q;
  logic por_done;
  assign por_done = (por_cnt_q == POR_LAST);
  always_ff @(posedge clk) begin
    if (!por_done) begin
      por_cnt_q <= por_cnt_q + CNT_W'(1);
    end
  end

  // Button synchronizer (held in the released state while the power-on reset is active).
  logic key_rst_n;
  sync_2ff #(
      .W    (1),
      .RESET(1)
  ) u_sync_2ff_key (
      .clk    (clk),
      .rst    (!por_done),
      .i_async(i_key_rst_n),
      .o_sync (key_rst_n)
  );

  logic req, rst1_q, rst2_q;
  assign req = !por_done || !key_rst_n;
  always_ff @(posedge clk) begin
    rst1_q <= req;
    rst2_q <= rst1_q;
  end

  assign o_rst = rst2_q || req;

endmodule
