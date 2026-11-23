// axil_pkg: a reusable UVM agent for one AXI4-Lite master interface (axil_if).
//
//   axil_item       one transaction: kind, address, data, strobes, response; the timing knobs the
//                   driver applies; what the monitor observed (handshake cycles, stalls, and the
//                   bus's concurrency when the transaction was accepted)
//   axil_cfg        agent configuration: active/passive, outstanding limit, coverage on/off, and
//                   a deliberate protocol violation (to prove the interface assertions fire)
//   axil_driver     pipelined master: writes and reads run in their own threads; AW and W start
//                   with independent delays; up to `max_outstanding` writes (and reads) are in
//                   flight; BREADY / RREADY are raised after a random delay or before VALID.
//                   The response goes back to the sequence through put_response (so a sequence
//                   calls get_response, and the register adapter sets provides_responses)
//   axil_monitor    rebuilds each transaction from the five channels (AW and W paired in order,
//                   B / R matched in order) and publishes it when its response is accepted, with
//                   the cycle of every handshake and the cycles each VALID waited for READY; also
//                   knows when the bus is idle (nothing presented and unanswered), so a passive
//                   agent needs no driver for that
//   axil_coverage   concurrency coverage (cg_outstanding) of the monitor's transactions
//   axil_agent      sequencer + driver (active only) + monitor (+ coverage)
//
// Latencies are never assumed: the driver waits for every handshake, the monitor only records.
package axil_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum bit {
    AXIL_READ,
    AXIL_WRITE
  } axil_kind_e;

  localparam bit [1:0] AXIL_OKAY = 2'b00, AXIL_EXOKAY = 2'b01, AXIL_SLVERR = 2'b10,
      AXIL_DECERR = 2'b11;

  // Deliberate master-side protocol violations (axil_cfg.violation): the channel's VALID dropped
  // one cycle after it was raised, if not yet accepted.
  typedef enum int {
    AXIL_NO_VIOLATION,
    AXIL_WITHDRAW_AW,
    AXIL_WITHDRAW_W,
    AXIL_WITHDRAW_AR
  } axil_violation_e;

  // ------------------------------------------------------------------ transaction
  // Not randomized as a whole: sequences set the fields procedurally (accel_base_seq::xfer; D-052).
  class axil_item extends uvm_sequence_item;
    axil_kind_e kind;
    bit [22:0] addr;
    bit [31:0] data;  // write data, or the read data the monitor / driver saw
    bit [3:0] strb;
    bit [1:0] resp;

    // Driver timing (cycles), set by the sequence (accel_base_seq::xfer).
    int unsigned aw_delay;  // before AWVALID (reads: before ARVALID)
    int unsigned w_delay;  // before WVALID
    int unsigned resp_delay;  // BREADY / RREADY this many cycles after VALID
    bit ready_early;  // BREADY / RREADY raised before VALID instead

    // Observed by the monitor (cycle stamps of axil_if.cycle at each handshake).
    longint aw_cycle, w_cycle, ar_cycle, resp_valid_cycle, resp_cycle;
    int unsigned aw_stall, w_stall, ar_stall, resp_stall;  // cycles VALID waited for READY
    // Observed by the monitor in the cycle the transaction was accepted (its last request channel):
    // writes and reads in flight (presented on the bus, response not yet accepted; this one
    // included), whether a transaction of the other direction was pending (accepted, response
    // not yet accepted), and, if its AW (or AR) was accepted in the same cycle as an AR (or AW),
    // whether this one was answered first.
    int unsigned wr_in_flight, rd_in_flight;
    bit other_pending, aw_ar_same_cycle, served_first;

    `uvm_object_utils(axil_item)

    function new(string name = "axil_item");
      super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
      axil_item t;
      super.do_copy(rhs);
      if (!$cast(t, rhs)) `uvm_fatal("AXIL", "do_copy: not an axil_item")
      kind = t.kind;
      addr = t.addr;
      data = t.data;
      strb = t.strb;
      resp = t.resp;
      aw_delay = t.aw_delay;
      w_delay = t.w_delay;
      resp_delay = t.resp_delay;
      ready_early = t.ready_early;
      aw_cycle = t.aw_cycle;
      w_cycle = t.w_cycle;
      ar_cycle = t.ar_cycle;
      resp_valid_cycle = t.resp_valid_cycle;
      resp_cycle = t.resp_cycle;
      aw_stall = t.aw_stall;
      w_stall = t.w_stall;
      ar_stall = t.ar_stall;
      resp_stall = t.resp_stall;
      wr_in_flight = t.wr_in_flight;
      rd_in_flight = t.rd_in_flight;
      other_pending = t.other_pending;
      aw_ar_same_cycle = t.aw_ar_same_cycle;
      served_first = t.served_first;
    endfunction

    // Cycle the transaction's last request channel was accepted (AW and W, or AR).
    function longint accept_cycle();
      if (kind == AXIL_WRITE) return aw_cycle > w_cycle ? aw_cycle : w_cycle;
      return ar_cycle;
    endfunction

    function string convert2string();
      return $sformatf(
          "%s %06h data %08h strb %b resp %0d (accepted @%0d, response valid @%0d, done @%0d)",
          kind == AXIL_WRITE ? "WR" : "RD",
          addr,
          data,
          strb,
          resp,
          accept_cycle(),
          resp_valid_cycle,
          resp_cycle
      );
    endfunction
  endclass

  // ------------------------------------------------------------------ configuration
  class axil_cfg extends uvm_object;
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    int unsigned max_outstanding = 2;  // per direction
    bit has_coverage = 1;
    axil_violation_e violation = AXIL_NO_VIOLATION;
    `uvm_object_utils(axil_cfg)
    function new(string name = "axil_cfg");
      super.new(name);
    endfunction
  endclass

  // ------------------------------------------------------------------ driver
  class axil_driver extends uvm_driver #(axil_item);
    `uvm_component_utils(axil_driver)
    virtual axil_if vif;
    axil_cfg cfg;
    mailbox #(axil_item) wr_mb = new(), rd_mb = new();  // from the sequencer, not yet issued
    mailbox #(axil_item) wr_pend = new(), rd_pend = new();  // issued, waiting for B / R
    semaphore wr_slots, rd_slots;  // max_outstanding per direction
    int unsigned wr_issuing, rd_issuing;  // items taken from the sequencer, not yet answered

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_driver: no virtual interface")
      if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg))
        cfg = axil_cfg::type_id::create("cfg");
    endfunction

    // True when no transaction is queued or in flight (tb_top's reset requires it).
    function bit idle();
      return wr_mb.num() == 0 && rd_mb.num() == 0 && wr_issuing == 0 && rd_issuing == 0;
    endfunction

    task run_phase(uvm_phase phase);
      wr_slots = new(cfg.max_outstanding);
      rd_slots = new(cfg.max_outstanding);
      vif.drv_cb.awvalid <= 1'b0;
      vif.drv_cb.wvalid  <= 1'b0;
      vif.drv_cb.arvalid <= 1'b0;
      vif.drv_cb.bready  <= 1'b0;
      vif.drv_cb.rready  <= 1'b0;
      fork
        get_items();
        write_issue();
        write_response();
        read_issue();
        read_response();
      join
    endtask

    task get_items();
      forever begin
        seq_item_port.get_next_item(req);
        if (req.kind == AXIL_WRITE) begin
          wr_issuing++;
          wr_mb.put(req);
        end else begin
          rd_issuing++;
          rd_mb.put(req);
        end
        seq_item_port.item_done();
      end
    endtask

    task automatic wait_out_reset();
      while (vif.drv_cb.rst) @(vif.drv_cb);
    endtask

    task write_issue();
      axil_item t;
      forever begin
        wr_mb.get(t);
        wr_slots.get();
        @(vif.drv_cb);
        wait_out_reset();
        fork
          drive_aw(t);
          drive_w(t);
        join
        wr_pend.put(t);
      end
    endtask

    task automatic drive_aw(axil_item t);
      repeat (t.aw_delay) @(vif.drv_cb);
      vif.drv_cb.awvalid <= 1'b1;
      vif.drv_cb.awaddr  <= t.addr;
      @(vif.drv_cb);
      if (cfg.violation == AXIL_WITHDRAW_AW && !vif.drv_cb.awready) begin
        `uvm_info("VIOLATION", "withdrawing AWVALID before AWREADY (deliberate)", UVM_LOW)
        vif.drv_cb.awvalid <= 1'b0;
        @(vif.drv_cb);
        vif.drv_cb.awvalid <= 1'b1;
        @(vif.drv_cb);
      end
      while (!vif.drv_cb.awready) @(vif.drv_cb);
      vif.drv_cb.awvalid <= 1'b0;
    endtask

    task automatic drive_w(axil_item t);
      repeat (t.w_delay) @(vif.drv_cb);
      vif.drv_cb.wvalid <= 1'b1;
      vif.drv_cb.wdata  <= t.data;
      vif.drv_cb.wstrb  <= t.strb;
      @(vif.drv_cb);
      if (cfg.violation == AXIL_WITHDRAW_W && !vif.drv_cb.wready) begin
        `uvm_info("VIOLATION", "withdrawing WVALID before WREADY (deliberate)", UVM_LOW)
        vif.drv_cb.wvalid <= 1'b0;
        @(vif.drv_cb);
        vif.drv_cb.wvalid <= 1'b1;
        @(vif.drv_cb);
      end
      while (!vif.drv_cb.wready) @(vif.drv_cb);
      vif.drv_cb.wvalid <= 1'b0;
    endtask

    task write_response();
      axil_item t, rsp;
      forever begin
        wr_pend.get(t);
        if (t.ready_early) vif.drv_cb.bready <= 1'b1;
        do @(vif.drv_cb); while (!vif.drv_cb.bvalid);
        if (!t.ready_early) begin
          repeat (t.resp_delay) @(vif.drv_cb);
          vif.drv_cb.bready <= 1'b1;
          @(vif.drv_cb);
        end
        t.resp = vif.drv_cb.bresp;
        vif.drv_cb.bready <= 1'b0;
        wr_slots.put();
        rsp = axil_item::type_id::create("rsp");
        rsp.copy(t);
        rsp.set_id_info(t);
        seq_item_port.put_response(rsp);
        wr_issuing--;
      end
    endtask

    task read_issue();
      axil_item t;
      forever begin
        rd_mb.get(t);
        rd_slots.get();
        @(vif.drv_cb);
        wait_out_reset();
        repeat (t.aw_delay) @(vif.drv_cb);
        vif.drv_cb.arvalid <= 1'b1;
        vif.drv_cb.araddr  <= t.addr;
        @(vif.drv_cb);
        if (cfg.violation == AXIL_WITHDRAW_AR && !vif.drv_cb.arready) begin
          `uvm_info("VIOLATION", "withdrawing ARVALID before ARREADY (deliberate)", UVM_LOW)
          vif.drv_cb.arvalid <= 1'b0;
          @(vif.drv_cb);
          vif.drv_cb.arvalid <= 1'b1;
          @(vif.drv_cb);
        end
        while (!vif.drv_cb.arready) @(vif.drv_cb);
        vif.drv_cb.arvalid <= 1'b0;
        rd_pend.put(t);
      end
    endtask

    task read_response();
      axil_item t, rsp;
      forever begin
        rd_pend.get(t);
        if (t.ready_early) vif.drv_cb.rready <= 1'b1;
        do @(vif.drv_cb); while (!vif.drv_cb.rvalid);
        if (!t.ready_early) begin
          repeat (t.resp_delay) @(vif.drv_cb);
          vif.drv_cb.rready <= 1'b1;
          @(vif.drv_cb);
        end
        t.resp = vif.drv_cb.rresp;
        t.data = vif.drv_cb.rdata;
        vif.drv_cb.rready <= 1'b0;
        rd_slots.put();
        rsp = axil_item::type_id::create("rsp");
        rsp.copy(t);
        rsp.set_id_info(t);
        seq_item_port.put_response(rsp);
        rd_issuing--;
      end
    endtask
  endclass

  // ------------------------------------------------------------------ monitor
  // Counts per channel (since the last reset): presentations (the first cycle of each VALID
  // period: VALID then stays high until READY, the interface assertions check that), handshakes,
  // and responses. A write is in flight from its first presented channel (AW or W) until its B
  // handshake, a read from ARVALID until its R handshake; a transaction is pending at the slave
  // from its first accepted request channel until its response handshake.
  class axil_monitor extends uvm_monitor;
    `uvm_component_utils(axil_monitor)
    virtual axil_if vif;
    uvm_analysis_port #(axil_item) ap;

    typedef struct {
      bit [22:0] addr;
      longint cycle;
      int unsigned stall;
      bit with_other;  // accepted in the same cycle as the other direction's address
    } addr_beat_t;
    typedef struct {
      bit [31:0] data;
      bit [3:0] strb;
      longint cycle;
      int unsigned stall;
    } data_beat_t;
    // The bus at the cycle a transaction was accepted (see axil_item).
    typedef struct {
      int unsigned wr_in_flight, rd_in_flight;
      bit other_pending;
    } accept_t;
    int unsigned n_done;  // transactions completed (the env's hang watchdog watches it)
    addr_beat_t aw_q[$], ar_q[$];
    data_beat_t w_q[$];
    accept_t wr_acc_q[$], rd_acc_q[$];
    int unsigned aw_stall, w_stall, ar_stall, b_stall, r_stall;
    longint b_first, r_first;
    int unsigned aw_arr, w_arr, ar_arr;  // presentations
    int unsigned aw_acc, w_acc, ar_acc, wr_acc;  // handshakes; writes with both AW and W accepted
    int unsigned b_n, r_n;  // response handshakes
    bit aw_wait, w_wait, ar_wait;  // VALID high and not accepted in the previous cycle
    bit pair_open, pair_answered;  // an AW / AR accepted together; one of the two answered

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_monitor: no virtual interface")
    endfunction

    function int unsigned wr_in_flight();
      return (aw_arr > w_arr ? aw_arr : w_arr) - b_n;
    endfunction

    function int unsigned wr_pending();
      return (aw_acc > w_acc ? aw_acc : w_acc) - b_n;
    endfunction

    // No transaction presented on the bus and unanswered (the env resets the DUT only then).
    function bit idle();
      return wr_in_flight() == 0 && ar_arr == r_n;
    endfunction

    function void flush();
      aw_q.delete();
      ar_q.delete();
      w_q.delete();
      wr_acc_q.delete();
      rd_acc_q.delete();
      {aw_stall, w_stall, ar_stall, b_stall, r_stall} = '0;
      b_first = -1;
      r_first = -1;
      {aw_arr, w_arr, ar_arr, aw_acc, w_acc, ar_acc, wr_acc, b_n, r_n} = '0;
      {aw_wait, w_wait, ar_wait, pair_open, pair_answered} = '0;
    endfunction

    // A response of a transaction whose address was accepted together with the other direction's:
    // the first of the two answered was served first.
    function bit answered_first(bit with_other);
      if (!with_other || !pair_open) return 0;
      if (pair_answered) begin
        pair_open = 0;
        return 0;
      end
      pair_answered = 1;
      return 1;
    endfunction

    task run_phase(uvm_phase phase);
      longint c;
      bit aw_hs, w_hs, ar_hs, b_hs, r_hs;
      flush();
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.rst) begin
          flush();
          continue;
        end
        c = vif.mon_cb.cycle;
        aw_hs = vif.mon_cb.awvalid && vif.mon_cb.awready;
        w_hs = vif.mon_cb.wvalid && vif.mon_cb.wready;
        ar_hs = vif.mon_cb.arvalid && vif.mon_cb.arready;
        b_hs = vif.mon_cb.bvalid && vif.mon_cb.bready;
        r_hs = vif.mon_cb.rvalid && vif.mon_cb.rready;
        // Presentations.
        if (vif.mon_cb.awvalid && !aw_wait) aw_arr++;
        if (vif.mon_cb.wvalid && !w_wait) w_arr++;
        if (vif.mon_cb.arvalid && !ar_wait) ar_arr++;
        aw_wait = vif.mon_cb.awvalid && !vif.mon_cb.awready;
        w_wait = vif.mon_cb.wvalid && !vif.mon_cb.wready;
        ar_wait = vif.mon_cb.arvalid && !vif.mon_cb.arready;
        // Requests.
        if (aw_hs) begin
          aw_q.push_back('{vif.mon_cb.awaddr, c, aw_stall, ar_hs});
          aw_stall = 0;
          aw_acc++;
        end else if (vif.mon_cb.awvalid) aw_stall++;
        if (w_hs) begin
          w_q.push_back('{vif.mon_cb.wdata, vif.mon_cb.wstrb, c, w_stall});
          w_stall = 0;
          w_acc++;
        end else if (vif.mon_cb.wvalid) w_stall++;
        if (ar_hs) begin
          ar_q.push_back('{vif.mon_cb.araddr, c, ar_stall, aw_hs});
          ar_stall = 0;
          ar_acc++;
        end else if (vif.mon_cb.arvalid) ar_stall++;
        if (aw_hs && ar_hs) begin
          pair_open = 1;
          pair_answered = 0;
        end
        // The bus as each transaction is accepted (responses of this cycle counted as done).
        while (wr_acc < aw_acc && wr_acc < w_acc) begin
          wr_acc++;
          wr_acc_q.push_back('{wr_in_flight() - int'(b_hs), ar_arr - r_n - int'(r_hs),
                               ar_acc - r_n - int'(r_hs) > 0});
        end
        if (ar_hs)
          rd_acc_q.push_back('{wr_in_flight() - int'(b_hs), ar_arr - r_n - int'(r_hs),
                               wr_pending() - int'(b_hs) > 0});
        // Responses.
        if (vif.mon_cb.bvalid && b_first < 0) b_first = c;
        if (b_hs) begin
          axil_item t = axil_item::type_id::create("wr");
          b_n++;
          if (aw_q.size() == 0 || w_q.size() == 0 || wr_acc_q.size() == 0)
            `uvm_error("AXIL_MON", "write response without an accepted AW and W")
          else begin
            addr_beat_t a = aw_q.pop_front();
            data_beat_t w = w_q.pop_front();
            accept_t x = wr_acc_q.pop_front();
            t.kind = AXIL_WRITE;
            t.addr = a.addr;
            t.data = w.data;
            t.strb = w.strb;
            t.resp = vif.mon_cb.bresp;
            t.aw_cycle = a.cycle;
            t.aw_stall = a.stall;
            t.w_cycle = w.cycle;
            t.w_stall = w.stall;
            t.resp_valid_cycle = b_first;
            t.resp_cycle = c;
            t.resp_stall = b_stall;
            t.wr_in_flight = x.wr_in_flight;
            t.rd_in_flight = x.rd_in_flight;
            t.other_pending = x.other_pending;
            t.aw_ar_same_cycle = a.with_other;
            t.served_first = answered_first(a.with_other);
            n_done++;
            ap.write(t);
          end
          b_first = -1;
          b_stall = 0;
        end else if (vif.mon_cb.bvalid) b_stall++;
        if (vif.mon_cb.rvalid && r_first < 0) r_first = c;
        if (r_hs) begin
          axil_item t = axil_item::type_id::create("rd");
          r_n++;
          if (ar_q.size() == 0 || rd_acc_q.size() == 0)
            `uvm_error("AXIL_MON", "read response without an accepted AR")
          else begin
            addr_beat_t a = ar_q.pop_front();
            accept_t x = rd_acc_q.pop_front();
            t.kind = AXIL_READ;
            t.addr = a.addr;
            t.data = vif.mon_cb.rdata;
            t.strb = 4'hF;
            t.resp = vif.mon_cb.rresp;
            t.ar_cycle = a.cycle;
            t.ar_stall = a.stall;
            t.resp_valid_cycle = r_first;
            t.resp_cycle = c;
            t.resp_stall = r_stall;
            t.wr_in_flight = x.wr_in_flight;
            t.rd_in_flight = x.rd_in_flight;
            t.other_pending = x.other_pending;
            t.aw_ar_same_cycle = a.with_other;
            t.served_first = answered_first(a.with_other);
            n_done++;
            ap.write(t);
          end
          r_first = -1;
          r_stall = 0;
        end else if (vif.mon_cb.rvalid) r_stall++;
      end
    endtask
  endclass

  // ------------------------------------------------------------------ coverage
  // Concurrency on the bus, from the monitor's transactions (sampled as each response is accepted,
  // with the values observed when the transaction was accepted):
  //   cp_wr_depth / cp_rd_depth  writes / reads in flight at each accept (0, 1, 2; the agent's
  //                              driver keeps at most two per direction): 2 means one answered
  //                              by the slave later and one more already presented behind it
  //   x_kind_other               each direction accepted with the other direction pending or not
  //                              (a read accepted while a write is pending, and the reverse)
  //   cp_same_cycle_first        AW and AR accepted in the same cycle, by which was answered first
  class axil_coverage extends uvm_subscriber #(axil_item);
    `uvm_component_utils(axil_coverage)
    axil_kind_e kind;
    int unsigned wr_depth, rd_depth;
    bit other_pending, pair_first;

    covergroup cg_outstanding;
      cp_wr_depth: coverpoint wr_depth {bins d0 = {0}; bins d1 = {1}; bins d2 = {2};}
      cp_rd_depth: coverpoint rd_depth {bins d0 = {0}; bins d1 = {1}; bins d2 = {2};}
      cp_kind: coverpoint kind;
      cp_other_pending: coverpoint other_pending;
      x_kind_other: cross cp_kind, cp_other_pending;
      cp_same_cycle_first: coverpoint kind iff (pair_first) {
        bins write_first = {AXIL_WRITE};
        bins read_first = {AXIL_READ};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_outstanding = new;
    endfunction

    function void write(axil_item t);
      kind = t.kind;
      wr_depth = t.wr_in_flight;
      rd_depth = t.rd_in_flight;
      other_pending = t.other_pending;
      pair_first = t.aw_ar_same_cycle && t.served_first;
      cg_outstanding.sample();
    endfunction
  endclass

  // ------------------------------------------------------------------ agent
  typedef uvm_sequencer#(axil_item) axil_sequencer;

  class axil_agent extends uvm_agent;
    `uvm_component_utils(axil_agent)
    axil_cfg cfg;
    axil_sequencer sqr;
    axil_driver drv;
    axil_monitor mon;
    axil_coverage cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg))
        cfg = axil_cfg::type_id::create("cfg");
      uvm_config_db#(axil_cfg)::set(this, "*", "cfg", cfg);
      mon = axil_monitor::type_id::create("mon", this);
      if (cfg.has_coverage) cov = axil_coverage::type_id::create("cov", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        sqr = axil_sequencer::type_id::create("sqr", this);
        drv = axil_driver::type_id::create("drv", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (cfg.has_coverage) mon.ap.connect(cov.analysis_export);
      if (cfg.is_active == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction

    // Nothing on the bus (the monitor's view) and, if active, nothing queued in the driver.
    function bit idle();
      return mon.idle() && (cfg.is_active == UVM_PASSIVE || drv.idle());
    endfunction
  endclass
endpackage
