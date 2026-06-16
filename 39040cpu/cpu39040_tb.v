`timescale 1ns/1ps

// cpu39040_tb.v — 39040cpu 测试台

module cpu39040_tb;
    reg CLK = 0;
    reg RST_n = 1;
    reg [7:0] EXT_IN = 8'hFF;
    wire [7:0] DATA_OUT;
    wire       PLAYING;

    cpu39040 u_dut (
        .CLK(CLK),
        .RST_n(RST_n),
        .EXT_IN(EXT_IN),
        .DATA_OUT(DATA_OUT),
        .PLAYING(PLAYING)
    );

    always #500 CLK = ~CLK;

    integer i;
    integer ci;
    reg [7:0] out_samples[0:127];
    reg [7:0] changes[0:15];
    reg [7:0] expected[0:6];
    reg is_ok;

    initial begin
        $dumpfile("cpu39040.vcd");
        $dumpvars(0, cpu39040_tb);

        RST_n = 0;
        #2000;
        RST_n = 1;
        #1000;

        $display("=== 39040cpu Test ===");
        $display("Expected DATA_OUT changes: 42, 4A, 0F, BD, 55, 30");
        $display("");

        // 收集 80 个样本 (每 2 时钟周期)
        for (i = 0; i < 80; i = i + 1) begin
            @(posedge CLK);
            #20;
            @(posedge CLK);
            #20;
            out_samples[i] = DATA_OUT;
        end

        // 提取变化的值
        ci = 0;
        changes[0] = out_samples[0];
        for (i = 1; i < 80; i = i + 1) begin
            if (out_samples[i] !== changes[ci] && ci < 15) begin
                ci = ci + 1;
                changes[ci] = out_samples[i];
            end
        end

        $display("Detected %0d value changes:", ci);
        for (i = 0; i <= ci; i = i + 1)
            $display("  change[%0d] = 0x%02X", i, changes[i]);

        // 验证: 期望 0x00 → 0x42 → 0x4A → 0x0F → 0xBD → 0x55 → 0x30
        expected[0] = 8'h00;
        expected[1] = 8'h42;
        expected[2] = 8'h4A;
        expected[3] = 8'h0F;
        expected[4] = 8'hBD;
        expected[5] = 8'h55;
        expected[6] = 8'h30;

        $display("");
        $display("=== Verification ===");
        is_ok = 1'b1;
        for (i = 0; i < 7 && i <= ci; i = i + 1) begin
            if (changes[i] !== expected[i]) begin
                $display("  FAIL: change[%0d] = 0x%02X, expected 0x%02X",
                         i, changes[i], expected[i]);
                is_ok = 1'b0;
            end else begin
                $display("  OK:   change[%0d] = 0x%02X", i, changes[i]);
            end
        end

        if (ci < 6) begin
            $display("  FAIL: only %0d changes detected, expected 6", ci);
            is_ok = 1'b0;
        end

        if (is_ok)
            $display("\nPASS");
        else
            $display("\nFAIL");

        $finish;
    end

endmodule
