// accel_backdoor_if: the register model's backdoor (accel_reg_backdoor) into the design under
// test, by hierarchical reference: IMG_SEL's register in csr_block and the descriptor table's RAM.
// The bench uses it only while the accelerator is idle and the bus quiet (uvm_reg_access_seq in
// accel_reg_test). A write here takes effect at once, like a deposit; the design's own logic
// keeps the value until it next writes the register or RAM word.
interface accel_backdoor_if;
  function automatic bit [3:0] read_img_sel();
    return tb_top.u_dut.u_accel_top.u_csr_block.img_sel_q;
  endfunction

  function automatic void write_img_sel(bit [3:0] v);
    tb_top.u_dut.u_accel_top.u_csr_block.img_sel_q = v;
  endfunction

  function automatic bit [31:0] read_desc(int w);
    return tb_top.u_dut.u_accel_top.u_sram_1r1w_desc.mem[w];
  endfunction

  function automatic void write_desc(int w, bit [31:0] v);
    tb_top.u_dut.u_accel_top.u_sram_1r1w_desc.mem[w] = v;
  endfunction
endinterface
