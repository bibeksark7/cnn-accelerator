// Lint fixture: generate-if without generate/endgenerate (Quartus 22.1 rejects it).
module bare_generate #(
    parameter int N = 1
) (
    output logic o_y
);
  if (N == 1) begin : g_one
    assign o_y = 1'b1;
  end else begin : g_other
    assign o_y = 1'b0;
  end
endmodule
