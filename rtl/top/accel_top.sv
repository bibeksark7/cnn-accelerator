// accel_top: the int8 CNN accelerator core (spec §11.1): CSR bus, memory port, layer sequencer,
// GEMM engine, pool and argmax units, the §5 buffers and the LOGIT register file.
//
// Buffers are sram_1r1w instances (1-cycle synchronous read). Each §5 buffer has one
// buf_port_mux in front of its ports; the layer sequencer's registered one-hot owner vectors
// pick the requester (owner 0: memory port, 1: GEMM engine, 2: pool unit). Requests are
// decoded per buffer from the descriptor's src/dst fields, so a unit only requests the buffers
// its layer names. Read data fans out; the units' source data is selected by the registered
// src field, and the memory port registers its own select with each read (D-028).
// Addresses are taken modulo each buffer's depth: bits above a buffer's address width are ignored
// (IMG 14 bits, ACT 13, WGT 10, PARAM 6, LOGIT 4 with the default depths).
//
// Parameters: spec §1 (N, DATA_W, ACC_W, K_TILE, IMG_DEPTH, IMG_SIZE, ACT_DEPTH, WGT_DEPTH,
// PARAM_DEPTH, LOGIT_DEPTH, DESC_DEPTH; depths are powers of two), PERF_W (performance counter
// width, default 32), and $readmemh init files IMG_INIT, WGT_INIT, PARAM_INIT, DESC_INIT
// ("" = no preload). N*DATA_W <= 64 gives full WGT words through the 64-bit memory port.
//
// Ports:
//   clk, rst                                    - clock, synchronous active-high reset: aborts a
//                                                 run, resets the CSRs; buffers and the
//                                                 descriptor table keep their contents
//   i_csr_valid, i_csr_we, i_csr_addr, i_csr_wdata, o_csr_ready, o_csr_rdata - CSR bus (§10.1)
//   i_mem_valid, o_mem_ready, i_mem_we, i_mem_sel, i_mem_addr, i_mem_wdata,
//   o_mem_rvalid, o_mem_rdata                   - memory port (§10.3)
//   o_busy, o_done, o_error, o_result, o_cyc_total - status for the FPGA top (§11.1)
//
// Latency: data-dependent; observe STATUS / o_done, never a cycle count.
module accel_top #(
    parameter int N           = 8,
    parameter int DATA_W      = 8,
    parameter int ACC_W       = 32,
    parameter int K_TILE      = 128,
    parameter int IMG_DEPTH   = 16384,
    parameter int IMG_SIZE    = 784,
    parameter int ACT_DEPTH   = 8192,
    parameter int WGT_DEPTH   = 1024,
    parameter int PARAM_DEPTH = 64,
    parameter int LOGIT_DEPTH = 16,
    parameter int DESC_DEPTH  = 8,
    parameter int PERF_W      = 32,
    parameter     IMG_INIT    = "",
    parameter     WGT_INIT    = "",
    parameter     PARAM_INIT  = "",
    parameter     DESC_INIT   = ""
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_csr_valid,
    input  logic        i_csr_we,
    input  logic [11:0] i_csr_addr,
    input  logic [31:0] i_csr_wdata,
    output logic        o_csr_ready,
    output logic [31:0] o_csr_rdata,
    input  logic        i_mem_valid,
    output logic        o_mem_ready,
    input  logic        i_mem_we,
    input  logic [ 2:0] i_mem_sel,
    input  logic [15:0] i_mem_addr,
    input  logic [63:0] i_mem_wdata,
    output logic        o_mem_rvalid,
    output logic [63:0] o_mem_rdata,
    output logic        o_busy,
    output logic        o_done,
    output logic        o_error,
    output logic [ 7:0] o_result,
    output logic [31:0] o_cyc_total
);

  localparam int WGT_W = N * DATA_W;
  localparam int IMG_AW = $clog2(IMG_DEPTH);
  localparam int ACT_AW = $clog2(ACT_DEPTH);
  localparam int WGT_AW = $clog2(WGT_DEPTH);
  localparam int PRM_AW = $clog2(PARAM_DEPTH);
  localparam int LOGIT_AW = $clog2(LOGIT_DEPTH);
  localparam int DESC_AW = $clog2(4 * DESC_DEPTH);
  localparam int LIDX_W = (DESC_DEPTH > 1) ? $clog2(DESC_DEPTH) : 1;
  localparam logic [2:0] OP_FC = 3'd2;

  // ================================================================ control
  // ---------------------------------------------------------------- CSR block
  logic csr_start;
  logic [3:0] img_sel;
  logic [PERF_W-1:0] cyc_total, cyc_mac, buf_rd, buf_wr;
  logic [DESC_DEPTH*PERF_W-1:0] layer_cyc;
  logic [LOGIT_AW-1:0] csr_logit_raddr;
  logic [31:0] csr_logit_rdata;
  logic csr_desc_re, csr_desc_we, desc_gnt;
  logic [DESC_AW-1:0] csr_desc_raddr, csr_desc_waddr;
  logic [31:0] csr_desc_wdata, desc_rdata;
  logic [7:0] result;

  logic seq_busy, seq_done, seq_error;
  logic [LIDX_W-1:0] seq_layer;

  csr_block #(
      .N          (N),
      .DATA_W     (DATA_W),
      .ACC_W      (ACC_W),
      .DESC_DEPTH (DESC_DEPTH),
      .LOGIT_DEPTH(LOGIT_DEPTH),
      .PERF_W     (PERF_W)
  ) u_csr_block (
      .clk          (clk),
      .rst          (rst),
      .i_csr_valid  (i_csr_valid),
      .i_csr_we     (i_csr_we),
      .i_csr_addr   (i_csr_addr),
      .i_csr_wdata  (i_csr_wdata),
      .o_csr_ready  (o_csr_ready),
      .o_csr_rdata  (o_csr_rdata),
      .o_start      (csr_start),
      .o_img_sel    (img_sel),
      .i_busy       (seq_busy),
      .i_done       (seq_done),
      .i_error      (seq_error),
      .i_layer      (4'(seq_layer)),
      .i_result     (result),
      .i_cyc_total  (cyc_total),
      .i_cyc_mac    (cyc_mac),
      .i_buf_rd     (buf_rd),
      .i_buf_wr     (buf_wr),
      .i_layer_cyc  (layer_cyc),
      .o_logit_raddr(csr_logit_raddr),
      .i_logit_rdata(csr_logit_rdata),
      .o_desc_re    (csr_desc_re),
      .o_desc_raddr (csr_desc_raddr),
      .i_desc_rdata (desc_rdata),
      .i_desc_gnt   (desc_gnt),
      .o_desc_we    (csr_desc_we),
      .o_desc_waddr (csr_desc_waddr),
      .o_desc_wdata (csr_desc_wdata)
  );

  // ---------------------------------------------------------------- layer sequencer
  logic mem_pending, seq_clear, layer_start, layer_done;
  logic seq_desc_re;
  logic [DESC_AW-1:0] seq_desc_raddr;
  logic [2:0] op;
  logic relu_en, requant_en;
  logic [1:0] src, dst;
  logic [15:0] src_base, dst_base, wgt_base;
  logic [7:0] dim_h, dim_w, c_in, c_out, param_base;
  logic gemm_start, pool_start, argmax_start;
  logic gemm_done, pool_done, argmax_done;
  // Lint waiver: the units' busy outputs are only observed by the ownership assertions
  // (testbench/sva/accel_top_sva.sv); the sequencer waits for done pulses.
  /* verilator lint_off UNUSEDSIGNAL */
  logic gemm_busy, pool_busy, argmax_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0] own_img, own_act0, own_act1;
  logic [1:0] own_wgt, own_prm;

  layer_seq #(
      .DESC_DEPTH(DESC_DEPTH),
      .IMG_SIZE  (IMG_SIZE)
  ) u_layer_seq (
      .clk           (clk),
      .rst           (rst),
      .i_start       (csr_start),
      .i_mem_pending (mem_pending),
      .i_img_sel     (img_sel),
      .o_busy        (seq_busy),
      .o_done        (seq_done),
      .o_error       (seq_error),
      .o_layer       (seq_layer),
      .o_clear       (seq_clear),
      .o_layer_start (layer_start),
      .o_layer_done  (layer_done),
      .o_desc_re     (seq_desc_re),
      .o_desc_raddr  (seq_desc_raddr),
      .i_desc_rdata  (desc_rdata),
      .o_op          (op),
      .o_relu_en     (relu_en),
      .o_requant_en  (requant_en),
      .o_src         (src),
      .o_dst         (dst),
      .o_src_base    (src_base),
      .o_dst_base    (dst_base),
      .o_h           (dim_h),
      .o_w           (dim_w),
      .o_c_in        (c_in),
      .o_c_out       (c_out),
      .o_wgt_base    (wgt_base),
      .o_param_base  (param_base),
      .o_gemm_start  (gemm_start),
      .o_pool_start  (pool_start),
      .o_argmax_start(argmax_start),
      .i_gemm_done   (gemm_done),
      .i_pool_done   (pool_done),
      .i_argmax_done (argmax_done),
      .o_own_img     (own_img),
      .o_own_act0    (own_act0),
      .o_own_act1    (own_act1),
      .o_own_wgt     (own_wgt),
      .o_own_prm     (own_prm)
  );

  // Descriptor table: written by the CSR block (idle only), read by the sequencer or, when the
  // sequencer is not reading, by the CSR block.
  assign desc_gnt = !seq_desc_re;

  sram_1r1w #(
      .WIDTH    (32),
      .DEPTH    (4 * DESC_DEPTH),
      .INIT_FILE(DESC_INIT)
  ) u_sram_1r1w_desc (
      .clk    (clk),
      .i_we   (csr_desc_we),
      .i_waddr(csr_desc_waddr),
      .i_wdata(csr_desc_wdata),
      .i_re   (seq_desc_re || csr_desc_re),
      .i_raddr(seq_desc_re ? seq_desc_raddr : csr_desc_raddr),
      .o_rdata(desc_rdata)
  );

  // ---------------------------------------------------------------- performance counters
  logic mac_active;
  logic img_re, act0_re, act1_re, wgt_re, prm_re, act0_we, act1_we;

  perf_counters #(
      .PERF_W    (PERF_W),
      .DESC_DEPTH(DESC_DEPTH),
      .RD_N      (5),
      .WR_N      (2)
  ) u_perf_counters (
      .clk          (clk),
      .rst          (rst),
      .i_clear      (seq_clear),
      .i_busy       (seq_busy),
      .i_mac_active (mac_active),
      .i_rd         ({prm_re, wgt_re, act1_re, act0_re, img_re}),
      .i_wr         ({act1_we, act0_we}),
      .i_layer_start(layer_start),
      .i_layer_done (layer_done),
      .i_layer_idx  (seq_layer),
      .o_cyc_total  (cyc_total),
      .o_cyc_mac    (cyc_mac),
      .o_buf_rd     (buf_rd),
      .o_buf_wr     (buf_wr),
      .o_layer_cyc  (layer_cyc)
  );

  // ================================================================ requesters
  // ---------------------------------------------------------------- memory port
  logic [4:0] mem_re, mem_we;
  // Lint waiver (here and for the unit address ports below): address bits above a buffer's
  // address width are ignored (addresses are taken modulo the buffer depth, D-028).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] mem_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [63:0] mem_wdata;
  logic [WGT_W-1:0] mem_wgt_wdata;
  assign mem_addr      = i_mem_addr;
  assign mem_wdata     = i_mem_wdata;
  assign mem_wgt_wdata = WGT_W'(i_mem_wdata);  // zero-extended if N*DATA_W > 64
  logic [7:0] img_rdata, act0_rdata, act1_rdata;
  logic [WGT_W-1:0] wgt_rdata;
  logic [63:0] prm_rdata;

  mem_port #(
      .WGT_W(WGT_W)
  ) u_mem_port (
      .clk         (clk),
      .rst         (rst),
      .i_mem_valid (i_mem_valid),
      .o_mem_ready (o_mem_ready),
      .i_mem_we    (i_mem_we),
      .i_mem_sel   (i_mem_sel),
      .o_mem_rvalid(o_mem_rvalid),
      .o_mem_rdata (o_mem_rdata),
      .i_busy      (seq_busy),
      .o_rd_pending(mem_pending),
      .o_re        (mem_re),
      .o_we        (mem_we),
      .i_img_rdata (img_rdata),
      .i_act0_rdata(act0_rdata),
      .i_act1_rdata(act1_rdata),
      .i_wgt_rdata (wgt_rdata),
      .i_prm_rdata (prm_rdata)
  );

  // ---------------------------------------------------------------- unit source data
  logic [7:0] src_rdata;
  always_comb begin
    case (src)
      2'd0:    src_rdata = img_rdata;
      2'd1:    src_rdata = act0_rdata;
      2'd2:    src_rdata = act1_rdata;
      default: src_rdata = '0;  // LOGIT is not a byte buffer (FC with src = LOGIT reads 0)
    endcase
  end

  // ---------------------------------------------------------------- GEMM engine
  logic g_src_re, g_wgt_re, g_prm_re, g_dst_we, g_logit_we;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] g_src_addr, g_dst_addr, g_logit_idx;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [WGT_AW-1:0] g_wgt_addr;
  logic [PRM_AW-1:0] g_prm_addr;
  logic [7:0] g_dst_wdata;
  logic [31:0] g_logit_wdata;

  gemm_engine #(
      .N          (N),
      .DATA_W     (DATA_W),
      .ACC_W      (ACC_W),
      .K_TILE     (K_TILE),
      .ADDR_W     (16),
      .WGT_DEPTH  (WGT_DEPTH),
      .PARAM_DEPTH(PARAM_DEPTH)
  ) u_gemm_engine (
      .clk          (clk),
      .rst          (rst),
      .i_start      (gemm_start),
      .o_busy       (gemm_busy),
      .o_done       (gemm_done),
      .i_fc         (op == OP_FC),
      .i_relu_en    (relu_en),
      .i_requant_en (requant_en),
      .i_src_base   (src_base),
      .i_dst_base   (dst_base),
      .i_h          (dim_h),
      .i_w          (dim_w),
      .i_c_in       (c_in),
      .i_c_out      (c_out),
      .i_wgt_base   (wgt_base),
      .i_param_base (param_base),
      .o_src_re     (g_src_re),
      .o_src_addr   (g_src_addr),
      .i_src_rdata  (src_rdata),
      .o_wgt_re     (g_wgt_re),
      .o_wgt_addr   (g_wgt_addr),
      .i_wgt_rdata  (wgt_rdata),
      .o_prm_re     (g_prm_re),
      .o_prm_addr   (g_prm_addr),
      .i_prm_rdata  (prm_rdata),
      .o_dst_we     (g_dst_we),
      .o_dst_addr   (g_dst_addr),
      .o_dst_wdata  (g_dst_wdata),
      .o_logit_we   (g_logit_we),
      .o_logit_idx  (g_logit_idx),
      .o_logit_wdata(g_logit_wdata),
      .o_mac_active (mac_active)
  );

  // ---------------------------------------------------------------- pool unit
  logic p_src_re, p_dst_we;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] p_src_addr, p_dst_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0] p_dst_wdata;

  pool_unit #(
      .ADDR_W(16),
      .DIM_W (8),
      .DATA_W(8)
  ) u_pool_unit (
      .clk        (clk),
      .rst        (rst),
      .i_start    (pool_start),
      .o_busy     (pool_busy),
      .o_done     (pool_done),
      .i_src_base (src_base),
      .i_dst_base (dst_base),
      .i_h        (dim_h),
      .i_w        (dim_w),
      .i_c        (c_in),
      .o_src_re   (p_src_re),
      .o_src_addr (p_src_addr),
      .i_src_rdata(src_rdata),
      .o_dst_we   (p_dst_we),
      .o_dst_addr (p_dst_addr),
      .o_dst_wdata(p_dst_wdata)
  );

  // ---------------------------------------------------------------- argmax unit, LOGIT registers
  logic a_rd_en;
  logic [31:0] logit_rdata;
  // Lint waiver: the maximum logit value is not reported (only its index, RESULT), and LOGIT
  // indices above the register file's width are ignored.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] a_max;
  logic [7:0] a_rd_idx;
  /* verilator lint_on UNUSEDSIGNAL */

  argmax_unit #(
      .VAL_W(32),
      .IDX_W(8)
  ) u_argmax_unit (
      .clk      (clk),
      .rst      (rst),
      .i_start  (argmax_start),
      .i_base   (src_base[7:0]),
      .i_count  (c_in),
      .o_busy   (argmax_busy),
      .o_done   (argmax_done),
      .o_result (result),
      .o_max    (a_max),
      .o_rd_en  (a_rd_en),
      .o_rd_idx (a_rd_idx),
      .i_rd_data(logit_rdata)
  );

  logit_rf #(
      .DEPTH(LOGIT_DEPTH),
      .WIDTH(32)
  ) u_logit_rf (
      .clk        (clk),
      .rst        (rst),
      .i_we       (g_logit_we),
      .i_waddr    (g_logit_idx[LOGIT_AW-1:0]),
      .i_wdata    (g_logit_wdata),
      .i_re       (a_rd_en),
      .i_raddr    (a_rd_idx[LOGIT_AW-1:0]),
      .o_rdata    (logit_rdata),
      .i_csr_raddr(csr_logit_raddr),
      .o_csr_rdata(csr_logit_rdata)
  );

  // ================================================================ buffers
  // Per-buffer request decode from the registered src/dst fields (owner order: mem, gemm, pool).
  logic src_img, src_act0, src_act1, dst_act0, dst_act1;
  assign src_img  = (src == 2'd0);
  assign src_act0 = (src == 2'd1);
  assign src_act1 = (src == 2'd2);
  assign dst_act0 = (dst == 2'd1);
  assign dst_act1 = (dst == 2'd2);

  // Requests presented to each multiplexer (bound by the ownership assertions).
  logic [2:0] img_req_re, img_req_we, act0_req_re, act0_req_we, act1_req_re, act1_req_we;
  logic [1:0] wgt_req_re, wgt_req_we, prm_req_re, prm_req_we;
  assign img_req_re  = {p_src_re && src_img, g_src_re && src_img, mem_re[0]};
  assign img_req_we  = {1'b0, 1'b0, mem_we[0]};
  assign act0_req_re = {p_src_re && src_act0, g_src_re && src_act0, mem_re[1]};
  assign act0_req_we = {p_dst_we && dst_act0, g_dst_we && dst_act0, mem_we[1]};
  assign act1_req_re = {p_src_re && src_act1, g_src_re && src_act1, mem_re[2]};
  assign act1_req_we = {p_dst_we && dst_act1, g_dst_we && dst_act1, mem_we[2]};
  assign wgt_req_re  = {g_wgt_re, mem_re[3]};
  assign wgt_req_we  = {1'b0, mem_we[3]};
  assign prm_req_re  = {g_prm_re, mem_re[4]};
  assign prm_req_we  = {1'b0, mem_we[4]};

  // ---------------------------------------------------------------- IMG
  logic [IMG_AW-1:0] img_raddr, img_waddr;
  logic [7:0] img_wdata;
  logic img_we;

  buf_port_mux #(
      .NUM_OWNERS(3),
      .WIDTH     (8),
      .AW        (IMG_AW)
  ) u_buf_port_mux_img (
      .i_owner(own_img),
      .i_re   (img_req_re),
      .i_raddr({p_src_addr[IMG_AW-1:0], g_src_addr[IMG_AW-1:0], mem_addr[IMG_AW-1:0]}),
      .i_we   (img_req_we),
      .i_waddr({{IMG_AW{1'b0}}, {IMG_AW{1'b0}}, mem_addr[IMG_AW-1:0]}),
      .i_wdata({8'd0, 8'd0, mem_wdata[7:0]}),
      .o_re   (img_re),
      .o_raddr(img_raddr),
      .o_we   (img_we),
      .o_waddr(img_waddr),
      .o_wdata(img_wdata)
  );

  sram_1r1w #(
      .WIDTH    (8),
      .DEPTH    (IMG_DEPTH),
      .INIT_FILE(IMG_INIT)
  ) u_sram_1r1w_img (
      .clk    (clk),
      .i_we   (img_we),
      .i_waddr(img_waddr),
      .i_wdata(img_wdata),
      .i_re   (img_re),
      .i_raddr(img_raddr),
      .o_rdata(img_rdata)
  );

  // ---------------------------------------------------------------- ACT0
  logic [ACT_AW-1:0] act0_raddr, act0_waddr;
  logic [7:0] act0_wdata;

  buf_port_mux #(
      .NUM_OWNERS(3),
      .WIDTH     (8),
      .AW        (ACT_AW)
  ) u_buf_port_mux_act0 (
      .i_owner(own_act0),
      .i_re   (act0_req_re),
      .i_raddr({p_src_addr[ACT_AW-1:0], g_src_addr[ACT_AW-1:0], mem_addr[ACT_AW-1:0]}),
      .i_we   (act0_req_we),
      .i_waddr({p_dst_addr[ACT_AW-1:0], g_dst_addr[ACT_AW-1:0], mem_addr[ACT_AW-1:0]}),
      .i_wdata({p_dst_wdata, g_dst_wdata, mem_wdata[7:0]}),
      .o_re   (act0_re),
      .o_raddr(act0_raddr),
      .o_we   (act0_we),
      .o_waddr(act0_waddr),
      .o_wdata(act0_wdata)
  );

  sram_1r1w #(
      .WIDTH(8),
      .DEPTH(ACT_DEPTH)
  ) u_sram_1r1w_act0 (
      .clk    (clk),
      .i_we   (act0_we),
      .i_waddr(act0_waddr),
      .i_wdata(act0_wdata),
      .i_re   (act0_re),
      .i_raddr(act0_raddr),
      .o_rdata(act0_rdata)
  );

  // ---------------------------------------------------------------- ACT1
  logic [ACT_AW-1:0] act1_raddr, act1_waddr;
  logic [7:0] act1_wdata;

  buf_port_mux #(
      .NUM_OWNERS(3),
      .WIDTH     (8),
      .AW        (ACT_AW)
  ) u_buf_port_mux_act1 (
      .i_owner(own_act1),
      .i_re   (act1_req_re),
      .i_raddr({p_src_addr[ACT_AW-1:0], g_src_addr[ACT_AW-1:0], mem_addr[ACT_AW-1:0]}),
      .i_we   (act1_req_we),
      .i_waddr({p_dst_addr[ACT_AW-1:0], g_dst_addr[ACT_AW-1:0], mem_addr[ACT_AW-1:0]}),
      .i_wdata({p_dst_wdata, g_dst_wdata, mem_wdata[7:0]}),
      .o_re   (act1_re),
      .o_raddr(act1_raddr),
      .o_we   (act1_we),
      .o_waddr(act1_waddr),
      .o_wdata(act1_wdata)
  );

  sram_1r1w #(
      .WIDTH(8),
      .DEPTH(ACT_DEPTH)
  ) u_sram_1r1w_act1 (
      .clk    (clk),
      .i_we   (act1_we),
      .i_waddr(act1_waddr),
      .i_wdata(act1_wdata),
      .i_re   (act1_re),
      .i_raddr(act1_raddr),
      .o_rdata(act1_rdata)
  );

  // ---------------------------------------------------------------- WGT
  logic [WGT_AW-1:0] wgt_raddr, wgt_waddr;
  logic [WGT_W-1:0] wgt_wdata;
  logic wgt_we;

  buf_port_mux #(
      .NUM_OWNERS(2),
      .WIDTH     (WGT_W),
      .AW        (WGT_AW)
  ) u_buf_port_mux_wgt (
      .i_owner(own_wgt),
      .i_re   (wgt_req_re),
      .i_raddr({g_wgt_addr, mem_addr[WGT_AW-1:0]}),
      .i_we   (wgt_req_we),
      .i_waddr({{WGT_AW{1'b0}}, mem_addr[WGT_AW-1:0]}),
      .i_wdata({{WGT_W{1'b0}}, mem_wgt_wdata}),
      .o_re   (wgt_re),
      .o_raddr(wgt_raddr),
      .o_we   (wgt_we),
      .o_waddr(wgt_waddr),
      .o_wdata(wgt_wdata)
  );

  sram_1r1w #(
      .WIDTH    (WGT_W),
      .DEPTH    (WGT_DEPTH),
      .INIT_FILE(WGT_INIT)
  ) u_sram_1r1w_wgt (
      .clk    (clk),
      .i_we   (wgt_we),
      .i_waddr(wgt_waddr),
      .i_wdata(wgt_wdata),
      .i_re   (wgt_re),
      .i_raddr(wgt_raddr),
      .o_rdata(wgt_rdata)
  );

  // ---------------------------------------------------------------- PARAM
  logic [PRM_AW-1:0] prm_raddr, prm_waddr;
  logic [63:0] prm_wdata;
  logic prm_we;

  buf_port_mux #(
      .NUM_OWNERS(2),
      .WIDTH     (64),
      .AW        (PRM_AW)
  ) u_buf_port_mux_prm (
      .i_owner(own_prm),
      .i_re   (prm_req_re),
      .i_raddr({g_prm_addr, mem_addr[PRM_AW-1:0]}),
      .i_we   (prm_req_we),
      .i_waddr({{PRM_AW{1'b0}}, mem_addr[PRM_AW-1:0]}),
      .i_wdata({64'd0, mem_wdata}),
      .o_re   (prm_re),
      .o_raddr(prm_raddr),
      .o_we   (prm_we),
      .o_waddr(prm_waddr),
      .o_wdata(prm_wdata)
  );

  sram_1r1w #(
      .WIDTH    (64),
      .DEPTH    (PARAM_DEPTH),
      .INIT_FILE(PARAM_INIT)
  ) u_sram_1r1w_prm (
      .clk    (clk),
      .i_we   (prm_we),
      .i_waddr(prm_waddr),
      .i_wdata(prm_wdata),
      .i_re   (prm_re),
      .i_raddr(prm_raddr),
      .o_rdata(prm_rdata)
  );

  // ================================================================ status outputs
  assign o_busy      = seq_busy;
  assign o_done      = seq_done;
  assign o_error     = seq_error;
  assign o_result    = result;
  assign o_cyc_total = 32'(cyc_total);

endmodule
