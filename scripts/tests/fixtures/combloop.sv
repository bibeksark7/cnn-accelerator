// Lint fixture: combinational loop. scripts/lint.sh must reject it.
module combloop (
    input  logic i_a,
    output logic o_y
);
  logic x, y;
  assign x   = y ^ i_a;
  assign y   = x;
  assign o_y = y;
endmodule
