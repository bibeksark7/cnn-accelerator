// soc_top: the RISC-V SoC (spec §13): PicoRV32 (picorv32_axi), an AXI4-Lite interconnect, the
// RAM, the accelerator behind its AXI4-Lite slave, and the GPIO block. Board-independent; the
// DE10-Lite top adds pins, reset and input conditioning (spec §13.7).
//
// Address map (spec §13.3; anything else gets DECERR):
//   0x0000_0000  RAM, RAM_BYTES                          (axil_ram)
//   0x1000_0000  accelerator, 8 MB: CSR window 4 KB at +0, buffer window 4 MB at +0x40_0000
//                                                        (accel_axil_slave; its CSR hole DECERRs)
//   0x2000_0000  GPIO, 4 KB                              (axil_gpio)
//
// CPU configuration (spec §13.2): RV32IM, fast multiplier, divider, barrel shifter, 32-bit
// cycle/instret counters, no compressed instructions, no interrupts; a misaligned access or
// illegal instruction (also ecall/ebreak) halts the CPU with o_trap = 1. Reset vector 0, initial
// sp = RAM_BYTES.
//
// Parameters:
//   RAM_BYTES                      - RAM size (power of two, at least 4 KB)
//   RAM_INIT                       - firmware image ($readmemh, 32-bit words from address 0)
//   IMG_INIT, WGT_INIT, PARAM_INIT, DESC_INIT - accelerator init files (spec §11.1)
//
// Ports:
//   clk, rst                             - clock, synchronous active-high reset (RAM and
//                                          accelerator buffers keep their contents)
//   i_sw, i_key_level, i_key_press       - synchronized switches, debounced KEY[0] (GPIO)
//   o_ledr, o_hex_code, o_mailbox        - GPIO outputs
//   o_trap                               - the CPU has trapped and halted (until reset)
//
// Latency: not applicable (a system).
module soc_top #(
    parameter int RAM_BYTES  = 65536,
    parameter     RAM_INIT   = "",
    parameter     IMG_INIT   = "",
    parameter     WGT_INIT   = "",
    parameter     PARAM_INIT = "",
    parameter     DESC_INIT  = ""
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [ 9:0] i_sw,
    input  logic        i_key_level,
    input  logic        i_key_press,
    output logic [ 8:0] o_ledr,
    output logic [29:0] o_hex_code,
    output logic [31:0] o_mailbox,
    output logic        o_trap
);

  localparam int NS = 3;
  localparam int S_RAM = 0, S_ACCEL = 1, S_GPIO = 2;
  localparam int RAM_AW = $clog2(RAM_BYTES);
  localparam logic [31:0] RAM_MASK = ~(32'(RAM_BYTES) - 32'd1);
  localparam logic [NS*32-1:0] BASE = {32'h2000_0000, 32'h1000_0000, 32'h0000_0000};
  localparam logic [NS*32-1:0] MASK = {32'hFFFF_F000, 32'hFF80_0000, RAM_MASK};

  // ---------------------------------------------------------------- CPU
  logic cpu_awvalid, cpu_awready, cpu_wvalid, cpu_wready, cpu_bvalid, cpu_bready;
  logic cpu_arvalid, cpu_arready, cpu_rvalid, cpu_rready;
  logic [31:0] cpu_awaddr, cpu_wdata, cpu_araddr, cpu_rdata;
  logic [3:0] cpu_wstrb;
  logic [1:0] cpu_bresp, cpu_rresp;

  // Lint waiver: AWPROT/ARPROT are not used (spec §13.3); PicoRV32 ignores BRESP/RRESP, and its
  // PCPI, IRQ and trace ports are unused in this configuration.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2:0] cpu_awprot, cpu_arprot;
  logic [1:0] unused_resp;
  logic pcpi_valid, trace_valid;
  logic [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2, eoi;
  logic [35:0] trace_data;
  /* verilator lint_on UNUSEDSIGNAL */
  assign unused_resp = cpu_bresp | cpu_rresp;

  picorv32_axi #(
      .ENABLE_COUNTERS     (1),
      .ENABLE_COUNTERS64   (0),
      .ENABLE_REGS_16_31   (1),
      .ENABLE_REGS_DUALPORT(1),
      .TWO_STAGE_SHIFT     (1),
      .BARREL_SHIFTER      (1),
      .TWO_CYCLE_COMPARE   (0),
      .TWO_CYCLE_ALU       (0),
      .COMPRESSED_ISA      (0),
      .CATCH_MISALIGN      (1),
      .CATCH_ILLINSN       (1),
      .ENABLE_PCPI         (0),
      .ENABLE_MUL          (0),
      .ENABLE_FAST_MUL     (1),
      .ENABLE_DIV          (1),
      .ENABLE_IRQ          (0),
      .ENABLE_IRQ_QREGS    (0),
      .ENABLE_IRQ_TIMER    (0),
      .ENABLE_TRACE        (0),
      .REGS_INIT_ZERO      (0),
      .PROGADDR_RESET      (32'h0000_0000),
      .STACKADDR           (32'(RAM_BYTES))
  ) u_picorv32_axi (
      .clk            (clk),
      .resetn         (!rst),
      .trap           (o_trap),
      .mem_axi_awvalid(cpu_awvalid),
      .mem_axi_awready(cpu_awready),
      .mem_axi_awaddr (cpu_awaddr),
      .mem_axi_awprot (cpu_awprot),
      .mem_axi_wvalid (cpu_wvalid),
      .mem_axi_wready (cpu_wready),
      .mem_axi_wdata  (cpu_wdata),
      .mem_axi_wstrb  (cpu_wstrb),
      .mem_axi_bvalid (cpu_bvalid),
      .mem_axi_bready (cpu_bready),
      .mem_axi_arvalid(cpu_arvalid),
      .mem_axi_arready(cpu_arready),
      .mem_axi_araddr (cpu_araddr),
      .mem_axi_arprot (cpu_arprot),
      .mem_axi_rvalid (cpu_rvalid),
      .mem_axi_rready (cpu_rready),
      .mem_axi_rdata  (cpu_rdata),
      .pcpi_valid     (pcpi_valid),
      .pcpi_insn      (pcpi_insn),
      .pcpi_rs1       (pcpi_rs1),
      .pcpi_rs2       (pcpi_rs2),
      .pcpi_wr        (1'b0),
      .pcpi_rd        (32'd0),
      .pcpi_wait      (1'b0),
      .pcpi_ready     (1'b0),
      .irq            (32'd0),
      .eoi            (eoi),
      .trace_valid    (trace_valid),
      .trace_data     (trace_data)
  );

  // ---------------------------------------------------------------- interconnect
  logic [NS-1:0] m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [NS-1:0] m_arvalid, m_arready, m_rvalid, m_rready;
  logic [31:0] m_wdata;
  // Lint waiver: the interconnect has decoded the region; each slave takes only its offset bits.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] m_awaddr, m_araddr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [3:0] m_wstrb;
  logic [2*NS-1:0] m_bresp, m_rresp;
  logic [32*NS-1:0] m_rdata;

  axil_interconnect #(
      .NS  (NS),
      .BASE(BASE),
      .MASK(MASK)
  ) u_axil_interconnect (
      .clk        (clk),
      .rst        (rst),
      .i_s_awvalid(cpu_awvalid),
      .o_s_awready(cpu_awready),
      .i_s_awaddr (cpu_awaddr),
      .i_s_wvalid (cpu_wvalid),
      .o_s_wready (cpu_wready),
      .i_s_wdata  (cpu_wdata),
      .i_s_wstrb  (cpu_wstrb),
      .o_s_bvalid (cpu_bvalid),
      .i_s_bready (cpu_bready),
      .o_s_bresp  (cpu_bresp),
      .i_s_arvalid(cpu_arvalid),
      .o_s_arready(cpu_arready),
      .i_s_araddr (cpu_araddr),
      .o_s_rvalid (cpu_rvalid),
      .i_s_rready (cpu_rready),
      .o_s_rdata  (cpu_rdata),
      .o_s_rresp  (cpu_rresp),
      .o_m_awvalid(m_awvalid),
      .i_m_awready(m_awready),
      .o_m_awaddr (m_awaddr),
      .o_m_wvalid (m_wvalid),
      .i_m_wready (m_wready),
      .o_m_wdata  (m_wdata),
      .o_m_wstrb  (m_wstrb),
      .i_m_bvalid (m_bvalid),
      .o_m_bready (m_bready),
      .i_m_bresp  (m_bresp),
      .o_m_arvalid(m_arvalid),
      .i_m_arready(m_arready),
      .o_m_araddr (m_araddr),
      .i_m_rvalid (m_rvalid),
      .o_m_rready (m_rready),
      .i_m_rdata  (m_rdata),
      .i_m_rresp  (m_rresp)
  );

  // ---------------------------------------------------------------- RAM
  axil_ram #(
      .BYTES    (RAM_BYTES),
      .INIT_FILE(RAM_INIT)
  ) u_axil_ram (
      .clk      (clk),
      .rst      (rst),
      .i_awvalid(m_awvalid[S_RAM]),
      .o_awready(m_awready[S_RAM]),
      .i_awaddr (m_awaddr[RAM_AW-1:0]),
      .i_wvalid (m_wvalid[S_RAM]),
      .o_wready (m_wready[S_RAM]),
      .i_wdata  (m_wdata),
      .i_wstrb  (m_wstrb),
      .o_bvalid (m_bvalid[S_RAM]),
      .i_bready (m_bready[S_RAM]),
      .o_bresp  (m_bresp[2*S_RAM+:2]),
      .i_arvalid(m_arvalid[S_RAM]),
      .o_arready(m_arready[S_RAM]),
      .i_araddr (m_araddr[RAM_AW-1:0]),
      .o_rvalid (m_rvalid[S_RAM]),
      .i_rready (m_rready[S_RAM]),
      .o_rdata  (m_rdata[32*S_RAM+:32]),
      .o_rresp  (m_rresp[2*S_RAM+:2])
  );

  // ---------------------------------------------------------------- accelerator
  logic csr_valid, csr_ready, csr_we;
  logic [11:0] csr_addr;
  logic [31:0] csr_wdata, csr_rdata;
  logic mem_valid, mem_ready, mem_we, mem_rvalid;
  logic [2:0] mem_sel;
  logic [15:0] mem_addr;
  logic [63:0] mem_wdata, mem_rdata;

  accel_axil_slave u_accel_axil_slave (
      .clk         (clk),
      .rst         (rst),
      .i_awvalid   (m_awvalid[S_ACCEL]),
      .o_awready   (m_awready[S_ACCEL]),
      .i_awaddr    (m_awaddr[22:0]),
      .i_wvalid    (m_wvalid[S_ACCEL]),
      .o_wready    (m_wready[S_ACCEL]),
      .i_wdata     (m_wdata),
      .i_wstrb     (m_wstrb),
      .o_bvalid    (m_bvalid[S_ACCEL]),
      .i_bready    (m_bready[S_ACCEL]),
      .o_bresp     (m_bresp[2*S_ACCEL+:2]),
      .i_arvalid   (m_arvalid[S_ACCEL]),
      .o_arready   (m_arready[S_ACCEL]),
      .i_araddr    (m_araddr[22:0]),
      .o_rvalid    (m_rvalid[S_ACCEL]),
      .i_rready    (m_rready[S_ACCEL]),
      .o_rdata     (m_rdata[32*S_ACCEL+:32]),
      .o_rresp     (m_rresp[2*S_ACCEL+:2]),
      .o_csr_valid (csr_valid),
      .i_csr_ready (csr_ready),
      .o_csr_we    (csr_we),
      .o_csr_addr  (csr_addr),
      .o_csr_wdata (csr_wdata),
      .i_csr_rdata (csr_rdata),
      .o_mem_valid (mem_valid),
      .i_mem_ready (mem_ready),
      .o_mem_we    (mem_we),
      .o_mem_sel   (mem_sel),
      .o_mem_addr  (mem_addr),
      .o_mem_wdata (mem_wdata),
      .i_mem_rvalid(mem_rvalid),
      .i_mem_rdata (mem_rdata)
  );

  // Lint waiver: firmware reads the accelerator's status through the CSR window.
  /* verilator lint_off UNUSEDSIGNAL */
  logic acc_busy, acc_done, acc_error;
  logic [7:0] acc_result;
  logic [31:0] acc_cyc_total;
  /* verilator lint_on UNUSEDSIGNAL */

  accel_top #(
      .IMG_INIT  (IMG_INIT),
      .WGT_INIT  (WGT_INIT),
      .PARAM_INIT(PARAM_INIT),
      .DESC_INIT (DESC_INIT)
  ) u_accel_top (
      .clk         (clk),
      .rst         (rst),
      .i_csr_valid (csr_valid),
      .i_csr_we    (csr_we),
      .i_csr_addr  (csr_addr),
      .i_csr_wdata (csr_wdata),
      .o_csr_ready (csr_ready),
      .o_csr_rdata (csr_rdata),
      .i_mem_valid (mem_valid),
      .o_mem_ready (mem_ready),
      .i_mem_we    (mem_we),
      .i_mem_sel   (mem_sel),
      .i_mem_addr  (mem_addr),
      .i_mem_wdata (mem_wdata),
      .o_mem_rvalid(mem_rvalid),
      .o_mem_rdata (mem_rdata),
      .o_busy      (acc_busy),
      .o_done      (acc_done),
      .o_error     (acc_error),
      .o_result    (acc_result),
      .o_cyc_total (acc_cyc_total)
  );

  // ---------------------------------------------------------------- GPIO
  axil_gpio u_axil_gpio (
      .clk        (clk),
      .rst        (rst),
      .i_awvalid  (m_awvalid[S_GPIO]),
      .o_awready  (m_awready[S_GPIO]),
      .i_awaddr   (m_awaddr[11:0]),
      .i_wvalid   (m_wvalid[S_GPIO]),
      .o_wready   (m_wready[S_GPIO]),
      .i_wdata    (m_wdata),
      .i_wstrb    (m_wstrb),
      .o_bvalid   (m_bvalid[S_GPIO]),
      .i_bready   (m_bready[S_GPIO]),
      .o_bresp    (m_bresp[2*S_GPIO+:2]),
      .i_arvalid  (m_arvalid[S_GPIO]),
      .o_arready  (m_arready[S_GPIO]),
      .i_araddr   (m_araddr[11:0]),
      .o_rvalid   (m_rvalid[S_GPIO]),
      .i_rready   (m_rready[S_GPIO]),
      .o_rdata    (m_rdata[32*S_GPIO+:32]),
      .o_rresp    (m_rresp[2*S_GPIO+:2]),
      .i_sw       (i_sw),
      .i_key_level(i_key_level),
      .i_key_press(i_key_press),
      .o_ledr     (o_ledr),
      .o_hex_code (o_hex_code),
      .o_mailbox  (o_mailbox)
  );

endmodule
