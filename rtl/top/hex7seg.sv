// hex7seg: one DE10-Lite seven-segment digit (segments active low, bit 7 the decimal point).
//
// i_code: 0..15 show the hex digit 0..F; 16 blank; 17 a dash (middle segment); 18 'E';
// other codes blank. The decimal point stays off.
// Segment order (Terasic): bit 0 a (top), 1 b, 2 c, 3 d (bottom), 4 e, 5 f, 6 g (middle), 7 dp.
//
// Ports:
//   i_code - what to show
//   o_seg  - segments, active low
//
// Latency: combinational.
module hex7seg (
    input  logic [4:0] i_code,
    output logic [7:0] o_seg
);

  localparam logic [4:0] CODE_BLANK = 5'd16;
  localparam logic [4:0] CODE_DASH = 5'd17;
  localparam logic [4:0] CODE_E = 5'd18;

  logic [6:0] on;  // segments g..a lit (active high)
  always_comb begin
    case (i_code)
      5'd0:      on = 7'b0111111;
      5'd1:      on = 7'b0000110;
      5'd2:      on = 7'b1011011;
      5'd3:      on = 7'b1001111;
      5'd4:      on = 7'b1100110;
      5'd5:      on = 7'b1101101;
      5'd6:      on = 7'b1111101;
      5'd7:      on = 7'b0000111;
      5'd8:      on = 7'b1111111;
      5'd9:      on = 7'b1101111;
      5'd10:     on = 7'b1110111;  // A
      5'd11:     on = 7'b1111100;  // b
      5'd12:     on = 7'b0111001;  // C
      5'd13:     on = 7'b1011110;  // d
      5'd14:     on = 7'b1111001;  // E
      5'd15:     on = 7'b1110001;  // F
      CODE_DASH: on = 7'b1000000;
      CODE_E:    on = 7'b1111001;
      CODE_BLANK: on = 7'b0000000;
      default:   on = 7'b0000000;  // unused codes: blank
    endcase
  end

  assign o_seg = {1'b1, ~on};

endmodule
