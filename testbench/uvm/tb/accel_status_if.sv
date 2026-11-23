// accel_status_if: accel_top's status outputs as brought out by accel_axil_tb (BUSY, DONE, ERROR,
// RESULT), observed by the UVM status monitor. Read only: nothing in the bench drives them.
//
// `cycle` counts rising edges exactly like axil_if's, so the two monitors' time stamps compare.
interface accel_status_if (
    input logic clk
);
  logic       rst;
  logic       busy;
  logic       done;
  logic       error;
  logic [7:0] result;
  longint     cycle = 0;

  always @(posedge clk) cycle <= cycle + 1;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, busy, done, error, result, cycle;
  endclocking

  // BUSY and DONE are never both set (spec §9: the run's end clears BUSY and sets DONE).
  a_busy_done_exclusive :
  assert property (@(posedge clk) disable iff (rst) !(busy && done));
endinterface
