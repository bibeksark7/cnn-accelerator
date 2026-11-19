// Binds fsm_legal_sva to every FSM whose enum leaves encodings unused (Verilator --assert runs
// of accel_top). A module-type bind covers every instance of the module.
bind layer_seq fsm_legal_sva #(
    .W       (3),
    .N_STATES(7)
) u_fsm_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(state_q)
);

bind gemm_engine fsm_legal_sva #(
    .W       (4),
    .N_STATES(11)
) u_qstate_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(qstate_q)
);

bind gemm_engine fsm_legal_sva #(
    .W       (3),
    .N_STATES(6)
) u_dstate_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(dstate_q)
);

bind agen_a fsm_legal_sva #(
    .W       (3),
    .N_STATES(6)
) u_fsm_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(state_q)
);

bind agen_pool fsm_legal_sva #(
    .W       (2),
    .N_STATES(3)
) u_fsm_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(state_q)
);

bind pool_unit fsm_legal_sva #(
    .W       (2),
    .N_STATES(3)
) u_fsm_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(state_q)
);

bind demo_ctrl fsm_legal_sva #(
    .W       (2),
    .N_STATES(3)
) u_fsm_legal_sva (
    .clk  (clk),
    .rst  (rst),
    .state(state_q)
);
