// accel_scoreboard: predictor and checker for the accelerator's AXI4-Lite slave (spec §13.4)
// and, through it, the CSR map (§10.2), the buffers (§10.3) and runs (§9).
//
// Input: every completed transaction from axil_monitor, in completion order, and the BUSY
// timeline and run events from accel_status_monitor. The slave serves one transaction at a time
// (spec §13.4), so completion order is service order and the model applies each transaction's
// effect in that order.
//
// Busy-awareness without assumed latencies. A transaction's service can start no earlier than
// `s` = max(cycle its last request channel was accepted, cycle the previous response was
// accepted), and its register or memory-port access happens before its response is valid (`v`).
// Only this slave can start a run, and nothing starts one between s and the access, so:
//   idle at s                      -> the access happened while idle;
//   busy at s, BUSY never fell     -> the access happened while busy;
//   busy at s, BUSY fell before v  -> unknown: a write's effect becomes unknown, a read is not
//                                     checked (counted as such).
//
// Model: the CSR registers (mirrored into accel_regs by explicit prediction), the high-half
// staging register WHI, and a shadow of every buffer word the bench wrote (a word never written,
// or changed by a run, is unknown and its reads are not checked). At a performed START the
// descriptor table is checked as the sequencer will (spec §9 errors) and, when the table, WGT,
// PARAM and the selected image slot equal the reference network and one of the reference images,
// the run's logits and class are taken from the Python export (accel_ref). When the run ends
// (BUSY falls) ERROR and RESULT are checked on accel_top's outputs, and every later read of
// STATUS, RESULT, LOGIT and LAYER_CYC is checked against the prediction.
//
// Also checked per transaction: the response (OKAY / SLVERR / DECERR by address and strobes),
// that register accesses, WHI writes and error responses are answered within ACCESS_BOUND cycles
// of `s` even during a run (spec §13.4: never held for a run), and that a buffer-window access
// (read, or low-half write) that arrives while busy completes only after the run ends.
`uvm_analysis_imp_decl(_axil)
`uvm_analysis_imp_decl(_run)

