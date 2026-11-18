// mem_port: host memory port (spec §10.3). Loads and reads back the §5 buffers while idle.
//
// A request is accepted when i_mem_valid && o_mem_ready. o_mem_ready is low while the
// accelerator is busy and while a read is pending, so at most one read is outstanding.
//   write  the selected buffer is written in the accepting cycle (through its port multiplexer,
//          which the layer sequencer gives to this port while idle)
//   read   the selected buffer is read in the accepting cycle; its data returns one cycle later
//          with a one-cycle o_mem_rvalid pulse. The buffer select is registered with the request,
//          so the returned word comes from the buffer that was read.
// Buffers (i_mem_sel): 0 IMG, 1 ACT0, 2 ACT1, 3 WGT, 4 PARAM; 5-7 reserved (writes ignored,
// reads return 0, still with one o_mem_rvalid pulse).
// Address bits above a buffer's width are ignored (spec §10.3).
// Data: byte buffers use i_mem_wdata[7:0] and read back zero-extended. WGT words are
// WGT_W = N*DATA_W bits wide: written from i_mem_wdata[WGT_W-1:0] (zero-extended if WGT_W > 64)
// and read back zero-extended to 64 bits. PARAM words are 64 bits (docs/decisions.md D-028).
// The request address and write data go to the buffers straight from the host port (accel_top);
// this module produces the per-buffer request strobes and returns the read data.
//
// Parameters:
//   WGT_W - WGT word width (N*DATA_W)
//
// Ports:
//   clk, rst                                   - clock, synchronous active-high reset
//   i_mem_valid, o_mem_ready, i_mem_we, i_mem_sel,
//   o_mem_rvalid, o_mem_rdata                  - host memory port handshake and read return
//                                                (spec §10.3; i_mem_addr and i_mem_wdata go to
//                                                the buffers directly)
//   i_busy                                     - STATUS.BUSY
//   o_rd_pending                               - a read has been accepted and not yet returned
//                                                (START is ignored while it is high, spec §9)
//   o_re[s], o_we[s]                           - read / write request to buffer s (s = sel)
//   i_img_rdata, i_act0_rdata, i_act1_rdata,
//   i_wgt_rdata, i_prm_rdata                   - buffer read data (1-cycle latency)
//
// Latency: o_mem_rvalid one cycle after an accepted read (not part of the interface).
module mem_port #(
    parameter int WGT_W = 64
) (
    input  logic             clk,
    input  logic             rst,
    input  logic             i_mem_valid,
    output logic             o_mem_ready,
    input  logic             i_mem_we,
    input  logic [      2:0] i_mem_sel,
    output logic             o_mem_rvalid,
    output logic [     63:0] o_mem_rdata,
    input  logic             i_busy,
    output logic             o_rd_pending,
    output logic [      4:0] o_re,
    output logic [      4:0] o_we,
    input  logic [      7:0] i_img_rdata,
    input  logic [      7:0] i_act0_rdata,
    input  logic [      7:0] i_act1_rdata,
    input  logic [WGT_W-1:0] i_wgt_rdata,
    input  logic [     63:0] i_prm_rdata
);

  logic accept;
  logic pend_q;
  logic [2:0] sel_q;

  assign o_mem_ready = !i_busy && !pend_q;
  assign accept      = i_mem_valid && o_mem_ready;

  always_comb begin
    o_re = '0;
    o_we = '0;
    if (accept && (i_mem_sel < 3'd5)) begin
      if (i_mem_we) begin
        o_we[i_mem_sel] = 1'b1;
      end else begin
        o_re[i_mem_sel] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pend_q <= 1'b0;
    end else begin
      pend_q <= accept && !i_mem_we;
    end
  end

  always_ff @(posedge clk) begin
    if (accept && !i_mem_we) begin
      sel_q <= i_mem_sel;
    end
  end

  always_comb begin
    case (sel_q)
      3'd0:    o_mem_rdata = 64'(i_img_rdata);
      3'd1:    o_mem_rdata = 64'(i_act0_rdata);
      3'd2:    o_mem_rdata = 64'(i_act1_rdata);
      3'd3:    o_mem_rdata = 64'(i_wgt_rdata);
      3'd4:    o_mem_rdata = i_prm_rdata;
      default: o_mem_rdata = '0;
    endcase
  end

  assign o_mem_rvalid = pend_q;
  assign o_rd_pending = pend_q;

endmodule
