// Lint fixture: one net driven by two cells. scripts/lint.sh must reject it.
module twocells (
    input  logic i_a,
    input  logic i_b,
    output logic o_y
);
  assign o_y = i_a & i_b;
  assign o_y = i_a | i_b;
endmodule
