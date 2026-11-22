# Timing constraints for the SoC on the DE10-Lite (de10lite_soc_top). One clock: the 50 MHz
# board clock. The same rules as the Milestone 1 demo (fpga/de10lite/de10lite.sdc, spec §12).
create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

# Asynchronous inputs: every SW and KEY input goes through a 2-FF synchronizer (sync_2ff,
# reset_gen), so no timing relationship to clk50 exists or is needed.
set_false_path -from [get_ports {SW[*] KEY[*]}]

# Human-visible outputs (seven-segment displays, LEDs): no timing relationship to any external
# clock.
set_false_path -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
