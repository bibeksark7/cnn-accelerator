// accel_coverage: functional coverage of the AXI4-Lite slave, its register map and its runs.
// Sampled by accel_scoreboard, which supplies what a bus monitor alone cannot know (whether the
// accelerator was busy when the slave could serve the access, WHI's value, the run's predicted
// outcome).
//
// Bins are collected with Verilator's --coverage-user into coverage.dat per test and merged and
// reported by scripts/uvm_coverage.py (goals and documented gaps there). get_coverage() is not
// used: Verilator does not support it per coverpoint (docs/decisions.md D-052).
class accel_coverage extends uvm_object;
  `uvm_object_utils(accel_coverage)

  typedef enum int {
    A_CSR_READ,
    A_CSR_WRITE,
    A_WHI_WRITE,
    A_BUF_READ,
    A_BUF_LOW_WRITE,
    A_ERROR_RESP
  } access_e;
  typedef enum int {
    E_START_IGNORED_BUSY,
    E_RESET_DURING_RUN,
    E_RESET_IDLE,
    E_BACK_TO_BACK
  } event_e;

  // sample() arguments
  bit we, partial, is_buf, is_hole, half, low_addr, wrapped, busy_at_s, whi_nz;
  csr_e csr;
  int unsigned sel, strb, aw_minus_w, aw_stall, w_stall, ar_stall, resp_stall;
  access_e access;
  run_outcome_e outcome;
  int unsigned img_sel;
  bit golden;
  event_e ev;
  int runs_since_reset;

  // Every register (and the unmapped offsets) read and written.
  covergroup cg_csr;
    cp_reg: coverpoint csr;
    cp_we: coverpoint we;
    x_reg_we: cross cp_reg, cp_we;
  endgroup

  // Every response the slave can give, by region and direction.
  covergroup cg_resp;
    cp_case: coverpoint {is_buf, is_hole, we, partial} {
      bins csr_read_okay = {4'b0000};
      bins csr_write_okay = {4'b0010};
      bins csr_write_partial_slverr = {4'b0011};
      bins hole_read_decerr = {4'b0100};
      bins hole_write_decerr = {4'b0110};
      bins hole_write_partial_decerr = {4'b0111};
      bins buf_read_okay = {4'b1000};
      bins buf_write_okay = {4'b1010};
      bins buf_write_partial_slverr = {4'b1011};
    }
  endgroup

  // Every buffer select (reserved ones included), both halves, read and write.
  covergroup cg_buf;
    cp_sel: coverpoint sel {bins s[] = {[0 : 7]};}
    cp_half: coverpoint half;
    cp_we: coverpoint we;
    x_sel_half_we: cross cp_sel, cp_half, cp_we;
  endgroup

  // Word addresses past a buffer's depth (they wrap, spec §5), per buffer.
  covergroup cg_wrap;
    cp_sel: coverpoint sel iff (wrapped) {bins s[] = {[0 : 4]};}
  endgroup

  // Ignored address bits [1:0] set, in both windows.
  covergroup cg_low_addr;
    cp_region: coverpoint is_buf iff (low_addr);
  endgroup

  // Partial write strobes (every pattern but 4'b1111).
  covergroup cg_strb;
    cp_strb: coverpoint strb iff (partial) {bins p[] = {[0 : 14]};}
  endgroup

  // AW / W acceptance order (at this slave both orders and the same cycle are reachable).
  covergroup cg_aw_w_order;
    cp_order: coverpoint aw_minus_w iff (we) {
      bins aw_first = {[32'h8000_0000 : 32'hFFFF_FFFF]};  // negative: AW accepted earlier
      bins same_cycle = {0};
      bins w_first = {[1 : 32'h7FFF_FFFF]};
    }
  endgroup

  // Backpressure: request VALID waiting for READY, and response VALID waiting for the master.
  covergroup cg_stall;
    cp_aw: coverpoint aw_stall iff (we) {bins none = {0}; bins stalled = {[1 : $]};}
    cp_w: coverpoint w_stall iff (we) {bins none = {0}; bins stalled = {[1 : $]};}
    cp_ar: coverpoint ar_stall iff (!we) {bins none = {0}; bins stalled = {[1 : $]};}
    cp_resp: coverpoint resp_stall {
      bins at_once = {0};
      bins waited_1_2 = {[1 : 2]};
      bins waited_3_plus = {[3 : $]};
    }
  endgroup

  // Each kind of access arriving while idle and during a run.
  covergroup cg_access_busy;
    cp_access: coverpoint access;
    cp_busy: coverpoint busy_at_s;
    x_access_busy: cross cp_access, cp_busy;
  endgroup

  // Low-half writes with WHI zero and non-zero, to byte, wide and reserved buffers.
  covergroup cg_whi;
    cp_target: coverpoint sel iff (we && is_buf && !half && !partial) {
      bins byte_buf = {[0 : 2]};
      bins wide_buf = {[3 : 4]};
      bins reserved = {[5 : 7]};
    }
    cp_whi: coverpoint whi_nz iff (we && is_buf && !half && !partial);
    x_target_whi: cross cp_target, cp_whi;
  endgroup

  // Runs: every image slot started, every predicted outcome (spec §9 errors), golden checks.
  covergroup cg_run;
    cp_img_sel: coverpoint img_sel {bins slot[] = {[0 : 15]};}
    cp_outcome: coverpoint outcome {ignore_bins unknown = {RUN_UNKNOWN};}
    cp_golden: coverpoint golden {bins checked = {1};}
  endgroup

  covergroup cg_event;
    cp_ev: coverpoint ev;
  endgroup

  function new(string name = "accel_coverage");
    super.new(name);
    cg_csr = new;
    cg_resp = new;
    cg_buf = new;
    cg_wrap = new;
    cg_low_addr = new;
    cg_strb = new;
    cg_aw_w_order = new;
    cg_stall = new;
    cg_access_busy = new;
    cg_whi = new;
    cg_run = new;
    cg_event = new;
  endfunction

  function void sample_access(axil_item t, bit busy, bit whi_nonzero);
    we = t.kind == AXIL_WRITE;
    partial = we && t.strb != 4'hF;
    strb = t.strb;
    is_buf = t.addr[22];
    is_hole = !is_buf && t.addr[21:12] != 0;
    half = t.addr[2];
    low_addr = t.addr[1:0] != 0 && !is_hole;
    sel = t.addr[21:19];
    wrapped = is_buf && sel < N_BUFS && int'(t.addr[18:3]) >= BUF_DEPTH[sel];
    csr = csr_kind(t.addr[11:0]);
    aw_minus_w = 32'(t.aw_cycle - t.w_cycle);
    aw_stall = t.aw_stall;
    w_stall = t.w_stall;
    ar_stall = t.ar_stall;
    resp_stall = t.resp_stall;
    busy_at_s = busy;
    whi_nz = whi_nonzero;
    if (is_hole || partial) access = A_ERROR_RESP;
    else if (!is_buf) access = we ? A_CSR_WRITE : A_CSR_READ;
    else if (!we) access = A_BUF_READ;
    else access = half ? A_WHI_WRITE : A_BUF_LOW_WRITE;
    cg_resp.sample();
    cg_aw_w_order.sample();
    cg_stall.sample();
    cg_access_busy.sample();
    cg_strb.sample();
    cg_low_addr.sample();
    if (!is_hole && !is_buf && !partial) cg_csr.sample();
    if (is_buf && !partial) begin
      cg_buf.sample();
      cg_wrap.sample();
    end
    cg_whi.sample();
  endfunction

  function void sample_run(run_outcome_e o, int unsigned slot, bit is_golden);
    outcome = o;
    img_sel = slot;
    golden = is_golden;
    cg_run.sample();
    runs_since_reset++;
    if (runs_since_reset >= 2) sample_event(E_BACK_TO_BACK);
  endfunction

  function void sample_event(event_e e);
    ev = e;
    cg_event.sample();
    if (e inside {E_RESET_DURING_RUN, E_RESET_IDLE}) runs_since_reset = 0;
  endfunction
endclass
