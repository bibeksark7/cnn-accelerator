// Lint fixture: a used wire with no driver. scripts/lint.sh must reject it.
module undriven (
    input  logic i_a,
    output logic o_y
);
  logic w;
  assign o_y = w & i_a;
endmodule
