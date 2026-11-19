# Timing constraints for the DE10-Lite demo (de10lite_top). One clock: the 50 MHz board clock.
create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

# Asynchronous inputs: every SW and KEY input goes through a 2-FF synchronizer (sync_2ff,
# reset_gen), so no timing relationship to clk50 exists or is needed.
set_false_path -from [get_ports {SW[*] KEY[*]}]

# Human-visible outputs (seven-segment displays, LEDs): static between runs, no timing
# relationship to any external clock.
set_false_path -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] LEDR[*]}]
