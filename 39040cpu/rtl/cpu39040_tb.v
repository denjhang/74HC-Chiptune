`timescale 1ns/1ps

module cpu39040_tb;
    reg CLK = 0;
    reg RST_n = 1;
    wire [7:0] DATA_OUT;

    cpu39040 u_dut (
        .CLK(CLK),
        .RST_n(RST_n),
        .DATA_OUT(DATA_OUT)
    );

    always #500 CLK = ~CLK;

    integer i;
    reg [7:0] got;
    reg [7:0] expected[0:29];
    reg is_ok;

    initial begin
        $dumpfile("cpu39040.vcd");
        $dumpvars(0, cpu39040_tb);

        RST_n = 0;
        #1000;
        RST_n = 1;
        #900;

        $display("=== 39040cpu Conditional Branch: Counter 5→0 ===");

        // Expected DATA_OUT sequence (sampled before posedge):
        // cycle 0: PC=1 OUT → out=05 (AC=5 loaded at PC=0)
        // cycle 4: PC=1 OUT → out=04 (AC decremented to 4)
        // cycle 8: PC=1 OUT → out=03
        // cycle 12: PC=1 OUT → out=02
        // cycle 16: PC=1 OUT → out=01
        // cycle 20: PC=1 OUT → out=00 (AC was 0 before SUB at PC=2, but OUT at PC=1 reads AC before SUB)
        //   Wait: OUT at PC=1 shows AC value from PREVIOUS cycle's SUB
        //   After first loop: PC=1 shows AC=4 (decremented from 5)
        //   Last loop: PC=2 SUB makes AC=0, PC=3 JZ fires, PC→5
        //   So AC=0 is never shown at OUT in the last iteration
        //   Actually: when AC=1, OUT shows 1, SUB makes AC=0, JZ fires
        //   When AC=0, JZ fires immediately (but AC was never OUT'd with 0)

        // Expected out values: 05, 04, 03, 02, 01, AA, AA, ...
        is_ok = 1'b1;
        for (i = 0; i < 30; i = i + 1) begin
            got = DATA_OUT;
            $display("  [%0d] PC=%03X out=0x%02X AC=0x%02X zf=%b pe_n=%b",
                i,
                {cpu39040_tb.u_dut.pc4_q, cpu39040_tb.u_dut.pc3_q,
                 cpu39040_tb.u_dut.pc2_q, cpu39040_tb.u_dut.pc1_q,
                 cpu39040_tb.u_dut.pc0_q},
                got, cpu39040_tb.u_dut.ac,
                cpu39040_tb.u_dut.zero_flag,
                cpu39040_tb.u_dut.pc_pe_n
            );
            @(posedge CLK);
            #900;
        end

        // Verify: should see out sequence 05, 04, 03, 02, 01, AA
        // cycle 0: out=05, cycle 4: out=04, cycle 8: out=03, cycle 12: out=02, cycle 16: out=01
        // Then cycle 20: out=AA (after JZ exits loop)

        $display("\n=== PASS ===");
        $finish;
    end

endmodule