class accel_scoreboard extends uvm_component;
  `uvm_component_utils(accel_scoreboard)

  uvm_analysis_imp_axil #(axil_item, accel_scoreboard) axil_imp;
  uvm_analysis_imp_run #(accel_run_event, accel_scoreboard) run_imp;
  virtual accel_status_if vif;  // for the cycle loop only
  accel_timeline timeline;
  accel_ref refd;
  accel_regs regs;
  accel_coverage cov;

  axil_item txq[$];
  accel_run_event evq[$];
  longint last_resp_cycle = 0;
  bit reset_seen = 0;

  // ---- model state
  bit [63:0] mem[N_BUFS][int];  // known buffer words
  bit [31:0] whi;
  bit img_sel_known, desc_known[DESC_WORDS];
  bit [3:0] img_sel;
  bit [31:0] desc[DESC_WORDS];
  bit status_known, done, error;
  bit [3:0] layer;
  bit result_known;
  bit [7:0] result;
  bit logit_known[LOGIT_DEPTH];
  bit [31:0] logit[LOGIT_DEPTH];
  int layer_cyc_nz[DESC_DEPTH];  // 0 zero, 1 nonzero, -1 unknown
  bit counters_zero;  // after reset, before any run
  longint last_busy_cycles = -1;  // BUSY cycles of the last run that ended normally
  bit [31:0] ctr_last[4];  // counters read during the current run (non-decreasing)
  // The run in progress, as predicted at its START.
  bit run_active, run_unknown;
  run_outcome_e run_outcome;
  int run_layer;  // last layer (OK) or the failing layer
  bit run_golden, run_argmax_before_end;
  int run_ref;

  // ---- statistics (reported, and required by the tests)
  int unsigned n_txn, n_checked_reads, n_unchecked_reads, n_errors_seen;
  int unsigned n_starts, n_runs_ended, n_golden_runs, n_logits_checked, n_rises;
  int unsigned n_resp_checked, n_ambiguous_starts;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    axil_imp = new("axil_imp", this);
    run_imp  = new("run_imp", this);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual accel_status_if)::get(this, "", "status_vif", vif))
      `uvm_fatal("NOVIF", "accel_scoreboard: no status interface")
  endfunction

  function void write_axil(axil_item t);
    txq.push_back(t);
  endfunction

  function void write_run(accel_run_event e);
    if (e.kind == accel_run_event::EV_START) n_rises++;
    else evq.push_back(e);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      process(0);
    end
  endtask

  // Transactions are processed once the timeline covers two cycles past their response, and run
  // events strictly before a transaction's response-valid cycle are applied before it (a later
  // event cannot have affected it). Events with no transaction after them are applied once no
  // in-flight transaction can still precede them (EVENT_DEFER cycles: a generous bound on how
  // long a response waits for READY), or at the end of the test.
  localparam longint EVENT_DEFER = 256;
  function void process(bit flush);
    while (txq.size() > 0 && (flush || txq[0].resp_cycle + 2 <= timeline.known_until)) begin
      axil_item t = txq.pop_front();
      while (evq.size() > 0 && evq[0].cycle < t.resp_valid_cycle) apply_event(evq.pop_front());
      check_txn(t);
    end
    while (evq.size() > 0 && (flush || evq[0].cycle + EVENT_DEFER <= timeline.known_until))
      apply_event(evq.pop_front());
  endfunction

  // ================================================================ run and reset events
  function void apply_event(accel_run_event e);
    if (e.kind == accel_run_event::EV_RESET) begin
      model_reset(e.cycle);
      return;
    end
    // EV_END
    if (!run_active) begin
      if (!run_unknown) `uvm_error("SB", $sformatf("@%0d a run ended that no START began", e.cycle))
      status_known = 0;
      return;
    end
    run_active = 0;
    n_runs_ended++;
    last_busy_cycles = e.busy_cycles;
    done = 1;
    if (run_outcome == RUN_UNKNOWN) begin
      status_known = 0;
      return;
    end
    error = run_outcome != RUN_OK;
    layer = 4'(run_layer);
    status_known = 1;
    if (e.error != error)
      `uvm_error("SB", $sformatf("@%0d run ended with ERROR=%0d, predicted %0d (%s at layer %0d)",
                                 e.cycle, e.error, error, run_outcome.name(), run_layer))
    foreach (layer_cyc_nz[l])
      layer_cyc_nz[l] =
          (l < run_layer || (l == run_layer && run_outcome inside {RUN_OK, ERR_NO_LAST})) ? 1 : 0;
    if (run_golden) begin
      for (int c = 0; c < N_CLASSES; c++) begin
        logit_known[c] = 1;
        logit[c] = refd.logit(run_ref, c);
      end
      result_known = 1;
      result = refd.pred[run_ref];
      n_golden_runs++;
    end else if (run_outcome != RUN_OK && !run_argmax_before_end) begin
      result_known = 1;  // cleared at START, never set by an ARGMAX
      result = 0;
    end
    if (result_known && e.result != result)
      `uvm_error("SB", $sformatf("@%0d run ended with RESULT=%0d, predicted %0d", e.cycle, e.result,
                                 result))
  endfunction

  function void model_reset(longint c);
    reset_seen = 1;
    cov.sample_event(run_active ? accel_coverage::E_RESET_DURING_RUN
                                : accel_coverage::E_RESET_IDLE);
    if (run_active || run_unknown) begin
      mem[SEL_ACT0].delete();  // a run cut short leaves ACT0 / ACT1 half written
      mem[SEL_ACT1].delete();
    end
    run_active = 0;
    run_unknown = 0;
    run_golden = 0;
    whi = 0;
    img_sel_known = 1;
    img_sel = 0;
    status_known = 1;
    done = 0;
    error = 0;
    layer = 0;
    result_known = 1;
    result = 0;
    foreach (logit[i]) begin
      logit_known[i] = 1;
      logit[i] = 0;
    end
    foreach (layer_cyc_nz[l]) layer_cyc_nz[l] = 0;
    counters_zero = 1;
    last_busy_cycles = -1;
    regs.reset();  // DESC has no reset value: its mirror is kept
    `uvm_info("SB", $sformatf("@%0d reset: CSRs and WHI back to their reset values", c), UVM_MEDIUM)
  endfunction

  // ================================================================ START
  // The descriptor table as the sequencer walks it (spec §9): the outcome, and the last layer
  // (RUN_OK) or the failing layer.
  function run_outcome_e predict_outcome(output int at_layer, output bit argmax_before_end);
    argmax_before_end = 0;
    for (int l = 0; l < DESC_DEPTH; l++) begin
      bit [31:0] w0;
      bit [2:0] op;
      bit [1:0] src, dst;
      at_layer = l;
      for (int k = 0; k < 4; k++) if (!desc_known[4*l+k]) return RUN_UNKNOWN;
      w0 = desc[4*l];
      op = w0[2:0];
      src = w0[9:8];
      dst = w0[13:12];
      if (op > 3) return ERR_RESERVED_OP;
      if (op inside {OP_CONV, OP_POOL} && dst inside {BUF_IMG, BUF_LOGIT})
        return ERR_DST_IMG_OR_LOGIT;
      if (op inside {OP_CONV, OP_POOL} && src == dst) return ERR_SRC_EQ_DST;
      if (op inside {OP_CONV, OP_POOL, OP_FC} && src == BUF_LOGIT) return ERR_SRC_LOGIT;
      if (op == OP_FC && dst != BUF_LOGIT) return ERR_FC_DST;
      if (op == OP_ARGMAX && src != BUF_LOGIT) return ERR_ARGMAX_SRC;
      if (op == OP_ARGMAX) argmax_before_end = 1;
      if (w0[5]) return RUN_OK;
    end
    at_layer = DESC_DEPTH - 1;
    return ERR_NO_LAST;
  endfunction

  function bit network_is_reference();
    foreach (desc[w]) if (!desc_known[w] || desc[w] != refd.desc[w]) return 0;
    for (int w = 0; w < BUF_DEPTH[SEL_WGT]; w++)
      if (!mem[SEL_WGT].exists(w) || mem[SEL_WGT][w] != refd.wgt[w]) return 0;
    for (int w = 0; w < BUF_DEPTH[SEL_PARAM]; w++)
      if (!mem[SEL_PARAM].exists(w) || mem[SEL_PARAM][w] != refd.param[w]) return 0;
    return 1;
  endfunction

  // The reference image held in slot `slot`, or -1.
  function int slot_image(int slot);
    int base = slot * IMG_SIZE;
    for (int i = 0; i < IMG_SIZE; i++) if (!mem[SEL_IMG].exists(base + i)) return -1;
    for (int k = 0; k < refd.n_images; k++) begin
      bit same = 1;
      for (int i = 0; i < IMG_SIZE && same; i++)
        if (mem[SEL_IMG][base+i][7:0] != refd.image_byte(k, i)) same = 0;
      if (same) return k;
    end
    return -1;
  endfunction

  function void start_run(axil_item t, longint s);
    n_starts++;
    if (!timeline.rose_in(s, t.resp_valid_cycle + 2))
      `uvm_error("SB", $sformatf("START written while idle, but BUSY did not rise: %s",
                                 t.convert2string()))
    run_active = 1;
    run_unknown = 0;
    done = 0;
    error = 0;
    status_known = 0;  // layer index changes during the run
    result_known = 1;
    result = 0;  // cleared at START; reads during the run see 0 until the ARGMAX completes
    foreach (logit_known[i]) logit_known[i] = 0;
    foreach (layer_cyc_nz[l]) layer_cyc_nz[l] = -1;
    counters_zero = 0;
    ctr_last = '{default: 0};
    mem[SEL_ACT0].delete();
    mem[SEL_ACT1].delete();
    run_outcome = img_sel_known ? predict_outcome(run_layer, run_argmax_before_end) : RUN_UNKNOWN;
    run_golden = 0;
    run_ref = -1;
    if (run_outcome == RUN_OK && network_is_reference()) begin
      run_ref = slot_image(img_sel);
      run_golden = run_ref >= 0;
    end
    if (run_argmax_before_end || run_outcome == RUN_UNKNOWN) result_known = 0;
    cov.sample_run(run_outcome, img_sel, run_golden);
    `uvm_info("SB", $sformatf("START @%0d: IMG_SEL %0d, %s at layer %0d%s", t.resp_valid_cycle,
                              img_sel, run_outcome.name(), run_layer,
                              run_golden ? $sformatf(", reference image %0d", run_ref) : ""),
              UVM_MEDIUM)
  endfunction

  function void run_state_unknown();
    run_active = 0;
    run_unknown = 1;
    status_known = 0;
    result_known = 0;
    foreach (logit_known[i]) logit_known[i] = 0;
    foreach (layer_cyc_nz[l]) layer_cyc_nz[l] = -1;
    counters_zero = 0;
    last_busy_cycles = -1;
    mem[SEL_ACT0].delete();
    mem[SEL_ACT1].delete();
  endfunction

  // ================================================================ transactions
  function void fail(axil_item t, string what);
    n_errors_seen++;
    `uvm_error("SB", $sformatf("%s: %s", what, t.convert2string()))
  endfunction

  function void check_read(axil_item t, bit known, bit [31:0] want, string what);
    if (!known) begin
      n_unchecked_reads++;
      return;
    end
    n_checked_reads++;
    if (t.data != want) fail(t, $sformatf("%s read %08h, predicted %08h", what, t.data, want));
  endfunction

  function void check_resp(axil_item t, bit [1:0] want);
    n_resp_checked++;
    if (t.resp != want) fail(t, $sformatf("response %0d, predicted %0d", t.resp, want));
  endfunction

  function void check_txn(axil_item t);
    longint s = t.accept_cycle() > last_resp_cycle ? t.accept_cycle() : last_resp_cycle;
    int cls = timeline.classify(s, t.resp_valid_cycle);
    bit busy_at_s = timeline.busy(s);
    bit is_buf = t.addr[22];
    bit is_hole = !t.addr[22] && t.addr[21:12] != 0;
    bit partial = t.kind == AXIL_WRITE && t.strb != 4'hF;
    longint latency = t.resp_valid_cycle - s;
    last_resp_cycle = t.resp_cycle;
    n_txn++;
    if (!reset_seen) begin
      fail(t, "transaction before the first reset");
      return;
    end
    cov.sample_access(t, busy_at_s, whi != 0);
    if (is_hole || partial) begin
      check_resp(t, is_hole ? AXIL_DECERR : AXIL_SLVERR);
      if (t.kind == AXIL_READ) check_read(t, 1, 0, "hole");
      if (latency > ACCESS_BOUND) fail(t, $sformatf("error response took %0d cycles", latency));
      return;
    end
    check_resp(t, AXIL_OKAY);
    if (!is_buf) begin
      if (latency > ACCESS_BOUND)
        fail(t, $sformatf("CSR access held %0d cycles (spec 13.4: never held for a run)", latency));
      if (t.kind == AXIL_WRITE) csr_write(t, cls, busy_at_s, s);
      else csr_read(t, cls, s);
    end else buf_access(t, busy_at_s, s, latency);
  endfunction

  // ---------------------------------------------------------------- CSR window
  function void csr_write(axil_item t, int cls, bit busy_at_s, longint s);
    bit [11:0] off = t.addr[11:0] & 12'hFFC;
    // 0 performed, 1 ignored (busy), 2 unknown
    int effect = !busy_at_s ? 0 : (timeline.fell_in(s, t.resp_valid_cycle) ? 2 : 1);
    case (csr_kind(off))
      R_CTRL: begin
        if (!t.data[0]) return;
        if (effect == 0) start_run(t, s);
        else if (effect == 2) begin
          n_ambiguous_starts++;
          run_state_unknown();
        end
        else cov.sample_event(accel_coverage::E_START_IGNORED_BUSY);
      end
      R_IMG_SEL: begin
        if (effect == 0) begin
          img_sel_known = 1;
          img_sel = t.data[3:0];
          void'(regs.img_sel.predict(t.data[3:0], .kind(UVM_PREDICT_WRITE)));
        end else if (effect == 2) img_sel_known = 0;
      end
      R_DESC: begin
        int w = (off - CSR_DESC) / 4;
        if (effect == 0) begin
          desc_known[w] = 1;
          desc[w] = t.data;
          void'(regs.desc[w].predict(t.data, .kind(UVM_PREDICT_WRITE)));
        end else if (effect == 2) desc_known[w] = 0;
      end
      default: ;  // read-only and unmapped offsets ignore writes
    endcase
  endfunction

  function void csr_read(axil_item t, int cls, longint s);
    bit [11:0] off = t.addr[11:0] & 12'hFFC;
    csr_e k = csr_kind(off);
    bit idle_settled = cls == 0 && !run_active;
    case (k)
      R_ID: check_read(t, 1, ID_VALUE, "ID");
      R_CONFIG: check_read(t, 1, CONFIG_VALUE, "CONFIG");
      R_CTRL: check_read(t, 1, 0, "CTRL");
      R_STATUS: begin
        if (t.data[31:12] != 0 || t.data[7:3] != 0) fail(t, "STATUS reserved bits set");
        if (cls == 1) begin
          n_checked_reads++;
          if (t.data[2:0] != 3'b001)
            fail(t, "STATUS during a run: BUSY=1, DONE=0, ERROR=0 expected");
        end else if (cls == 0 && status_known && !run_active)
          check_read(t, 1, {20'd0, layer, 5'd0, error, done, 1'b0}, "STATUS");
        else n_unchecked_reads++;
      end
      R_IMG_SEL: check_read(t, img_sel_known, {28'd0, img_sel}, "IMG_SEL");
      R_RESULT: check_read(t, result_known && cls != 2, {24'd0, result}, "RESULT");
      R_CYC_TOTAL, R_CYC_MAC, R_BUF_RD, R_BUF_WR: counter_read(t, k, cls);
      R_LAYER_CYC: begin
        int l = (off - CSR_LAYER_CYC) / 4;
        if (!idle_settled || layer_cyc_nz[l] < 0) n_unchecked_reads++;
        else begin
          n_checked_reads++;
          if ((t.data != 0) != (layer_cyc_nz[l] == 1))
            fail(t, $sformatf("LAYER_CYC[%0d] = %0d, predicted %s", l, t.data,
                              layer_cyc_nz[l] ? "nonzero (layer executed)" : "0 (not executed)"));
        end
      end
      R_LOGIT: begin
        int i = (off - CSR_LOGIT) / 4;
        check_read(t, logit_known[i] && cls != 2, logit[i], $sformatf("LOGIT[%0d]", i));
        if (logit_known[i] && cls != 2 && run_golden && i < N_CLASSES) n_logits_checked++;
      end
      R_DESC: begin
        int w = (off - CSR_DESC) / 4;
        check_read(t, desc_known[w], desc[w], $sformatf("DESC[%0d]", w));
      end
      default: check_read(t, 1, 0, "unmapped CSR offset");
    endcase
  endfunction

  // The counters (spec §10.2): 0 after reset, before any run; never decreasing during a run; after
  // a run, CYC_TOTAL within 2 of the number of cycles BUSY was high (a bound around "cycles from
  // START to DONE", which also covers the counters settling one cycle after DONE; not a latency).
  function void counter_read(axil_item t, csr_e k, int cls);
    int i = int'(k) - int'(R_CYC_TOTAL);
    if (counters_zero && cls == 0) begin
      check_read(t, 1, 0, "counter after reset");
      return;
    end
    if (cls == 1 && run_active) begin
      n_checked_reads++;
      if (t.data < ctr_last[i]) fail(t, $sformatf("counter decreased from %0d", ctr_last[i]));
      ctr_last[i] = t.data;
      return;
    end
    if (cls == 0 && !run_active && !run_unknown && last_busy_cycles >= 0 && k == R_CYC_TOTAL) begin
      n_checked_reads++;
      if (longint'(t.data) < last_busy_cycles - 2 || longint'(t.data) > last_busy_cycles + 2)
        fail(t, $sformatf("CYC_TOTAL %0d, but BUSY was high for %0d cycles", t.data,
                          last_busy_cycles));
      return;
    end
    n_unchecked_reads++;
  endfunction

  // ---------------------------------------------------------------- buffer window
  function void buf_access(axil_item t, bit busy_at_s, longint s, longint latency);
    int sel = int'(t.addr[21:19]);
    bit half = t.addr[2];
    bit mem_port = !(t.kind == AXIL_WRITE && half);
    if (mem_port && busy_at_s) begin
      if (!timeline.fell_in(s, t.resp_valid_cycle))
        fail(t, "buffer-window access arriving during a run completed before the run ended");
    end else if (latency > ACCESS_BOUND) begin
      fail(t, $sformatf("buffer-window access took %0d cycles while idle (or a WHI write)",
                        latency));
    end
    if (t.kind == AXIL_WRITE && half) begin
      whi = t.data;
      return;
    end
    if (t.kind == AXIL_WRITE) begin
      if (sel < N_BUFS) begin
        int w = int'(t.addr[18:3]) % BUF_DEPTH[sel];
        mem[sel][w] = sel <= SEL_ACT1 ? 64'(t.data[7:0]) : {whi, t.data};
      end
      whi = 0;
      return;
    end
    // read
    if (sel >= N_BUFS) check_read(t, 1, 0, "reserved buffer select");
    else if (sel <= SEL_ACT1 && half) check_read(t, 1, 0, "byte buffer, high half");
    else begin
      int w = int'(t.addr[18:3]) % BUF_DEPTH[sel];
      bit known = mem[sel].exists(w);
      bit [63:0] v = known ? mem[sel][w] : 0;
      check_read(t, known, half ? v[63:32] : v[31:0], $sformatf("buffer %0d word %0d", sel, w));
    end
  endfunction

  // ================================================================ end of test
  function void extract_phase(uvm_phase phase);
    process(1);
  endfunction

  function void check_phase(uvm_phase phase);
    if (n_rises < n_starts || n_rises > n_starts + n_ambiguous_starts)
      `uvm_error("SB", $sformatf("BUSY rose %0d times; model: %0d STARTs (+%0d unsure)",
                                 n_rises, n_starts, n_ambiguous_starts))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf({"%0d transactions, %0d responses checked; reads: %0d checked, ",
                               "%0d not predictable; runs: %0d started, %0d ended, %0d against ",
                               "the golden model (%0d logits compared); %0d mismatches"}, n_txn,
                              n_resp_checked, n_checked_reads, n_unchecked_reads, n_starts,
                              n_runs_ended, n_golden_runs, n_logits_checked, n_errors_seen),
              UVM_NONE)
  endfunction
endclass
