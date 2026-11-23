// accel_timeline: BUSY as a function of the cycle, and the run and reset events, recorded by
// accel_status_monitor from accel_top's status outputs and queried by the scoreboard.
//
// The scoreboard classifies each AXI transaction by whether the accelerator was busy over the
// cycles in which the slave could have served it (see accel_scoreboard). `known_until` lets it
// wait until the timeline covers a transaction's cycles before classifying it; `updated` fires
// each time known_until advances (after that cycle's events are published).
class accel_run_event extends uvm_object;
  typedef enum {
    EV_START,
    EV_END,
    EV_RESET
  } kind_e;
  kind_e kind;
  longint cycle;
  bit error;  // EV_END: ERROR and RESULT as the run ended
  bit [7:0] result;
  longint busy_cycles;  // EV_END: cycles BUSY was high
  `uvm_object_utils(accel_run_event)
  function new(string name = "accel_run_event");
    super.new(name);
  endfunction
endclass

class accel_timeline extends uvm_object;
  `uvm_object_utils(accel_timeline)
  // BUSY changes: busy_val[i] holds from cycle busy_at[i] (inclusive) until the next change.
  longint busy_at[$];
  bit busy_val[$];
  longint reset_at[$];  // cycles in which rst was sampled high after being low
  longint known_until = -1;
  event updated;

  function new(string name = "accel_timeline");
    super.new(name);
    busy_at.push_back(0);
    busy_val.push_back(0);
  endfunction

  function bit busy(longint c);
    for (int i = busy_at.size() - 1; i >= 0; i--) if (busy_at[i] <= c) return busy_val[i];
    return 0;
  endfunction

  // 0: idle in every cycle of [c0, c1]; 1: busy in every cycle; 2: both.
  function int classify(longint c0, longint c1);
    bit b0 = busy(c0);
    foreach (busy_at[i]) if (busy_at[i] > c0 && busy_at[i] <= c1 && busy_val[i] != b0) return 2;
    return int'(b0);
  endfunction

  // A run ended (BUSY fell) in a cycle of (c0, c1].
  function bit fell_in(longint c0, longint c1);
    foreach (busy_at[i]) if (busy_at[i] > c0 && busy_at[i] <= c1 && !busy_val[i]) return 1;
    return 0;
  endfunction

  // A run started (BUSY rose) in a cycle of (c0, c1].
  function bit rose_in(longint c0, longint c1);
    foreach (busy_at[i]) if (busy_at[i] > c0 && busy_at[i] <= c1 && busy_val[i]) return 1;
    return 0;
  endfunction

  // Cycle of the last change before or at c.
  function longint last_change(longint c);
    for (int i = busy_at.size() - 1; i >= 0; i--) if (busy_at[i] <= c) return busy_at[i];
    return 0;
  endfunction
endclass

// accel_status_monitor: samples BUSY, DONE, ERROR and RESULT each cycle (accel_status_if),
// records BUSY into the timeline and publishes run starts, run ends and resets.
class accel_status_monitor extends uvm_monitor;
  `uvm_component_utils(accel_status_monitor)
  virtual accel_status_if vif;
  accel_timeline timeline;
  uvm_analysis_port #(accel_run_event) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual accel_status_if)::get(this, "", "status_vif", vif))
      `uvm_fatal("NOVIF", "accel_status_monitor: no status interface")
  endfunction

  task run_phase(uvm_phase phase);
    bit busy_q = 0, rst_q = 0;
    longint rose = 0;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.rst && !rst_q) begin
        accel_run_event e = accel_run_event::type_id::create("reset");
        e.kind  = accel_run_event::EV_RESET;
        e.cycle = vif.mon_cb.cycle;
        timeline.reset_at.push_back(e.cycle);
        ap.write(e);
      end
      rst_q = vif.mon_cb.rst;
      if (vif.mon_cb.busy != busy_q) begin
        accel_run_event e = accel_run_event::type_id::create("run");
        timeline.busy_at.push_back(vif.mon_cb.cycle);
        timeline.busy_val.push_back(vif.mon_cb.busy);
        e.cycle = vif.mon_cb.cycle;
        if (vif.mon_cb.busy) begin
          e.kind = accel_run_event::EV_START;
          rose   = e.cycle;
        end else if (!vif.mon_cb.rst &&
                     !(timeline.reset_at.size() > 0 && e.cycle - timeline.reset_at[$] <= 2)) begin
          e.kind = accel_run_event::EV_END;
          e.error = vif.mon_cb.error;
          e.result = vif.mon_cb.result;
          e.busy_cycles = e.cycle - rose;
          if (!vif.mon_cb.done) `uvm_error("STATUS", "BUSY fell without DONE (spec §9)")
        end else e.kind = accel_run_event::EV_RESET;  // a run aborted by reset
        busy_q = vif.mon_cb.busy;
        if (e.kind != accel_run_event::EV_RESET) ap.write(e);
      end
      timeline.known_until = vif.mon_cb.cycle;
      ->timeline.updated;
    end
  endtask
endclass
