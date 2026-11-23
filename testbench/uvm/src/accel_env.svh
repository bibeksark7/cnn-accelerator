// accel_env: the AXI4-Lite agent on the accelerator's slave, the status monitor on accel_top's
// BUSY / DONE / ERROR / RESULT, the register model and the scoreboard with its coverage.
//
//   agent.mon --> scoreboard (axil_imp) <-- status monitor (run_imp, and the BUSY timeline)
//   regs.default_map --> agent.sqr (through accel_reg_adapter); mirror predicted by the scoreboard
class accel_env extends uvm_env;
  `uvm_component_utils(accel_env)
  axil_agent agent;
  axil_cfg agent_cfg;
  accel_status_monitor smon;
  accel_scoreboard sb;
  accel_regs regs;
  accel_reg_adapter adapter;
  accel_ref refd;
  accel_timeline timeline;
  accel_coverage cov;
  virtual axil_if vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "accel_env: no AXI4-Lite interface")
    if (!uvm_config_db#(axil_cfg)::get(this, "", "agent_cfg", agent_cfg))
      agent_cfg = axil_cfg::type_id::create("agent_cfg");
    uvm_config_db#(axil_cfg)::set(this, "agent", "cfg", agent_cfg);
    agent = axil_agent::type_id::create("agent", this);
    smon = accel_status_monitor::type_id::create("smon", this);
    sb = accel_scoreboard::type_id::create("sb", this);
    refd = accel_ref::type_id::create("refd");
    refd.load();
    timeline = accel_timeline::type_id::create("timeline");
    cov = accel_coverage::type_id::create("cov");
    regs = accel_regs::type_id::create("regs");
    regs.build();
    adapter = accel_reg_adapter::type_id::create("adapter");
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(sb.axil_imp);
    smon.ap.connect(sb.run_imp);
    smon.timeline = timeline;
    sb.timeline = timeline;
    sb.refd = refd;
    sb.regs = regs;
    sb.cov = cov;
    regs.default_map.set_sequencer(agent.sqr, adapter);
    regs.default_map.set_auto_predict(0);
    accel_base_seq::vif = vif;
  endfunction

  // Hang guard: a transaction in flight and none completed for HANG_CYCLES cycles. A buffer-window
  // access legitimately holds the slave until a run ends (about 47,000 cycles), so the bound is
  // far above one run; it only turns a hang into a failure instead of a wall-clock timeout.
  localparam int unsigned HANG_CYCLES = 400_000;
  task run_phase(uvm_phase phase);
    int unsigned last_done = 0, quiet = 0;
    forever begin
      repeat (1000) @(posedge vif.clk);
      if (agent.drv.idle() || agent.mon.n_done != last_done) quiet = 0;
      else quiet += 1000;
      last_done = agent.mon.n_done;
      if (quiet >= HANG_CYCLES)
        `uvm_fatal("HANG", $sformatf("no AXI transaction completed for %0d cycles", quiet))
    end
  endtask

  // Synchronous reset for `cycles` cycles. Only with the bus idle: AXI4-Lite has no way to cancel
  // a transaction, and the bench's model of one cut by reset would be a guess.
  task reset_dut(int unsigned cycles = 4);
    while (!agent.drv.idle()) @(posedge vif.clk);
    repeat (2) @(posedge vif.clk);
    vif.rst <= 1'b1;
    repeat (cycles) @(posedge vif.clk);
    vif.rst <= 1'b0;
    repeat (2) @(posedge vif.clk);
  endtask

  task wait_cycles(int unsigned n);
    repeat (n) @(posedge vif.clk);
  endtask
endclass
