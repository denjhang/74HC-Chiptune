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
    reg [7:0] expected[0:7];
    reg [7:0] got;
    reg is_ok;

    initial begin
        $dumpfile("cpu39040.vcd");
        $dumpvars(0, cpu39040_tb);

        RST_n = 0;
        #1000;
        RST_n = 1;
        #500;

        expected[0] = 8'h42;
        expected[1] = 8'h4C;
        expected[2] = 8'h60;
        expected[3] = 8'h40;
        expected[4] = 8'h0F;
        expected[5] = 8'h0A;
        expected[6] = 8'hFF;
        expected[7] = 8'h00;

        $display("=== 39040cpu LD/ADD/SUB (6-chip, ROM tAA=55ns) ===");

        // 跳过 NOP(PC=0) — 1 cycle
        @(posedge CLK);

        is_ok = 1'b1;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge CLK);
            #100;
            got = DATA_OUT;
            $display("  [%0d] got=0x%02X  exp=0x%02X  %s",
                     i, got, expected[i],
                     (got === expected[i]) ? "OK" : "FAIL");
            if (got !== expected[i]) is_ok = 1'b0;
        end

        $display(is_ok ? "\nPASS" : "\nFAIL");
        $finish;
    end

endmodule
