// axil_pkg: a reusable UVM agent for one AXI4-Lite master interface (axil_if).
//
//   axil_item       one transaction: kind, address, data, strobes, response; the timing knobs the
//                   driver applies; the handshake cycles the monitor observed
//   axil_cfg        agent configuration: active/passive, outstanding limit, timing ranges, and a
//                   deliberate protocol violation (to prove the interface assertions fire)
//   axil_driver     pipelined master: writes and reads run in their own threads; AW and W start
//                   with independent delays; up to `max_outstanding` writes (and reads) are in
//                   flight; BREADY / RREADY are raised after a random delay or before VALID.
//                   The response goes back to the sequence through put_response (so a sequence
//                   calls get_response, and the register adapter sets provides_responses)
//   axil_monitor    rebuilds each transaction from the five channels (AW and W paired in order,
//                   B / R matched in order) and publishes it when its response is accepted, with
//                   the cycle of every handshake and the cycles each VALID waited for READY
//   axil_agent      sequencer + driver + monitor
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

  // Deliberate master-side protocol violations (axil_cfg.violation).
  typedef enum int {
    AXIL_NO_VIOLATION,
    AXIL_WITHDRAW_AW  // AWVALID dropped one cycle after it was raised if not yet accepted
  } axil_violation_e;

  // ------------------------------------------------------------------ transaction
  class axil_item extends uvm_sequence_item;
    rand axil_kind_e kind;
    rand bit [22:0] addr;
    rand bit [31:0] data;  // write data, or the read data the monitor / driver saw
    rand bit [3:0] strb;
    bit [1:0] resp;

    // Driver timing (cycles), set by the sequence (accel_base_seq::xfer).
    int unsigned aw_delay;  // before AWVALID (reads: before ARVALID)
    int unsigned w_delay;  // before WVALID
    int unsigned resp_delay;  // BREADY / RREADY this many cycles after VALID
    bit ready_early;  // BREADY / RREADY raised before VALID instead

    // Observed by the monitor (cycle stamps of axil_if.cycle at each handshake).
    longint aw_cycle, w_cycle, ar_cycle, resp_valid_cycle, resp_cycle;
    int unsigned aw_stall, w_stall, ar_stall, resp_stall;  // cycles VALID waited for READY

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
      do @(vif.drv_cb); while (!vif.drv_cb.wready);
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
        do @(vif.drv_cb); while (!vif.drv_cb.arready);
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
  class axil_monitor extends uvm_monitor;
    `uvm_component_utils(axil_monitor)
    virtual axil_if vif;
    uvm_analysis_port #(axil_item) ap;

    typedef struct {
      bit [22:0] addr;
      longint cycle;
      int unsigned stall;
    } addr_beat_t;
    typedef struct {
      bit [31:0] data;
      bit [3:0] strb;
      longint cycle;
      int unsigned stall;
    } data_beat_t;
    int unsigned n_done;  // transactions completed (the env's hang watchdog watches it)
    addr_beat_t aw_q[$], ar_q[$];
    data_beat_t w_q[$];
    int unsigned aw_stall, w_stall, ar_stall, b_stall, r_stall;
    longint b_first, r_first;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_monitor: no virtual interface")
    endfunction

    function void flush();
      aw_q.delete();
      ar_q.delete();
      w_q.delete();
      {aw_stall, w_stall, ar_stall, b_stall, r_stall} = '0;
      b_first = -1;
      r_first = -1;
    endfunction

    task run_phase(uvm_phase phase);
      longint c;
      flush();
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.rst) begin
          flush();
          continue;
        end
        c = vif.mon_cb.cycle;
        // Requests.
        if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin
          aw_q.push_back('{vif.mon_cb.awaddr, c, aw_stall});
          aw_stall = 0;
        end else if (vif.mon_cb.awvalid) aw_stall++;
        if (vif.mon_cb.wvalid && vif.mon_cb.wready) begin
          w_q.push_back('{vif.mon_cb.wdata, vif.mon_cb.wstrb, c, w_stall});
          w_stall = 0;
        end else if (vif.mon_cb.wvalid) w_stall++;
        if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin
          ar_q.push_back('{vif.mon_cb.araddr, c, ar_stall});
          ar_stall = 0;
        end else if (vif.mon_cb.arvalid) ar_stall++;
        // Responses.
        if (vif.mon_cb.bvalid && b_first < 0) b_first = c;
        if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
          axil_item t = axil_item::type_id::create("wr");
          if (aw_q.size() == 0 || w_q.size() == 0)
            `uvm_error("AXIL_MON", "write response without an accepted AW and W")
          else begin
            addr_beat_t a = aw_q.pop_front();
            data_beat_t w = w_q.pop_front();
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
            n_done++;
            ap.write(t);
          end
          b_first = -1;
          b_stall = 0;
        end else if (vif.mon_cb.bvalid) b_stall++;
        if (vif.mon_cb.rvalid && r_first < 0) r_first = c;
        if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
          axil_item t = axil_item::type_id::create("rd");
          if (ar_q.size() == 0) `uvm_error("AXIL_MON", "read response without an accepted AR")
          else begin
            addr_beat_t a = ar_q.pop_front();
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
            n_done++;
            ap.write(t);
          end
          r_first = -1;
          r_stall = 0;
        end else if (vif.mon_cb.rvalid) r_stall++;
      end
    endtask
  endclass

  // ------------------------------------------------------------------ agent
  typedef uvm_sequencer#(axil_item) axil_sequencer;

  class axil_agent extends uvm_agent;
    `uvm_component_utils(axil_agent)
    axil_cfg cfg;
    axil_sequencer sqr;
    axil_driver drv;
    axil_monitor mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg))
        cfg = axil_cfg::type_id::create("cfg");
      uvm_config_db#(axil_cfg)::set(this, "*", "cfg", cfg);
      mon = axil_monitor::type_id::create("mon", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        sqr = axil_sequencer::type_id::create("sqr", this);
        drv = axil_driver::type_id::create("drv", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (cfg.is_active == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass
endpackage
