// Binds soc_bus_sva to the CPU's bus in soc_top (SoC tests, Verilator --assert).
bind soc_top soc_bus_sva u_soc_bus_sva (
    .clk   (clk),
    .rst   (rst),
    .bvalid(cpu_bvalid),
    .bready(cpu_bready),
    .bresp (cpu_bresp),
    .rvalid(cpu_rvalid),
    .rready(cpu_rready),
    .rresp (cpu_rresp),
    .trap  (o_trap)
);
