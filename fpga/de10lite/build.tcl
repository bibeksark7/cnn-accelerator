# Quartus project and full compile of the DE10-Lite demo (top: de10lite_top).
# Run by fpga/de10lite/build_win.sh in a Windows build directory that holds this script, every
# RTL file (flat), pins.tcl, de10lite.sdc and the init files:
#   quartus_sh -t build.tcl
load_package flow

set proj de10lite
project_new $proj -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY de10lite_top
# MAX 10 initializes M9K contents only in this configuration mode (docs/decisions.md D-021).
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name SDC_FILE de10lite.sdc
foreach f [lsort [glob *.sv]] {
  set_global_assignment -name SYSTEMVERILOG_FILE $f
}
foreach {name file} {IMG_INIT img.hex WGT_INIT wgt.hex PARAM_INIT param.hex DESC_INIT desc.hex
                     LABEL_INIT label.hex} {
  set_parameter -name $name "\"$file\""
}
source pins.tcl

execute_flow -compile
project_close
