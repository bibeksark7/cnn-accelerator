// axil_gpio: board I/O registers as an AXI4-Lite slave (spec §13.6).
//
// Register map (byte offsets in the 4 KB region; unmapped offsets read 0 and ignore writes, OKAY):
//   0x000 LEDR     RW  [8:0] o_ledr (LEDR[9] is the CPU trap, wired in the board top)
//   0x004 HEX      RW  six 5-bit hex7seg codes, HEXd in [5d+4 : 5d]; reset 0x2108_4210 (blank)
//   0x008 SW       RO  [9:0] i_sw
//   0x00C KEY      RO  [0] i_key_level
//   0x010 KEY_EVT  RW1C [0] set by i_key_press; writing 1 clears it (a press in the same cycle wins)
//   0x014 MAILBOX  RW  o_mailbox
// Writes must be full words: a write with WSTRB != 4'b1111 is not performed and gets SLVERR.
// Reads always return the whole word with OKAY. Address bits [1:0] are ignored.
//
// Ports:
//   clk, rst                          - clock, synchronous active-high reset
//   i_awvalid ... o_rresp             - AXI4-Lite slave (axil_slave_port), 12 address bits
//   i_sw, i_key_level, i_key_press    - synchronized switches, debounced KEY[0] level and press
//   o_ledr, o_hex_code, o_mailbox     - register outputs
//
// Latency: every access is answered in the cycle its request is accepted.
module axil_gpio (
    input  logic        clk,
    input  logic        rst,
    input  logic        i_awvalid,
    output logic        o_awready,
    input  logic [11:0] i_awaddr,
    input  logic        i_wvalid,
    output logic        o_wready,
    input  logic [31:0] i_wdata,
    input  logic [ 3:0] i_wstrb,
    output logic        o_bvalid,
    input  logic        i_bready,
    output logic [ 1:0] o_bresp,
    input  logic        i_arvalid,
    output logic        o_arready,
    input  logic [11:0] i_araddr,
    output logic        o_rvalid,
    input  logic        i_rready,
    output logic [31:0] o_rdata,
    output logic [ 1:0] o_rresp,
    input  logic [ 9:0] i_sw,
    input  logic        i_key_level,
    input  logic        i_key_press,
    output logic [ 8:0] o_ledr,
    output logic [29:0] o_hex_code,
    output logic [31:0] o_mailbox
);

  localparam logic [9:0] A_LEDR = 10'h000, A_HEX = 10'h001, A_SW = 10'h002;
  localparam logic [9:0] A_KEY = 10'h003, A_KEY_EVT = 10'h004, A_MAILBOX = 10'h005;
  localparam logic [29:0] HEX_BLANK = 30'h2108_4210;  // code 16 in every digit
  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

  logic req_valid, req_we;
  logic [11:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0] req_wstrb;
  logic [31:0] rdata;
  logic [1:0] resp;

  axil_slave_port #(
      .ADDR_W(12)
  ) u_axil_slave_port (
      .clk        (clk),
      .rst        (rst),
      .i_awvalid  (i_awvalid),
      .o_awready  (o_awready),
      .i_awaddr   (i_awaddr),
      .i_wvalid   (i_wvalid),
      .o_wready   (o_wready),
      .i_wdata    (i_wdata),
      .i_wstrb    (i_wstrb),
      .o_bvalid   (o_bvalid),
      .i_bready   (i_bready),
      .o_bresp    (o_bresp),
      .i_arvalid  (i_arvalid),
      .o_arready  (o_arready),
      .i_araddr   (i_araddr),
      .o_rvalid   (o_rvalid),
      .i_rready   (i_rready),
      .o_rdata    (o_rdata),
      .o_rresp    (o_rresp),
      .o_req_valid(req_valid),
      .i_req_ready(1'b1),
      .o_req_we   (req_we),
      .o_req_addr (req_addr),
      .o_req_wdata(req_wdata),
      .o_req_wstrb(req_wstrb),
      .i_rsp_valid(req_valid),
      .i_rsp_resp (resp),
      .i_rsp_rdata(rdata)
  );

  // Lint waiver: address bits [1:0] are ignored (word registers).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [11:0] addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [9:0] reg_idx;
  logic wr;
  assign addr    = req_addr;
  assign reg_idx = addr[11:2];
  assign wr      = req_valid && req_we && req_wstrb == 4'b1111;
  assign resp    = (req_we && req_wstrb != 4'b1111) ? RESP_SLVERR : RESP_OKAY;

  logic [8:0] ledr_q;
  logic [29:0] hex_q;
  logic [31:0] mailbox_q;
  logic key_evt_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      ledr_q    <= '0;
      hex_q     <= HEX_BLANK;
      mailbox_q <= '0;
      key_evt_q <= 1'b0;
    end else begin
      if (wr && reg_idx == A_LEDR) ledr_q <= req_wdata[8:0];
      if (wr && reg_idx == A_HEX) hex_q <= req_wdata[29:0];
      if (wr && reg_idx == A_MAILBOX) mailbox_q <= req_wdata;
      if (i_key_press) key_evt_q <= 1'b1;
      else if (wr && reg_idx == A_KEY_EVT && req_wdata[0]) key_evt_q <= 1'b0;
    end
  end

  always_comb begin
    case (reg_idx)
      A_LEDR:    rdata = {23'd0, ledr_q};
      A_HEX:     rdata = {2'd0, hex_q};
      A_SW:      rdata = {22'd0, i_sw};
      A_KEY:     rdata = {31'd0, i_key_level};
      A_KEY_EVT: rdata = {31'd0, key_evt_q};
      A_MAILBOX: rdata = mailbox_q;
      default:   rdata = 32'd0;
    endcase
  end

  assign o_ledr     = ledr_q;
  assign o_hex_code = hex_q;
  assign o_mailbox  = mailbox_q;

endmodule
