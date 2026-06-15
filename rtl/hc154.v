// hc154.v — 74HC154 4-to-16 Line Decoder/Demultiplexer (active-low outputs)
//
// DIP-24
//   Pin 1:  Y0 (output, active low)
//   Pin 2:  Y1
//   Pin 3:  Y2
//   Pin 4:  Y3
//   Pin 5:  Y4
//   Pin 6:  Y5
//   Pin 7:  Y6
//   Pin 8:  Y7
//   Pin 9:  Y8
//   Pin 10: Y9
//   Pin 11: Y10
//   Pin 12: GND
//   Pin 13: Y11
//   Pin 14: Y12
//   Pin 15: Y13
//   Pin 16: Y14
//   Pin 17: Y15
//   Pin 18: NC
//   Pin 19: A3
//   Pin 20: A2
//   Pin 21: A1
//   Pin 22: A0
//   Pin 23: /G (enable, active low)
//   Pin 24: VCC
//
// When /G=0, one of Y0-Y15 is pulled low based on A[3:0].
// When /G=1, all outputs are high.

`timescale 1ns/1ps

module hc154 (
    input  [3:0] A,
    input        G_n,
    output [15:0] Y
);
    reg [15:0] y_reg;

    always @(*) begin
        if (!G_n)
            y_reg = ~(16'b0000_0000_0000_0001 << A);
        else
            y_reg = 16'hFFFF;
    end

    assign #(15, 15) Y = y_reg;
endmodule
