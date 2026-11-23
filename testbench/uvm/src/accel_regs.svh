// accel_regs: UVM register model of the CSR map (spec §10.2), at offset 0 of the accelerator's
// region, plus the adapter between register operations and axil_item.
//
// The mirror is predicted by accel_scoreboard (explicit prediction, auto-predict off): only the
// scoreboard knows whether a write was performed (IMG_SEL and DESC writes are ignored while
// busy) and what a run changed. Registers whose value only the scoreboard can predict (STATUS,
// RESULT, the counters, LAYER_CYC, LOGIT) have compare off: the scoreboard checks every read of
// them against its own model, busy-aware; the register sequences check the rest (ID, CONFIG,
// IMG_SEL, DESC) against the mirror as well.
class accel_reg extends uvm_reg;
  `uvm_object_utils(accel_reg)
  rand uvm_reg_field value;

  function new(string name = "accel_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  // One field at bit 0. `checked` = 0 turns compare off (the scoreboard checks it).
  function void build_field(int unsigned width, string access, uvm_reg_data_t reset,
                            bit has_reset, bit is_volatile, bit checked);
    value = uvm_reg_field::type_id::create("value");
    value.configure(this, width, 0, access, is_volatile, reset, has_reset, 1, 0);
    if (!checked) value.set_compare(UVM_NO_CHECK);
  endfunction
endclass

class accel_regs extends uvm_reg_block;
  `uvm_object_utils(accel_regs)
  accel_reg id, config_r, ctrl, status, img_sel, result, cyc_total, cyc_mac, buf_rd, buf_wr;
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
    ctrl = add("CTRL", CSR_CTRL, "RW", 1, "WO", 0, 1, 0, 0);
    status = add("STATUS", CSR_STATUS, "RO", 12, "RO", 0, 1, 1, 0);
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
    lock_model();
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
