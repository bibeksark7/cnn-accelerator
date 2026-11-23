// accel_regs: UVM register model of the CSR map (spec §10.2), at offset 0 of the accelerator's
// region, plus the adapter between register operations and axil_item, and a backdoor for the
// registers with storage the bench can reach (IMG_SEL and the descriptor table).
//
// The mirror is predicted by accel_scoreboard (explicit prediction, auto-predict off): only the
// scoreboard knows whether a write was performed (IMG_SEL and DESC writes are ignored while
// busy) and what a run changed. Registers whose value only the scoreboard can predict (STATUS,
// RESULT, the counters, LAYER_CYC, LOGIT) have compare off: the scoreboard checks every read of
// them against its own model, busy-aware; the register sequences check the rest (ID, CONFIG,
// IMG_SEL, DESC) against the mirror as well.
//
// The mirror is predicted when the monitor publishes the response, in the same time step as the
// driver hands the response back, so it is current when write() returns (BUG-023).
typedef class accel_scoreboard;

class accel_reg extends uvm_reg;
  `uvm_object_utils(accel_reg)
  rand uvm_reg_field value;  // single-field registers

  function new(string name = "accel_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  // A field at `lsb`. `checked` = 0 turns compare off (the scoreboard checks it).
  function uvm_reg_field add_field(string name, int unsigned width, int unsigned lsb,
                                   string access, uvm_reg_data_t reset, bit has_reset,
                                   bit is_volatile, bit checked);
    uvm_reg_field f = uvm_reg_field::type_id::create(name);
    f.configure(this, width, lsb, access, is_volatile, reset, has_reset, 1, 0);
    if (!checked) f.set_compare(UVM_NO_CHECK);
    return f;
  endfunction

  // One field at bit 0.
  function void build_field(int unsigned width, string access, uvm_reg_data_t reset,
                            bit has_reset, bit is_volatile, bit checked);
    value = add_field("value", width, 0, access, reset, has_reset, is_volatile, checked);
  endfunction
endclass

// STATUS (spec §10.2): BUSY [0], DONE [1], ERROR [2], LAYER [11:8]. Every field changes with runs,
// so none is compared against the mirror: the scoreboard checks STATUS reads, busy-aware.
class accel_status_reg extends accel_reg;
  `uvm_object_utils(accel_status_reg)
  rand uvm_reg_field busy, done, error, layer;
  function new(string name = "accel_status_reg");
    super.new(name);
  endfunction
  function void build();
    busy = add_field("BUSY", 1, 0, "RO", 0, 1, 1, 0);
    done = add_field("DONE", 1, 1, "RO", 0, 1, 1, 0);
    error = add_field("ERROR", 1, 2, "RO", 0, 1, 1, 0);
    layer = add_field("LAYER", 4, 8, "RO", 0, 1, 1, 0);
  endfunction
endclass

