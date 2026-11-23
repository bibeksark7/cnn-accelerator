// The parts of uvm-core's DPI C code the bench uses with Verilator: messages, regular
// expressions (uvm_config_db / factory lookups by pattern) and the command line (+UVM_TESTNAME
// and other plusargs). Not the HDL backdoor (uvm_hdl.c), which needs a simulator-specific VPI
// back end: the register model is accessed through the bus only (docs/decisions.md D-052).
#include <stdlib.h>
extern "C" {
#include "uvm_dpi.h"
#include "uvm_common.c"
#include "uvm_regex.cc"
#include "uvm_svcmd_dpi.c"
}
