`timescale 1ns/1ps

// cpu39040_tb.v — 39040cpu 测试台
// 期望 OUT 变化: 42, 4A, 0F, BD, 55, 30, DE, BB, 03, 02, 01, FF

module cpu39040_tb;
    reg CLK = 0;
    reg RST_n = 1;
    reg [7:0] EXT_IN = 8'hFF;
    wire [7:0] DATA_OUT;
    wire       PLAYING;

    cpu39040 u_dut (
        .CLK(CLK), .RST_n(RST_n), .EXT_IN(EXT_IN),
        .DATA_OUT(DATA_OUT), .PLAYING(PLAYING)
    );

    always #500 CLK = ~CLK;

    integer i;
    integer ci;
    reg [7:0] out_samples[0:255];
    reg [7:0] changes[0:31];
    reg [7:0] expected[0:15];
    reg is_ok;

    initial begin
        $dumpfile("cpu39040.vcd");
        $dumpvars(0, cpu39040_tb);

        // 期望: 00 42 4A 0F BD 55 30 DE BB 03 02 01 FF
        expected[0]  = 8'h00;
        expected[1]  = 8'h42;
        expected[2]  = 8'h4A;
        expected[3]  = 8'h0F;
        expected[4]  = 8'hBD;
        expected[5]  = 8'h55;
        expected[6]  = 8'h30;
        expected[7]  = 8'hDE;
        expected[8]  = 8'hBB;
        expected[9]  = 8'h03;
        expected[10] = 8'h02;
        expected[11] = 8'h01;
        expected[12] = 8'hFF;

        RST_n = 0;
        #2000;
        RST_n = 1;
        #1000;

        $display("=== 39040cpu Full Test ===");
        $display("Expected: 00 42 4A 0F BD 55 30 DE BB 03 02 01 FF");

        // 收集 200 个样本, 每个 CLK 边沿采样一次 (#50 确保传播延迟)
        for (i = 0; i < 400; i = i + 1) begin
            @(posedge CLK);
            #50;
            out_samples[i] = DATA_OUT;
            // Debug: print all samples
            if (i < 80) begin
                $display("  s[%0d] t=%0dns OUT=0x%02X pc=%0d rom=%0d ctrl=0x%02X d=0x%02X ac=0x%02X out=0x%02X jf=%0d pe=%0d",
                         i, $time, DATA_OUT, u_dut.pc, u_dut.rom_addr,
                         u_dut.ctrl, u_dut.d_reg, u_dut.ac, u_dut.out_reg,
                         u_dut.jmp_flag_reg, u_dut.pc_pe_n);
            end
        end

        // 提取变化的值
        ci = 0;
        changes[0] = out_samples[0];
        for (i = 1; i < 400; i = i + 1) begin
            if (out_samples[i] !== changes[ci] && ci < 31) begin
                ci = ci + 1;
                changes[ci] = out_samples[i];
            end
        end

        $display("");
        $display("Detected %0d changes:", ci);
        for (i = 0; i <= ci; i = i + 1)
            $display("  [%2d] 0x%02X", i, changes[i]);

        // 验证
        $display("");
        $display("=== Verification ===");
        is_ok = 1'b1;
        for (i = 0; i < 13; i = i + 1) begin
            if (i > ci) begin
                $display("  FAIL: expected change[%0d]=0x%02X but only %0d changes",
                         i, expected[i], ci);
                is_ok = 1'b0;
            end else if (changes[i] !== expected[i]) begin
                $display("  FAIL: [%0d] got 0x%02X expected 0x%02X",
                         i, changes[i], expected[i]);
                is_ok = 1'b0;
            end else begin
                $display("  OK:   [%0d] = 0x%02X", i, changes[i]);
            end
        end

        if (is_ok)
            $display("\nPASS");
        else
            $display("\nFAIL");

        $finish;
    end

endmodule
