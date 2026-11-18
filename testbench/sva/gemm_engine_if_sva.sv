// gemm_engine_if_sva: assertions on the gemm_engine interface (rtl/core/gemm_engine.sv header).
//
// Uses only engine ports. Bound by gemm_engine_bind.sv. Simulation-only (Verilator --assert);
// Icarus does not support concurrent assertions. The systolic_array assertions are bound
// separately (systolic_array_bind.sv) and also check the array inside the engine.
//
// Producer (layer sequencer) obligations:
//   a_start_only_when_idle   i_start only while o_busy is low
//   a_cfg_stable_while_busy  the configuration inputs do not change while busy
// Engine obligations:
//   a_done_is_pulse          o_done lasts one cycle
//   a_done_ends_busy         o_busy is low the cycle after o_done
//   a_busy_ends_with_done    o_busy only falls right after o_done
//   a_quiet_when_idle        no buffer access while idle
//   a_write_port_matches     CONV writes only activations, FC writes only logits
module gemm_engine_if_sva #(
    parameter int ADDR_W = 16
) (
    input logic              clk,
    input logic              rst,
    input logic              i_start,
    input logic              o_busy,
    input logic              o_done,
    input logic              i_fc,
    input logic              i_relu_en,
    input logic              i_requant_en,
    input logic [ADDR_W-1:0] i_src_base,
    input logic [ADDR_W-1:0] i_dst_base,
    input logic [       7:0] i_h,
    input logic [       7:0] i_w,
    input logic [       7:0] i_c_in,
    input logic [       7:0] i_c_out,
    input logic [      15:0] i_wgt_base,
    input logic [       7:0] i_param_base,
    input logic              o_src_re,
    input logic              o_wgt_re,
    input logic              o_prm_re,
    input logic              o_dst_we,
    input logic              o_logit_we
);

  logic [3 + 2*ADDR_W + 5*8 + 16 - 1:0] cfg;
  assign cfg = {
    i_fc,
    i_relu_en,
    i_requant_en,
    i_src_base,
    i_dst_base,
    i_h,
    i_w,
    i_c_in,
    i_c_out,
    i_wgt_base,
    i_param_base
  };

  a_start_only_when_idle :
  assert property (@(posedge clk) disable iff (rst) i_start |-> !o_busy);

  a_cfg_stable_while_busy :
  assert property (@(posedge clk) disable iff (rst) (o_busy && $past(o_busy)) |-> $stable(cfg));

  a_done_is_pulse :
  assert property (@(posedge clk) disable iff (rst) o_done |=> !o_done);

  a_done_ends_busy :
  assert property (@(posedge clk) disable iff (rst) o_done |=> !o_busy);

  a_busy_ends_with_done :
  assert property (@(posedge clk) disable iff (rst) $fell(o_busy) |-> $past(o_done));

  a_quiet_when_idle :
  assert property (@(posedge clk) disable iff (rst)
      !o_busy |-> !(o_src_re || o_wgt_re || o_prm_re || o_dst_we || o_logit_we));

  a_write_port_matches :
  assert property (@(posedge clk) disable iff (rst) !(o_dst_we && i_fc) && !(o_logit_we && !i_fc));

endmodule
