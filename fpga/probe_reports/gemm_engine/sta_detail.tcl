# Worst-case timing detail (slow corner) for the probe
project_open probe_gemm_engine
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 1 -detail full_path -file timing_setup_worst.rpt
report_timing -hold -npaths 1 -detail full_path -file timing_hold_worst.rpt
create_timing_summary -setup -file timing_summary_setup.rpt
create_timing_summary -hold -file timing_summary_hold.rpt
report_clock_fmax_summary -file fmax.rpt
delete_timing_netlist
project_close
