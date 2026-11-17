// Lint fixture: constant bit selects in always_comb (Icarus prints a "sorry" message).
module icarus_sorry (
    input  logic [1:0] i_a,
    output logic       o_y
);
  always_comb begin
    o_y = i_a[1] & i_a[0];
  end
endmodule
