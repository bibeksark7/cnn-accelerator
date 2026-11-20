# Timing reports for the DE10-Lite demo (run by build_win.sh after build.tcl):
#   quartus_sta -t sta_reports.tcl
#
# Every operating condition (corner) the device offers is analysed in turn:
#   timing_corners.rpt          worst setup and hold slack per corner (one line each)
#   timing_setup_worst.rpt      worst setup path per corner (appended)
#   timing_hold_worst.rpt       worst hold path per corner (appended)
#   timing_summary_setup.rpt    setup summary per corner (appended)
#   timing_summary_hold.rpt     hold summary per corner (appended)
#   mtbf.rpt                    synchronizer chains and their MTBF per corner (appended)
# and once:
#   fmax.rpt                    Fmax (slow corner, the default)
#   unconstrained_paths.rpt     must list no unconstrained paths
project_open de10lite
create_timing_netlist
read_sdc
update_timing_netlist

# Fmax and the unconstrained-path check at the default (slow) corner.
report_clock_fmax_summary -file fmax.rpt
# Every path must be constrained: this report must list no unconstrained paths.
report_ucp -summary -file unconstrained_paths.rpt

foreach f {timing_setup_worst.rpt timing_hold_worst.rpt timing_summary_setup.rpt
           timing_summary_hold.rpt mtbf.rpt} {
  file delete -force $f
}
set corners [open timing_corners.rpt w]
puts $corners "# Worst slack per operating condition (ns), clock clk50; written by sta_reports.tcl"
puts $corners "corner;setup_slack;hold_slack"

foreach_in_collection oc [get_available_operating_conditions] {
  set name [get_operating_conditions_info $oc -display_name]
  set_operating_conditions $oc
  update_timing_netlist
  set setup [report_timing -setup -npaths 1 -detail full_path -append -file timing_setup_worst.rpt]
  set hold [report_timing -hold -npaths 1 -detail full_path -append -file timing_hold_worst.rpt]
  create_timing_summary -setup -append -file timing_summary_setup.rpt
  create_timing_summary -hold -append -file timing_summary_hold.rpt
  report_metastability -append -file mtbf.rpt
  # report_timing returns {number_of_paths worst_slack}.
  puts $corners "$name;[lindex $setup 1];[lindex $hold 1]"
}
close $corners

delete_timing_netlist
project_close
