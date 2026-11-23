// accel_ref: the expected results, exported from Python (testbench/uvm/test_uvm.py, from the
// committed model/artifacts) as hex files, and the network's buffer images.
//
// Plusargs: +REF_DIR=<dir> with images.hex (IMG_SIZE bytes per image, as two's-complement
// int8), logits.hex (N_CLASSES int32 per image), pred.hex (one class per image) and count.txt
// (the number of images; every file in hex); +MEM_DIR=<dir> with the network's wgt.hex,
// param.hex and desc.hex (model/artifacts/mem).
class accel_ref extends uvm_object;
  `uvm_object_utils(accel_ref)

  int n_images;
  bit [7:0] images[];  // image k, byte i at k * IMG_SIZE + i
  bit [31:0] logits[];  // image k, class c at k * N_CLASSES + c
  bit [7:0] pred[];
  bit [63:0] wgt[BUF_DEPTH[SEL_WGT]];
  bit [63:0] param[BUF_DEPTH[SEL_PARAM]];
  bit [31:0] desc[DESC_WORDS];

  function new(string name = "accel_ref");
    super.new(name);
  endfunction

  // One hex number per line; returns the values in order.
  static function void read_hex(string path, ref bit [63:0] values[$]);
    int fd, n;
    string line;
    bit [63:0] v;
    values.delete();
    fd = $fopen(path, "r");
    if (fd == 0) `uvm_fatal("REF", $sformatf("cannot open %s", path))
    while ($fgets(line, fd)) begin
      n = $sscanf(line, "%h", v);
      if (n == 1) values.push_back(v);
    end
    $fclose(fd);
  endfunction

  function bit [7:0] image_byte(int k, int i);
    return images[k*IMG_SIZE+i];
  endfunction

  function bit [31:0] logit(int k, int c);
    return logits[k*N_CLASSES+c];
  endfunction

  function void load();
    string ref_dir, mem_dir;
    bit [63:0] v[$];
    if (!$value$plusargs("REF_DIR=%s", ref_dir)) `uvm_fatal("REF", "+REF_DIR not given")
    if (!$value$plusargs("MEM_DIR=%s", mem_dir)) `uvm_fatal("REF", "+MEM_DIR not given")
    read_hex({ref_dir, "/count.txt"}, v);
    if (v.size() != 1) `uvm_fatal("REF", "count.txt: expected one number")
    n_images = int'(v[0]);
    images = new[n_images * IMG_SIZE];
    logits = new[n_images * N_CLASSES];
    pred = new[n_images];
    read_hex({ref_dir, "/images.hex"}, v);
    if (v.size() != n_images * IMG_SIZE)
      `uvm_fatal("REF", $sformatf("images.hex: %0d bytes", v.size()))
    foreach (v[i]) images[i] = v[i][7:0];
    read_hex({ref_dir, "/logits.hex"}, v);
    if (v.size() != n_images * N_CLASSES) `uvm_fatal("REF", "logits.hex: wrong size")
    foreach (v[i]) logits[i] = v[i][31:0];
    read_hex({ref_dir, "/pred.hex"}, v);
    if (v.size() != n_images) `uvm_fatal("REF", "pred.hex: wrong size")
    foreach (v[i]) pred[i] = v[i][7:0];
    read_hex({mem_dir, "/wgt.hex"}, v);
    if (v.size() != BUF_DEPTH[SEL_WGT]) `uvm_fatal("REF", "wgt.hex: wrong size")
    foreach (v[i]) wgt[i] = v[i];
    read_hex({mem_dir, "/param.hex"}, v);
    if (v.size() != BUF_DEPTH[SEL_PARAM]) `uvm_fatal("REF", "param.hex: wrong size")
    foreach (v[i]) param[i] = v[i];
    read_hex({mem_dir, "/desc.hex"}, v);
    if (v.size() != DESC_WORDS) `uvm_fatal("REF", "desc.hex: wrong size")
    foreach (v[i]) desc[i] = v[i][31:0];
    `uvm_info("REF", $sformatf("%0d reference images from %s; network from %s", n_images, ref_dir,
                               mem_dir), UVM_LOW)
  endfunction
endclass
