# Quartus project and full compile of the RISC-V SoC on the DE10-Lite (top: de10lite_soc_top,
# spec §13.7). Run by fpga/de10lite_soc/build_win.sh in a Windows build directory that holds this
# script, every RTL file (flat), picorv32.v, pins.tcl, de10lite_soc.sdc, the accelerator's init
# files and the demo firmware image demo.hex:
#   quartus_sh -t build.tcl
load_package flow

set proj de10lite_soc
project_new $proj -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY de10lite_soc_top
# MAX 10 initializes M9K contents only in this configuration mode (docs/decisions.md D-021).
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name SDC_FILE de10lite_soc.sdc
foreach f [lsort [glob *.sv]] {
  set_global_assignment -name SYSTEMVERILOG_FILE $f
}
# PicoRV32 (third_party, unmodified, D-039) is Verilog-2005.
set_global_assignment -name VERILOG_FILE picorv32.v
foreach {name file} {RAM_INIT demo.hex IMG_INIT img.hex WGT_INIT wgt.hex PARAM_INIT param.hex
                     DESC_INIT desc.hex} {
  set_parameter -name $name "\"$file\""
}
source pins.tcl

execute_flow -compile
project_close
