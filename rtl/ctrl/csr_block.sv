// csr_block: CSR bus slave and register map (spec §10.1, §10.2).
//
// Register reads are answered in the cycle the request arrives (o_csr_ready = i_csr_valid).
// Descriptor-table reads take one more cycle: the table is a synchronous RAM. The CSR block reads
// it only in a cycle where the layer sequencer is not reading it (i_desc_gnt), so a descriptor
// read during a run waits at most for the sequencer's 4-word fetch. Writes are accepted at once.
//
// Register map (byte offsets; address bits [1:0] ignored; unmapped addresses read 0, ignore
// writes):
//   0x000 ID         RO  0x434E4E31 ("CNN1")
//   0x004 CONFIG     RO  [7:0] N, [15:8] DATA_W, [23:16] ACC_W, [31:24] DESC_DEPTH
//   0x010 CTRL       WO  [0] START: o_start pulses for one cycle on a write with bit 0 set (the
//                        sequencer ignores it unless idle with no memory-port read pending); reads 0
//   0x014 STATUS     RO  [0] BUSY, [1] DONE, [2] ERROR, [11:8] current (or last) layer
//   0x018 IMG_SEL    RW  [3:0]; writes while busy are ignored
//   0x01C RESULT     RO  [7:0] predicted class
//   0x020 CYC_TOTAL, 0x024 CYC_MAC, 0x028 BUF_RD, 0x02C BUF_WR  RO  performance counters
//   0x040 + 4L       LAYER_CYC[L], L < DESC_DEPTH  RO
//   0x080 + 4i       LOGIT[i], i < LOGIT_DEPTH     RO
//   0x100 + 4w       DESC[w], w < 4*DESC_DEPTH     RW; writes while busy are ignored
//
// Parameters:
//   N, DATA_W, ACC_W, DESC_DEPTH - reported in CONFIG (DESC_DEPTH <= 16)
//   LOGIT_DEPTH                  - number of LOGIT registers (<= 32)
//   PERF_W                       - performance counter width (<= 32; zero-extended)
//
// Ports:
//   clk, rst                                  - clock, synchronous active-high reset
//   i_csr_valid, i_csr_we, i_csr_addr, i_csr_wdata, o_csr_ready, o_csr_rdata - CSR bus
//   o_start                                   - START written
//   o_img_sel                                 - IMG_SEL register
//   i_busy, i_done, i_error, i_layer          - STATUS fields
//   i_result                                  - RESULT
//   i_cyc_total, i_cyc_mac, i_buf_rd, i_buf_wr, i_layer_cyc - performance counters
//   o_logit_raddr, i_logit_rdata              - LOGIT register read (combinational)
//   o_desc_re, o_desc_raddr, i_desc_rdata     - descriptor table read (1-cycle latency)
//   i_desc_gnt                                - the table's read port is free this cycle
//   o_desc_we, o_desc_waddr, o_desc_wdata     - descriptor table write
//
// Latency: registers 0 cycles (ready with valid); descriptor reads 1 or more cycles.
module csr_block #(
    parameter int N           = 8,
    parameter int DATA_W      = 8,
    parameter int ACC_W       = 32,
    parameter int DESC_DEPTH  = 8,
    parameter int LOGIT_DEPTH = 16,
    parameter int PERF_W      = 32
) (
    input  logic                                     clk,
    input  logic                                     rst,
    input  logic                                     i_csr_valid,
    input  logic                                     i_csr_we,
    input  logic [                             11:0] i_csr_addr,
    input  logic [                             31:0] i_csr_wdata,
    output logic                                     o_csr_ready,
    output logic [                             31:0] o_csr_rdata,
    output logic                                     o_start,
    output logic [                              3:0] o_img_sel,
    input  logic                                     i_busy,
    input  logic                                     i_done,
    input  logic                                     i_error,
    input  logic [                              3:0] i_layer,
    input  logic [                              7:0] i_result,
    input  logic [                       PERF_W-1:0] i_cyc_total,
    input  logic [                       PERF_W-1:0] i_cyc_mac,
    input  logic [                       PERF_W-1:0] i_buf_rd,
    input  logic [                       PERF_W-1:0] i_buf_wr,
    input  logic [            DESC_DEPTH*PERF_W-1:0] i_layer_cyc,
    output logic [            $clog2(LOGIT_DEPTH)-1:0] o_logit_raddr,
    input  logic [                             31:0] i_logit_rdata,
    output logic                                     o_desc_re,
    output logic [         $clog2(4*DESC_DEPTH)-1:0] o_desc_raddr,
    input  logic [                             31:0] i_desc_rdata,
    input  logic                                     i_desc_gnt,
    output logic                                     o_desc_we,
    output logic [         $clog2(4*DESC_DEPTH)-1:0] o_desc_waddr,
    output logic [                             31:0] o_desc_wdata
);

  localparam int LOGIT_AW = $clog2(LOGIT_DEPTH);
  localparam int DESC_AW = $clog2(4 * DESC_DEPTH);
  localparam logic [31:0] ID_VALUE = 32'h434E_4E31;
  localparam logic [31:0] CONFIG_VALUE = {8'(DESC_DEPTH), 8'(ACC_W), 8'(DATA_W), 8'(N)};

  // Word address and region decode. Lint waiver: byte-address bits [1:0] are ignored (spec §10.1).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [11:0] addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [9:0] waddr, desc_word;
  logic is_layer, is_logit, is_desc;
  assign addr      = i_csr_addr;
  assign waddr     = addr[11:2];
  assign is_layer  = (waddr[9:4] == 6'h01) && (32'(waddr[3:0]) < DESC_DEPTH);
  assign is_logit  = (waddr[9:5] == 5'h01) && (32'(waddr[4:0]) < LOGIT_DEPTH);
  assign desc_word = waddr - 10'h040;  // word index in the 0x100 region
  assign is_desc   = (waddr >= 10'h040) && (32'(desc_word) < 4 * DESC_DEPTH);

  // Descriptor reads: request the RAM when its port is free, answer the cycle after.
  logic desc_rd, desc_pend_q;
  assign desc_rd = i_csr_valid && !i_csr_we && is_desc;
  assign o_desc_re = desc_rd && !desc_pend_q && i_desc_gnt;
  assign o_desc_raddr = DESC_AW'(desc_word);

  assign o_csr_ready = i_csr_valid && (!desc_rd || desc_pend_q);

  always_ff @(posedge clk) begin
    if (rst) begin
      desc_pend_q <= 1'b0;
    end else if (o_desc_re) begin
      desc_pend_q <= 1'b1;
    end else if (o_csr_ready) begin
      desc_pend_q <= 1'b0;
    end
  end

  // Writes.
  logic wr;
  logic [3:0] img_sel_q;
  assign wr = i_csr_valid && i_csr_we;  // writes are accepted in the cycle they arrive
  assign o_start = wr && (waddr == 10'h004) && i_csr_wdata[0];
  assign o_desc_we = wr && is_desc && !i_busy;
  assign o_desc_waddr = DESC_AW'(desc_word);
  assign o_desc_wdata = i_csr_wdata;

  always_ff @(posedge clk) begin
    if (rst) begin
      img_sel_q <= '0;
    end else if (wr && (waddr == 10'h006) && !i_busy) begin
      img_sel_q <= i_csr_wdata[3:0];
    end
  end
  assign o_img_sel = img_sel_q;

  // Read data. LAYER_CYC as an array of 16 words (entries >= DESC_DEPTH read 0).
  logic [15:0][31:0] layer_cyc;
  genvar gl;
  generate
    for (gl = 0; gl < 16; gl = gl + 1) begin : g_layer_cyc
      if (gl < DESC_DEPTH) begin : g_used
        assign layer_cyc[gl] = 32'(i_layer_cyc[gl*PERF_W+:PERF_W]);
      end else begin : g_unused
        assign layer_cyc[gl] = '0;
      end
    end
  endgenerate

  logic [31:0] layer_rdata;
  assign layer_rdata   = layer_cyc[waddr[3:0]];
  assign o_logit_raddr = LOGIT_AW'(waddr[4:0]);

  always_comb begin
    o_csr_rdata = '0;
    if (is_layer) begin
      o_csr_rdata = layer_rdata;
    end else if (is_logit) begin
      o_csr_rdata = i_logit_rdata;
    end else if (is_desc) begin
      o_csr_rdata = i_desc_rdata;
    end else begin
      case (waddr)
        10'h000: o_csr_rdata = ID_VALUE;
        10'h001: o_csr_rdata = CONFIG_VALUE;
        10'h005: o_csr_rdata = {20'd0, i_layer, 5'd0, i_error, i_done, i_busy};
        10'h006: o_csr_rdata = {28'd0, img_sel_q};
        10'h007: o_csr_rdata = {24'd0, i_result};
        10'h008: o_csr_rdata = 32'(i_cyc_total);
        10'h009: o_csr_rdata = 32'(i_cyc_mac);
        10'h00A: o_csr_rdata = 32'(i_buf_rd);
        10'h00B: o_csr_rdata = 32'(i_buf_wr);
        default: o_csr_rdata = '0;
      endcase
    end
  end

endmodule