// CTRL (spec §10.2): START [0], write-only, reads 0.
class accel_ctrl_reg extends accel_reg;
  `uvm_object_utils(accel_ctrl_reg)
  rand uvm_reg_field start;
  function new(string name = "accel_ctrl_reg");
    super.new(name);
  endfunction
  function void build();
    start = add_field("START", 1, 0, "WO", 0, 1, 0, 0);
  endfunction
endclass

// Backdoor for IMG_SEL or one DESC word, through accel_backdoor_if (hierarchical references into
// accel_top: IMG_SEL's register in csr_block, the descriptor table's RAM). A backdoor write
// changes the design without a bus transaction, so it also updates the scoreboard's model (the
// register model's mirror is updated by uvm_reg itself). Used only while the accelerator is idle.
class accel_reg_backdoor extends uvm_reg_backdoor;
  `uvm_object_utils(accel_reg_backdoor)
  virtual accel_backdoor_if bif;
  accel_scoreboard sb;
  int word;  // DESC word, or -1 for IMG_SEL

  function new(string name = "accel_reg_backdoor");
    super.new(name);
  endfunction

  virtual function void read_func(uvm_reg_item rw);
    rw.set_value(word < 0 ? uvm_reg_data_t'(bif.read_img_sel()) : bif.read_desc(word), 0);
    rw.set_status(UVM_IS_OK);
  endfunction

  virtual task write(uvm_reg_item rw);
    bit [31:0] v = 32'(rw.get_value(0));
    if (word < 0) bif.write_img_sel(v[3:0]);
    else bif.write_desc(word, v);
    sb.backdoor_write(word, v);
    rw.set_status(UVM_IS_OK);
  endtask
endclass

typedef accel_reg accel_reg_q_t[$];

class accel_regs extends uvm_reg_block;
  `uvm_object_utils(accel_regs)
  accel_reg id, config_r, img_sel, result, cyc_total, cyc_mac, buf_rd, buf_wr;
  accel_ctrl_reg ctrl;
  accel_status_reg status;
  accel_reg layer_cyc[DESC_DEPTH];
  accel_reg logit[LOGIT_DEPTH];
  accel_reg desc[DESC_WORDS];

  function new(string name = "accel_regs");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  local function accel_reg add(string name, bit [11:0] offset, string rights, int unsigned width,
                               string access, uvm_reg_data_t reset, bit has_reset,
                               bit is_volatile, bit checked);
    accel_reg r = accel_reg::type_id::create(name);
    r.configure(this);
    r.build_field(width, access, reset, has_reset, is_volatile, checked);
    default_map.add_reg(r, offset, rights);
    return r;
  endfunction

  function void build();
    default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN);
    id = add("ID", CSR_ID, "RO", 32, "RO", ID_VALUE, 1, 0, 1);
    config_r = add("CONFIG", CSR_CONFIG, "RO", 32, "RO", CONFIG_VALUE, 1, 0, 1);
    // CTRL is write-only and reads 0; writing START has a side effect, so the generic register
    // sequences skip it (NO_REG_TESTS below).
    ctrl = accel_ctrl_reg::type_id::create("CTRL");
    ctrl.configure(this);
    ctrl.build();
    default_map.add_reg(ctrl, CSR_CTRL, "RW");
    status = accel_status_reg::type_id::create("STATUS");
    status.configure(this);
    status.build();
    default_map.add_reg(status, CSR_STATUS, "RO");
    img_sel = add("IMG_SEL", CSR_IMG_SEL, "RW", 4, "RW", 0, 1, 0, 1);
    result = add("RESULT", CSR_RESULT, "RO", 8, "RO", 0, 1, 1, 0);
    cyc_total = add("CYC_TOTAL", CSR_CYC_TOTAL, "RO", 32, "RO", 0, 1, 1, 0);
    cyc_mac = add("CYC_MAC", CSR_CYC_MAC, "RO", 32, "RO", 0, 1, 1, 0);
    buf_rd = add("BUF_RD", CSR_BUF_RD, "RO", 32, "RO", 0, 1, 1, 0);
    buf_wr = add("BUF_WR", CSR_BUF_WR, "RO", 32, "RO", 0, 1, 1, 0);
    foreach (layer_cyc[l])
      layer_cyc[l] = add($sformatf("LAYER_CYC%0d", l), CSR_LAYER_CYC + 12'(4 * l), "RO", 32,
                         "RO", 0, 1, 1, 0);
    foreach (logit[i])
      logit[i] = add($sformatf("LOGIT%0d", i), CSR_LOGIT + 12'(4 * i), "RO", 32, "RO", 0, 1, 1, 0);
    // DESC is not reset (spec §10.2): no reset value, so the reset sequence skips it.
    foreach (desc[w]) desc[w] = add($sformatf("DESC%0d", w), CSR_DESC + 12'(4 * w), "RW", 32, "RW",
                                    0, 0, 0, 1);
    uvm_resource_db#(bit)::set({"REG::", ctrl.get_full_name()}, "NO_REG_TESTS", 1, this);
    // uvm_reg_access_seq (frontdoor against backdoor) covers only the registers with a backdoor.
    begin
      accel_reg_q_t regs = all_regs();
      foreach (regs[i])
        if (regs[i] != img_sel && !is_desc(regs[i]))
          uvm_resource_db#(bit)::set({"REG::", regs[i].get_full_name()}, "NO_REG_ACCESS_TEST", 1,
                                     this);
    end
    lock_model();
  endfunction

  function bit is_desc(uvm_reg r);
    foreach (desc[w]) if (r == desc[w]) return 1;
    return 0;
  endfunction

  function accel_reg_q_t all_regs();
    accel_reg_q_t q = '{id, config_r, ctrl, status, img_sel, result, cyc_total, cyc_mac, buf_rd,
                        buf_wr};
    foreach (layer_cyc[l]) q.push_back(layer_cyc[l]);
    foreach (logit[i]) q.push_back(logit[i]);
    foreach (desc[w]) q.push_back(desc[w]);
    return q;
  endfunction

  // Backdoors for IMG_SEL and every DESC word (the env calls this once the scoreboard exists).
  function void set_backdoors(virtual accel_backdoor_if bif, accel_scoreboard sb);
    accel_reg_backdoor b = accel_reg_backdoor::type_id::create("img_sel_backdoor");
    b.bif = bif;
    b.sb = sb;
    b.word = -1;
    img_sel.set_backdoor(b);
    foreach (desc[w]) begin
      b = accel_reg_backdoor::type_id::create($sformatf("desc%0d_backdoor", w));
      b.bif = bif;
      b.sb = sb;
      b.word = w;
      desc[w].set_backdoor(b);
    end
  endfunction
endclass

// Register operation <-> AXI4-Lite transaction, with random timing up to max_delay cycles;
// provides_responses: the driver returns a response item.
class accel_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(accel_reg_adapter)
  int unsigned max_delay = 3;

  function new(string name = "accel_reg_adapter");
    super.new(name);
    provides_responses = 1;
    supports_byte_enable = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    axil_item t = axil_item::type_id::create("reg_item");
    t.kind = rw.kind == UVM_WRITE ? AXIL_WRITE : AXIL_READ;
    t.addr = 23'(rw.addr);
    t.data = 32'(rw.data);
    t.strb = 4'hF;
    t.aw_delay = $urandom_range(0, max_delay);
    t.w_delay = $urandom_range(0, max_delay);
    t.resp_delay = $urandom_range(0, max_delay);
    t.ready_early = $urandom_range(0, 1);
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    axil_item t;
    if (!$cast(t, bus_item)) `uvm_fatal("RAL", "bus2reg: not an axil_item")
    rw.kind   = t.kind == AXIL_WRITE ? UVM_WRITE : UVM_READ;
    rw.addr   = t.addr;
    rw.data   = t.data;
    rw.status = t.resp == AXIL_OKAY ? UVM_IS_OK : UVM_NOT_OK;
  endfunction
endclass
