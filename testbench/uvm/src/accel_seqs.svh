// accel_seqs: sequences for the accelerator's AXI4-Lite slave.
//
// Every sequence reaches the bus through accel_base_seq's write / read, which randomize the
// transaction's timing (AW / W skew, response-ready delay, ready before valid) within the
// sequence's knobs and wait for the driver's response. Per-transaction randomization is
// procedural ($urandom_range, seeded by +verilator+seed): Verilator solves randomize() with
// constraints in an external SMT solver, about 3 ms per call (D-052), too slow for tens of
// thousands of transactions. Constrained randomize() is used where the constraint is the point
// (accel_desc_err_item). Several sequences may run in parallel on
// the one sequencer (the driver keeps writes and reads in flight together).
//
// Checking is the scoreboard's job; sequences only use responses for control flow (polling
// STATUS) and to stop early on a broken response.
class accel_base_seq extends uvm_sequence #(axil_item);
  `uvm_object_utils(accel_base_seq)
  accel_ref refd;
  int unsigned max_delay = 3;  // AW / W / AR start delay and response-ready delay, cycles
  int unsigned early_pct = 30;  // chance of raising BREADY / RREADY before VALID
  int unsigned min_resp_delay = 0;  // > 0: BREADY / RREADY held off at least this long
  static virtual axil_if vif;  // set by accel_env, for waits that must not hold the driver
  int unsigned guard = 2_000_000;  // polls before a run counts as hung (not an expected value)

  function new(string name = "accel_base_seq");
    super.new(name);
  endfunction

  function void configure(accel_base_seq parent);
    refd = parent.refd;
    max_delay = parent.max_delay;
    early_pct = parent.early_pct;
    min_resp_delay = parent.min_resp_delay;
  endfunction

  task xfer(axil_kind_e kind, bit [22:0] addr, bit [31:0] data, bit [3:0] strb,
            output axil_item rsp);
    axil_item t = axil_item::type_id::create("t");
    uvm_sequence_item r;
    start_item(t);
    t.kind = kind;
    t.addr = addr;
    t.data = data;
    t.strb = strb;
    t.aw_delay = $urandom_range(0, max_delay);
    t.w_delay = $urandom_range(0, max_delay);
    t.resp_delay = $urandom_range(min_resp_delay, max_delay > min_resp_delay ? max_delay
                                                                               : min_resp_delay);
    t.ready_early = min_resp_delay == 0 && $urandom_range(0, 99) < early_pct;
    finish_item(t);
    get_base_response(r, t.get_transaction_id());
    if (!$cast(rsp, r)) `uvm_fatal("SEQ", "response is not an axil_item")
  endtask

  // Idle cycles in this sequence only (other sequences' transactions keep flowing).
  task wait_cycles(int unsigned n);
    repeat (n) @(posedge vif.clk);
  endtask

  task write(bit [22:0] addr, bit [31:0] data, bit [3:0] strb = 4'hF);
    axil_item rsp;
    xfer(AXIL_WRITE, addr, data, strb, rsp);
  endtask

  task read(bit [22:0] addr, output bit [31:0] data);
    axil_item rsp;
    xfer(AXIL_READ, addr, 0, 4'hF, rsp);
    data = rsp.data;
  endtask

  task csr_write(bit [11:0] off, bit [31:0] data);
    write(23'(off), data);
  endtask

  task csr_read(bit [11:0] off, output bit [31:0] data);
    read(23'(off), data);
  endtask

  // One 64-bit word of WGT or PARAM: high half (WHI), then low half (spec §13.4).
  task wide_write(int sel, int word, bit [63:0] v);
    write(buf_addr(sel, word, 1), v[63:32]);
    write(buf_addr(sel, word, 0), v[31:0]);
  endtask

  // One byte-buffer word: the bits above [7:0] are ignored, so they are random.
  task byte_write(int sel, int word, bit [7:0] v);
    write(buf_addr(sel, word, 0) | 23'($urandom_range(0, 3)), {24'($urandom), v});
  endtask
endclass

// Single accesses, for tests that interleave bus traffic with resets and waits.
class accel_write_seq extends accel_base_seq;
  `uvm_object_utils(accel_write_seq)
  bit [22:0] addr;
  bit [31:0] data;
  function new(string name = "accel_write_seq");
    super.new(name);
  endfunction
  task body();
    write(addr, data);
  endtask
endclass

class accel_read_seq extends accel_base_seq;
  `uvm_object_utils(accel_read_seq)
  bit [22:0] addr;
  bit [31:0] data;
  function new(string name = "accel_read_seq");
    super.new(name);
  endfunction
  task body();
    read(addr, data);
  endtask
endclass

// IMG_SEL and START only: the run is left going.
class accel_start_seq extends accel_base_seq;
  `uvm_object_utils(accel_start_seq)
  int slot;
  function new(string name = "accel_start_seq");
    super.new(name);
  endfunction
  task body();
    csr_write(CSR_IMG_SEL, slot);
    csr_write(CSR_CTRL, 1);
  endtask
endclass

// The reference network: every WGT and PARAM word through the buffer window, the descriptor table
// through the CSR window.
class accel_load_net_seq extends accel_base_seq;
  `uvm_object_utils(accel_load_net_seq)
  function new(string name = "accel_load_net_seq");
    super.new(name);
  endfunction
  task body();
    foreach (refd.wgt[w]) wide_write(SEL_WGT, w, refd.wgt[w]);
    foreach (refd.param[w]) wide_write(SEL_PARAM, w, refd.param[w]);
    foreach (refd.desc[w]) csr_write(CSR_DESC + 12'(4 * w), refd.desc[w]);
  endtask
endclass

// Reference image `image` into IMG slot `slot`.
class accel_load_image_seq extends accel_base_seq;
  `uvm_object_utils(accel_load_image_seq)
  int image, slot;
  function new(string name = "accel_load_image_seq");
    super.new(name);
  endfunction
  task body();
    for (int i = 0; i < IMG_SIZE; i++)
      byte_write(SEL_IMG, slot * IMG_SIZE + i, refd.image_byte(image, i));
  endtask
endclass

// One run on slot `slot`: IMG_SEL, START, poll STATUS until DONE, then read the results and the
// counters (the scoreboard checks them).
class accel_run_seq extends accel_base_seq;
  `uvm_object_utils(accel_run_seq)
  int slot;
  int unsigned poll_gap = 255;  // up to this many idle cycles between STATUS polls
  bit [31:0] status;
  function new(string name = "accel_run_seq");
    super.new(name);
  endfunction
  task body();
    bit [31:0] v;
    csr_write(CSR_IMG_SEL, slot);
    csr_write(CSR_CTRL, 1);
    for (int n = 0;; n++) begin
      if (n > 0) wait_cycles($urandom_range(0, poll_gap));
      csr_read(CSR_STATUS, status);
      if (!(status & STATUS_BUSY) && (status & STATUS_DONE)) break;
      if (n == guard) `uvm_fatal("SEQ", "run never finished (DONE never set)")
    end
    for (int i = 0; i < LOGIT_DEPTH; i++) csr_read(CSR_LOGIT + 12'(4 * i), v);
    csr_read(CSR_RESULT, v);
    csr_read(CSR_IMG_SEL, v);
    for (int l = 0; l < DESC_DEPTH; l++) csr_read(CSR_LAYER_CYC + 12'(4 * l), v);
    csr_read(CSR_CYC_TOTAL, v);
    csr_read(CSR_CYC_MAC, v);
    csr_read(CSR_BUF_RD, v);
    csr_read(CSR_BUF_WR, v);
    csr_read(CSR_STATUS, v);
  endtask
endclass

// Random accesses to every CSR offset (mapped ones weighted up): reads of anything; writes to the
// read-only and unmapped offsets (ignored), to IMG_SEL, and to DESC words (a random value, read
// back, then the original value restored). No CTRL writes (they start runs).
class accel_csr_rand_seq extends accel_base_seq;
  `uvm_object_utils(accel_csr_rand_seq)
  int unsigned n = 500;
  bit allow_writes = 1;
  function new(string name = "accel_csr_rand_seq");
    super.new(name);
  endfunction
  task body();
    bit [31:0] v;
    repeat (n) begin
      bit [11:0] off;
      randcase
        6: off = 12'(4 * $urandom_range(0, 11));  // ID .. BUF_WR (and the holes between)
        2: off = CSR_LAYER_CYC + 12'(4 * $urandom_range(0, DESC_DEPTH - 1));
        3: off = CSR_LOGIT + 12'(4 * $urandom_range(0, LOGIT_DEPTH - 1));
        3: off = CSR_DESC + 12'(4 * $urandom_range(0, DESC_WORDS - 1));
        2: off = 12'($urandom_range(0, 12'hFFF));  // anywhere, unmapped offsets included
      endcase
      off = off | 12'($urandom_range(0, 3));  // address bits [1:0] are ignored
      if (!allow_writes || $urandom_range(0, 1)) csr_read(off, v);
      else begin
        csr_e k = csr_kind(off);
        if (k == R_CTRL) csr_read(off, v);
        else if (k == R_DESC) begin
          int w = ((off & 12'hFFC) - CSR_DESC) / 4;
          csr_write(off, $urandom);
          csr_read(off, v);
          csr_write(off, refd.desc[w]);
        end else csr_write(off, $urandom);
      end
    end
  endtask
endclass

// Random buffer-window accesses: every select (reserved ones too), both halves, word addresses
// past the depth, ignored address bits, partial strobes. WGT and PARAM words written are put back
// at the end (later runs use the network); IMG slots written are not (reload before use).
class accel_buf_rand_seq extends accel_base_seq;
  `uvm_object_utils(accel_buf_rand_seq)
  int unsigned n = 1000;
  function new(string name = "accel_buf_rand_seq");
    super.new(name);
  endfunction
  task body();
    bit [31:0] v;
    int touched_wgt[$], touched_prm[$];
    repeat (n) begin
      int sel = $urandom_range(0, 7);
      int depth = sel < N_BUFS ? BUF_DEPTH[sel] : 1024;
      int word;
      bit half = $urandom_range(0, 1);
      bit [22:0] a;
      randcase
        6: word = $urandom_range(0, depth - 1);
        1: word = depth - 1;
        1: word = $urandom_range(depth, 16'hFFFF);  // wraps (bits above the depth ignored)
      endcase
      a = buf_addr(sel, word, half) | 23'($urandom_range(0, 3));
      randcase
        5: read(a, v);
        4: begin
          write(a, $urandom);
          if (!half && sel == SEL_WGT) touched_wgt.push_back(word % depth);
          if (!half && sel == SEL_PARAM) touched_prm.push_back(word % depth);
        end
        1: write(a, $urandom, 4'($urandom_range(0, 14)));  // partial: SLVERR, not performed
      endcase
    end
    write(buf_addr(7, 0, 0), 0);  // clears WHI (a reserved select: no buffer written)
    foreach (touched_wgt[i]) wide_write(SEL_WGT, touched_wgt[i], refd.wgt[touched_wgt[i]]);
    foreach (touched_prm[i]) wide_write(SEL_PARAM, touched_prm[i], refd.param[touched_prm[i]]);
  endtask
endclass

// Random addresses anywhere in the 8 MB region, most of them in the DECERR hole between the CSR
// and buffer windows; random strobes. Reads and error responses only change nothing, so this
// runs in parallel with anything; writes outside the hole are partial (SLVERR, not performed).
class accel_err_rand_seq extends accel_base_seq;
  `uvm_object_utils(accel_err_rand_seq)
  int unsigned n = 500;
  function new(string name = "accel_err_rand_seq");
    super.new(name);
  endfunction
  task body();
    bit [31:0] v;
    repeat (n) begin
      bit [22:0] a;
      randcase
        4: a = 23'($urandom_range(23'h1000, 23'h3F_FFFF));  // the hole
        1: a = 23'($urandom_range(23'h1000, 23'h1FFF));  // just above the CSR window
        1: a = 23'($urandom_range(23'h3F_F000, 23'h3F_FFFF));  // just below the buffer window
        1: a = 23'($urandom);  // anywhere
      endcase
      if ($urandom_range(0, 1)) read(a, v);
      else if (!a[22] && a[21:12] != 0) write(a, $urandom, 4'($urandom_range(0, 15)));
      else write(a, $urandom, 4'($urandom_range(0, 14)));
    end
  endtask
endclass

// While a run is in progress (started by someone else). First `n_free` accesses the slave must
// answer at once even during a run (spec §13.4): register reads of every kind, IMG_SEL and START
// writes (ignored while busy), DESC writes of the value already there, WHI writes. Then a few
// buffer-window reads and low-half writes, which are held until the run ends (and hold every
// access behind them: the slave serves one at a time), and polling until DONE has been seen
// three times. Starts once STATUS shows BUSY; the last access is a low-half write to a reserved
// select, which clears WHI.
class accel_poll_seq extends accel_base_seq;
  `uvm_object_utils(accel_poll_seq)
  int slot;  // the slot being run (IMG_SEL writes keep it)
  int unsigned n_free = 1000;
  // The first held access, which alone reaches the slave while busy (the rest wait behind it):
  // 0 a buffer read, 1 a low-half write to ACT0 / ACT1, 2 a low-half write to a reserved select.
  int unsigned first_held = 0;
  function new(string name = "accel_poll_seq");
    super.new(name);
  endfunction

  task free_access(output bit [31:0] status, output bit saw_status);
    bit [31:0] v;
    saw_status = 0;
    randcase
      8: begin
        csr_read(CSR_STATUS, status);
        saw_status = 1;
      end
      4: csr_read(12'(4 * $urandom_range(0, 11)), v);
      2: csr_read(CSR_LOGIT + 12'(4 * $urandom_range(0, LOGIT_DEPTH - 1)), v);
      2: csr_read(CSR_LAYER_CYC + 12'(4 * $urandom_range(0, DESC_DEPTH - 1)), v);
      2: csr_read(CSR_DESC + 12'(4 * $urandom_range(0, DESC_WORDS - 1)), v);
      1: csr_write(CSR_IMG_SEL, slot);
      1: csr_write(CSR_CTRL, 1);  // ignored while busy
      1: begin
        int w = $urandom_range(0, DESC_WORDS - 1);
        csr_write(CSR_DESC + 12'(4 * w), refd.desc[w]);
      end
      1: write(buf_addr($urandom_range(0, 7), $urandom_range(0, 1023), 1), $urandom);  // WHI
    endcase
  endtask

  task body();
    bit [31:0] v, status;
    bit saw;
    int after_done = 0;
    for (int n = 0;; n++) begin
      csr_read(CSR_STATUS, status);
      if (status & STATUS_BUSY) break;
      if (n == guard) `uvm_fatal("SEQ", "the run never started (BUSY never seen)")
    end
    // Register traffic only while the run is surely still going (the run lasts far longer).
    for (int n = 0; n < n_free; n++) begin
      free_access(status, saw);
      if (saw && !(status & STATUS_BUSY)) break;  // ended early (an error run)
    end
    // Held accesses: reads of any buffer, low-half writes to ACT0 / ACT1 (a run overwrites them
    // anyway) and to reserved selects.
    for (int i = 0; i < 3; i++) begin
      case (i == 0 ? first_held : $urandom_range(0, 2))
        0: read(buf_addr($urandom_range(0, 7), $urandom_range(0, 1023), $urandom_range(0, 1)), v);
        1: write(buf_addr($urandom_range(SEL_ACT0, SEL_ACT1), $urandom_range(0, 8191), 0),
                 $urandom);
        default: write(buf_addr($urandom_range(5, 7), $urandom_range(0, 1023), 0), $urandom);
      endcase
    end
    for (int n = 0; after_done < 3; n++) begin
      csr_read(CSR_STATUS, status);
      if (status & STATUS_DONE) after_done++;
      if (n == guard) `uvm_fatal("SEQ", "run never finished (DONE never seen)")
    end
    write(buf_addr(7, 0, 0), 0);
  endtask
endclass

// A random invalid descriptor (spec §9): one layer of the reference table replaced by a word 0
// whose op, src and dst break at least one of the rules the sequencer checks before starting a
// layer. The constraint states the rules positively (`legal`) and requires their negation; the
// scoreboard predicts the outcome with its own, procedural, checker.
class accel_desc_err_item extends uvm_object;
  `uvm_object_utils(accel_desc_err_item)
  rand int unsigned layer;
  rand bit [2:0] op;
  rand bit [1:0] src, dst;
  rand bit last;
  bit legal;

  constraint c_layer {layer < 6;}
  constraint c_illegal {
    !(op <= 3 &&
      ((op == OP_CONV || op == OP_POOL) -> (dst inside {BUF_ACT0, BUF_ACT1} && src != dst &&
                                            src != BUF_LOGIT)) &&
      (op == OP_FC -> (dst == BUF_LOGIT && src != BUF_LOGIT)) &&
      (op == OP_ARGMAX -> src == BUF_LOGIT));
  }
  // Spread over the rules, not just reserved ops (half of all op values).
  constraint c_spread {op dist {[0 : 3] := 3, [4 : 7] := 1};}

  function new(string name = "accel_desc_err_item");
    super.new(name);
  endfunction
endclass

// Each §9 descriptor error, one run each: the reference table with one or two descriptors
// changed, then the original words restored. The scoreboard predicts the outcome from the table.
class accel_desc_error_seq extends accel_base_seq;
  `uvm_object_utils(accel_desc_error_seq)
  int slot;
  int unsigned n_random = 12;  // constrained-random invalid descriptors after the directed ones
  function new(string name = "accel_desc_error_seq");
    super.new(name);
  endfunction

  function bit [31:0] w0(int l, int op, int src, int dst, bit last);
    bit [31:0] v = refd.desc[4*l];
    v[2:0] = 3'(op);
    v[5] = last;
    v[9:8] = 2'(src);
    v[13:12] = 2'(dst);
    return v;
  endfunction

  task run_with(int l[$], bit [31:0] words[$]);
    accel_run_seq r = accel_run_seq::type_id::create("r");
    foreach (l[i]) csr_write(CSR_DESC + 12'(4 * l[i]), words[i]);
    r.configure(this);
    r.slot = slot;
    r.start(m_sequencer, this);
    foreach (l[i]) csr_write(CSR_DESC + 12'(4 * l[i]), refd.desc[l[i]]);
  endtask

  task body();
    // Word 0 of descriptor L is DESC word 4L (spec §8 has the reference table).
    // First: no descriptor with last = 1 (ARGMAX at layers 5, 6 and 7, none last). Its ARGMAXes
    // set RESULT, so the error runs after it show that START clears RESULT.
    run_with('{4 * 5, 4 * 6, 4 * 6 + 1, 4 * 6 + 2, 4 * 7, 4 * 7 + 1, 4 * 7 + 2},
             '{w0(5, OP_ARGMAX, BUF_LOGIT, BUF_LOGIT, 0), w0(5, OP_ARGMAX, BUF_LOGIT, BUF_LOGIT, 0),
               refd.desc[21], refd.desc[22], w0(5, OP_ARGMAX, BUF_LOGIT, BUF_LOGIT, 0),
               refd.desc[21], refd.desc[22]});
    run_with('{4 * 2}, '{w0(2, 5, BUF_ACT1, BUF_ACT0, 0)});  // reserved op
    run_with('{4 * 0}, '{w0(0, OP_CONV, BUF_IMG, BUF_IMG, 0)});  // CONV dst = IMG
    run_with('{4 * 1}, '{w0(1, OP_POOL, BUF_ACT0, BUF_LOGIT, 0)});  // POOL dst = LOGIT
    run_with('{4 * 1}, '{w0(1, OP_POOL, BUF_ACT0, BUF_ACT0, 0)});  // POOL src = dst
    run_with('{4 * 4}, '{w0(4, OP_FC, BUF_LOGIT, BUF_LOGIT, 0)});  // FC src = LOGIT
    run_with('{4 * 4}, '{w0(4, OP_FC, BUF_ACT1, BUF_ACT0, 0)});  // FC dst != LOGIT
    run_with('{4 * 5}, '{w0(5, OP_ARGMAX, BUF_ACT1, BUF_LOGIT, 1)});  // ARGMAX src != LOGIT
    // Constrained-random invalid descriptors.
    repeat (n_random) begin
      accel_desc_err_item e = accel_desc_err_item::type_id::create("desc_err");
      if (!e.randomize()) `uvm_fatal("SEQ", "accel_desc_err_item: randomize failed")
      `uvm_info("SEQ", $sformatf("invalid descriptor: layer %0d op %0d src %0d dst %0d last %0d",
                                 e.layer, e.op, e.src, e.dst, e.last), UVM_MEDIUM)
      run_with('{4 * e.layer}, '{w0(e.layer, e.op, e.src, e.dst, e.last)});
    end
  endtask
endclass
