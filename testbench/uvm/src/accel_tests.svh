// accel_tests: the UVM tests (select with +UVM_TESTNAME). Each starts with a reset and ends by
// printing "TEST PASSED" only if no UVM_ERROR, UVM_FATAL or UVM_WARNING was reported, the
// scoreboard saw no mismatch, and the test's own minimums were met (so a test that checked
// nothing cannot pass).
//
//   accel_reg_test       register model: reset values, bit-bash and frontdoor-against-backdoor
//                        access (uvm_reg_access_seq) of IMG_SEL and every DESC word, random CSR
//                        traffic with partial-strobe writes, then a second reset (DESC kept, the
//                        rest reset)
//   accel_bus_test       random buffer-window, CSR-window and error-address traffic in parallel,
//                        two transactions in flight per direction, random timing
//   accel_infer_test     the network uploaded through the bus, then every reference image (the
//                        quick subset and the saturating images) run back to back, slots reused
//   accel_poll_test      runs with a second sequence polling and poking the slave throughout
//   accel_error_test     each §9 descriptor error, then a correct run again. The env's agent is
//                        passive here (a separate active agent is the bus master), then a reset
//                        requested while a read is in flight must wait for its response
//   accel_reset_test     reset in the middle of a run and while idle; WHI, CSRs, buffers after it
//   accel_random_test    runs, uploads, random reads and error traffic all at once, extreme timing
//   accel_violation_test the driver breaks the AXI4-Lite rules on purpose (+VIOLATION=AW, W or AR:
//                        that channel's VALID withdrawn before READY): the interface assertion
//                        must stop the simulation (the pytest entry expects this test to fail
//                        through that channel's valid_ready_sva a_valid_held)
class accel_base_test extends uvm_test;
  `uvm_component_utils(accel_base_test)
  accel_env env;
  axil_cfg agent_cfg;
  // Set by a subclass's new(): the env's agent only monitors, and `master`, an active agent outside
  // the env on the same interface, drives the bus. The register model has no frontdoor then.
  bit passive_env = 0;
  axil_agent master;
  int unsigned min_golden_runs = 0, min_checked_reads = 1, min_runs = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    agent_cfg = axil_cfg::type_id::create("agent_cfg");
    configure_agent(agent_cfg);
    if (passive_env) begin
      axil_cfg master_cfg = axil_cfg::type_id::create("master_cfg");
      configure_agent(master_cfg);
      master_cfg.has_coverage = 0;  // the env's agent has it
      agent_cfg.is_active = UVM_PASSIVE;
      uvm_config_db#(axil_cfg)::set(this, "master", "cfg", master_cfg);
      master = axil_agent::type_id::create("master", this);
    end
    uvm_config_db#(axil_cfg)::set(this, "env", "agent_cfg", agent_cfg);
    env = accel_env::type_id::create("env", this);
  endfunction

  virtual function void configure_agent(axil_cfg cfg);
  endfunction

  // The sequencer of whichever agent drives the bus.
  function axil_sequencer sqr();
    return passive_env ? master.sqr : env.agent.sqr;
  endfunction

  function accel_base_seq seq_cfg(accel_base_seq s, int unsigned max_delay = 3,
                                  int unsigned early_pct = 30);
    s.refd = env.refd;
    s.max_delay = max_delay;
    s.early_pct = early_pct;
    return s;
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    env.reset_dut();
    body();
    env.wait_cycles(10);
    phase.drop_objection(this);
  endtask

  virtual task body();
  endtask

  // Helpers used by several tests.
  task load_net(int unsigned max_delay = 3);
    accel_load_net_seq s = accel_load_net_seq::type_id::create("load_net");
    void'(seq_cfg(s, max_delay));
    s.start(sqr());
  endtask

  task load_image(int image, int slot, int unsigned max_delay = 3);
    accel_load_image_seq s = accel_load_image_seq::type_id::create("load_image");
    void'(seq_cfg(s, max_delay));
    s.image = image;
    s.slot = slot;
    s.start(sqr());
  endtask

  task run_slot(int slot, int unsigned max_delay = 3);
    accel_run_seq s = accel_run_seq::type_id::create("run");
    void'(seq_cfg(s, max_delay));
    s.slot = slot;
    s.start(sqr());
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    int errors = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
    int warnings = rs.get_severity_count(UVM_WARNING);
    string why = "";
    if (errors != 0) why = $sformatf("%0d UVM errors", errors);
    else if (warnings != 0) why = $sformatf("%0d UVM warnings", warnings);
    else if (env.sb.n_errors_seen != 0) why = "scoreboard mismatches";
    else if (env.sb.n_golden_runs < min_golden_runs)
      why = $sformatf("%0d golden-checked runs, need %0d", env.sb.n_golden_runs, min_golden_runs);
    else if (env.sb.n_runs_ended < min_runs)
      why = $sformatf("%0d runs, need %0d", env.sb.n_runs_ended, min_runs);
    else if (env.sb.n_checked_reads < min_checked_reads)
      why = $sformatf("%0d checked reads, need %0d", env.sb.n_checked_reads, min_checked_reads);
    if (why == "") `uvm_info("RESULT", $sformatf("TEST PASSED: %s", get_type_name()), UVM_NONE)
    else `uvm_info("RESULT", $sformatf("TEST FAILED: %s: %s", get_type_name(), why), UVM_NONE)
  endfunction
endclass

class accel_reg_test extends accel_base_test;
  `uvm_component_utils(accel_reg_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_checked_reads = 500;
  endfunction
  task body();
    uvm_reg_hw_reset_seq rst_seq = uvm_reg_hw_reset_seq::type_id::create("hw_reset");
    uvm_reg_single_bit_bash_seq bash = uvm_reg_single_bit_bash_seq::type_id::create("bit_bash");
    uvm_reg_access_seq access = uvm_reg_access_seq::type_id::create("access");
    accel_csr_rand_seq csr = accel_csr_rand_seq::type_id::create("csr_rand");
    uvm_status_e st;
    uvm_reg_data_t v;
    rst_seq.model = env.regs;
    rst_seq.start(null);
    bash.rg = env.regs.img_sel;
    bash.start(null);
    foreach (env.regs.desc[w]) begin
      bash.rg = env.regs.desc[w];
      bash.start(null);
    end
    // Frontdoor write, backdoor check; backdoor write, frontdoor check (IMG_SEL and DESC: the
    // registers with a backdoor; the others are marked NO_REG_ACCESS_TEST in accel_regs).
    access.model = env.regs;
    access.start(null);
    // Leave the reference table in DESC (the random sequence restores what it changes).
    foreach (env.regs.desc[w]) env.regs.desc[w].write(st, env.refd.desc[w]);
    void'(seq_cfg(csr));
    csr.n = 1500;
    csr.start(sqr());
    env.regs.img_sel.write(st, 9);
    env.reset_dut(3);
    rst_seq.start(null);  // IMG_SEL back to 0
    foreach (env.regs.desc[w]) begin  // DESC kept across reset
      env.regs.desc[w].mirror(st, UVM_CHECK);
    end
    csr.allow_writes = 0;
    csr.n = 300;
    csr.start(sqr());
  endtask
endclass

class accel_bus_test extends accel_base_test;
  `uvm_component_utils(accel_bus_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_checked_reads = 1000;
  endfunction
  function void configure_agent(axil_cfg cfg);
    cfg.max_outstanding = 2;
  endfunction
  task body();
    accel_buf_rand_seq b = accel_buf_rand_seq::type_id::create("buf_rand");
    accel_csr_rand_seq c = accel_csr_rand_seq::type_id::create("csr_rand");
    accel_err_rand_seq e = accel_err_rand_seq::type_id::create("err_rand");
    load_net();  // so the DESC writes have the reference values to restore
    void'(seq_cfg(b, 6, 40));
    void'(seq_cfg(c, 6, 40));
    void'(seq_cfg(e, 6, 40));
    b.n = 3000;
    c.n = 1000;
    e.n = 1500;  // no runs here, so CSR writes (IMG_SEL, DESC with restore) are safe in parallel
    fork
      b.start(sqr());
      c.start(sqr());
      e.start(sqr());
    join
  endtask
endclass

class accel_infer_test extends accel_base_test;
  `uvm_component_utils(accel_infer_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  task body();
    min_golden_runs = env.refd.n_images + 1;
    load_net();
    for (int k = 0; k < env.refd.n_images; k++) begin
      load_image(k, k % IMG_SLOTS, k % 4);
      run_slot(k % IMG_SLOTS, k % 4);
    end
    run_slot((env.refd.n_images - 1) % IMG_SLOTS);  // the same slot again, no reload
  endtask
endclass

class accel_poll_test extends accel_base_test;
  `uvm_component_utils(accel_poll_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_golden_runs = 3;
    min_runs = 4;
    min_checked_reads = 2000;
  endfunction
  function void configure_agent(axil_cfg cfg);
    cfg.max_outstanding = 2;
  endfunction
  task body();
    load_net();
    for (int k = 0; k < 4; k++) begin
      accel_run_seq r = accel_run_seq::type_id::create("run");
      accel_poll_seq p = accel_poll_seq::type_id::create("poll");
      load_image(k, 15 - k);
      void'(seq_cfg(r, 2));
      void'(seq_cfg(p, 4, 50));
      r.slot = 15 - k;
      p.slot = 15 - k;
      p.first_held = k % 3;
      fork
        r.start(sqr());
        begin
          env.wait_cycles(20);
          p.start(sqr());
        end
      join
    end
  endtask
endclass

class accel_error_test extends accel_base_test;
  `uvm_component_utils(accel_error_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_runs = 10 + 12;
    min_golden_runs = 2;
    passive_env = 1;
  endfunction

  // A reset requested while a read is in flight, its response held off by the master: reset_dut
  // must wait for it. The env's agent has no driver, so only its monitor can tell.
  task reset_during_read();
    accel_read_seq rd = accel_read_seq::type_id::create("slow_read");
    bit done = 0;
    if (env.agent.drv != null || env.agent.sqr != null)
      `uvm_error("TEST", "the env's agent is not passive")
    void'(seq_cfg(rd, 0, 0));
    rd.min_resp_delay = 40;
    rd.addr = 23'(CSR_ID);
    fork
      begin
        rd.start(sqr());
        done = 1;
      end
      begin
        while (env.agent.idle()) env.wait_cycles(1);
        env.reset_dut();
        if (!done) `uvm_fatal("TEST", "reset_dut did not wait for the read in flight")
      end
    join
  endtask

  task body();
    accel_desc_error_seq e = accel_desc_error_seq::type_id::create("desc_errors");
    load_net();
    load_image(0, 6);  // class 7: the runs after the first show RESULT cleared by START
    void'(seq_cfg(e));
    e.slot = 6;
    e.start(sqr());
    run_slot(6);  // the restored table runs correctly
    reset_during_read();
    run_slot(6);  // and again after the reset (buffers and DESC kept)
  endtask
endclass

class accel_reset_test extends accel_base_test;
  `uvm_component_utils(accel_reset_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_golden_runs = 2;
    min_runs = 1;
  endfunction

  task write(bit [22:0] addr, bit [31:0] data);
    accel_write_seq s = accel_write_seq::type_id::create("write");
    void'(seq_cfg(s));
    s.addr = addr;
    s.data = data;
    s.start(sqr());
  endtask

  task read(bit [22:0] addr);
    accel_read_seq s = accel_read_seq::type_id::create("read");
    void'(seq_cfg(s));
    s.addr = addr;
    s.start(sqr());
  endtask

  task body();
    uvm_reg_hw_reset_seq rst_seq = uvm_reg_hw_reset_seq::type_id::create("hw_reset");
    accel_csr_rand_seq csr = accel_csr_rand_seq::type_id::create("csr_rand");
    int unsigned reset_at[4] = '{50, 3000, 20000, 45000};  // cycles into the run
    void'(seq_cfg(csr));
    rst_seq.model = env.regs;
    load_net();
    load_image(7, 2);
    run_slot(2);
    // Reset in the middle of runs, at several points; every CSR is checked afterwards.
    foreach (reset_at[i]) begin
      accel_start_seq st = accel_start_seq::type_id::create("start");
      void'(seq_cfg(st));
      st.slot = 2;
      st.start(sqr());
      env.wait_cycles(reset_at[i]);
      env.reset_dut($urandom_range(1, 6));
      rst_seq.start(null);
      csr.allow_writes = 0;
      csr.n = 80;
      csr.start(sqr());
    end
    // A reset while idle, then WHI: cleared by reset (a high-half write, reset, a low-half write
    // stores {0, low}).
    write(buf_addr(SEL_PARAM, 40, 1), 32'hDEAD_BEEF);
    env.reset_dut();
    write(buf_addr(SEL_PARAM, 40, 0), 32'h1234_5678);
    read(buf_addr(SEL_PARAM, 40, 1));
    read(buf_addr(SEL_PARAM, 40, 0));
    write(buf_addr(SEL_PARAM, 40, 1), env.refd.param[40][63:32]);
    write(buf_addr(SEL_PARAM, 40, 0), env.refd.param[40][31:0]);
    // Buffers and the descriptor table survive reset: the same image runs correctly again.
    run_slot(2);
  endtask
endclass

class accel_random_test extends accel_base_test;
  `uvm_component_utils(accel_random_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    min_golden_runs = 6;
    min_checked_reads = 3000;
  endfunction
  function void configure_agent(axil_cfg cfg);
    cfg.max_outstanding = 2;
  endfunction
  task body();
    bit stop = 0;
    load_net(8);
    fork
      begin  // foreground: uploads and runs, random slots and images
        for (int i = 0; i < 6; i++) begin
          int k = $urandom_range(0, env.refd.n_images - 1);
          int slot = $urandom_range(0, IMG_SLOTS - 1);
          load_image(k, slot, $urandom_range(0, 8));
          run_slot(slot, $urandom_range(0, 8));
        end
        stop = 1;
      end
      begin  // background: reads of everything and error traffic (they change nothing)
        while (!stop) begin
          accel_csr_rand_seq c = accel_csr_rand_seq::type_id::create("csr_reads");
          accel_err_rand_seq e = accel_err_rand_seq::type_id::create("errors");
          void'(seq_cfg(c, 8, 50));
          void'(seq_cfg(e, 8, 50));
          c.allow_writes = 0;
          c.n = 200;
          e.n = 100;
          fork
            c.start(sqr());
            e.start(sqr());
          join
        end
      end
    join
  endtask
endclass

class accel_violation_test extends accel_base_test;
  `uvm_component_utils(accel_violation_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void configure_agent(axil_cfg cfg);
    string which = "AW";
    void'($value$plusargs("VIOLATION=%s", which));
    cfg.max_outstanding = 2;
    case (which)
      "AW": cfg.violation = AXIL_WITHDRAW_AW;
      "W": cfg.violation = AXIL_WITHDRAW_W;
      "AR": cfg.violation = AXIL_WITHDRAW_AR;
      default: `uvm_fatal("TEST", {"+VIOLATION must be AW, W or AR, not ", which})
    endcase
  endfunction
  task body();
    // Two writes (or reads) back to back with a slow BREADY (RREADY) on the first: the second's
    // AW and W (AR) wait, since the slave's buffers stay full until the first response is
    // accepted, and the driver withdraws the chosen VALID.
    if (agent_cfg.violation == AXIL_WITHDRAW_AR) begin
      accel_read_seq slow = accel_read_seq::type_id::create("slow_r");
      accel_read_seq next = accel_read_seq::type_id::create("next");
      void'(seq_cfg(slow, 0, 0));
      void'(seq_cfg(next, 0, 0));
      slow.min_resp_delay = 10;
      slow.addr = buf_addr(7, 0, 0);
      next.addr = buf_addr(7, 1, 0);
      fork
        slow.start(sqr());
        begin
          env.wait_cycles(1);
          next.start(sqr());
        end
      join
    end else begin
      accel_write_seq slow = accel_write_seq::type_id::create("slow_b");
      accel_write_seq next = accel_write_seq::type_id::create("next");
      void'(seq_cfg(slow, 0, 0));
      void'(seq_cfg(next, 0, 0));
      slow.min_resp_delay = 10;
      slow.addr = buf_addr(7, 0, 0);
      next.addr = buf_addr(7, 1, 0);
      fork
        slow.start(sqr());
        begin
          env.wait_cycles(1);
          next.start(sqr());
        end
      join
    end
  endtask
endclass
