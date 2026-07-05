//==============================================================================
// tb/glowworm1_tb_jmp.v —— 跳转测试
//------------------------------------------------------------------------------
// 测试 1：无条件跳转 JMP (07XX) → 死循环计数器自增
//   PC=0..3 自增 RF[0]，PC=4 JMP 回 PC=0
//   预期：RF[0] 每次循环 +1
//
// 程序：
//   PC=0: A = RF          0x2100   A = RF[0]
//   PC=1: B = 0x01        0x0601   ALU 加数
//   PC=2: RA = 0x00       0x0500   RF 地址
//   PC=3: RF = ALU[ADD]   0x1000   RF[0] += 1
//   PC=4: A2 = 0          0x0400   A2A1A0 = 0x000000
//   PC=5: A1 = 0          0x0300
//   PC=6: A0 = 0          0x0200
//   PC=7: PC = A2A1A0     0x07FE   JMP 0
//==============================================================================
`timescale 1ns/1ps
module glowworm1_tb_jmp;
    reg clk = 0; reg rst_n = 0;
    wire [7:0] io0_o, io1_o; wire io0_oe, io1_oe;
    reg  [7:0] io0_i = 0, io1_i = 0;
    wire [23:0] dbg_pc; wire [15:0] dbg_ir;
    wire [7:0] dbg_A, dbg_B, dbg_RA;
    wire [23:0] dbg_A2A1A0; wire [7:0] dbg_rf_qa; wire [15:0] dbg_alu_q;

    glowworm1 dut(.*);

    always #5 clk = ~clk;

    integer i;
    initial begin
        dut.prog_rom[0] = 16'h0500;   // RA = 0
        dut.prog_rom[1] = 16'h0000;   // RF[0] = 0  (init counter)
        dut.prog_rom[2] = 16'h2100;   // A = RF      ← loop body PC=2
        dut.prog_rom[3] = 16'h0601;   // B = 1
        dut.prog_rom[4] = 16'h0500;   // RA = 0
        dut.prog_rom[5] = 16'h1000;   // RF[0] = A+B
        dut.prog_rom[6] = 16'h0400;   // A2 = 0
        dut.prog_rom[7] = 16'h0300;   // A1 = 0
        dut.prog_rom[8] = 16'h0202;   // A0 = 2 (loop start)
        dut.prog_rom[9] = 16'h07FE;   // JMP 2

        repeat (3) @(posedge clk);
        rst_n = 1;

        $display("===== JMP test =====");
        $display("t     | PC  IR   A  B  RA | RF[0]");
        // 跑 30 个周期（应该跑 3+ 圈循环）
        for (i = 0; i < 30; i = i + 1) begin
            @(negedge clk);
            $display("%4t  | %2x  %04x %02x %02x %02x | %02x",
                $time, dbg_pc[7:0], dbg_ir, dbg_A, dbg_B, dbg_RA, dut.rf_ram[0]);
        end

        $display("----- verify -----");
        // 循环体 8 条指令 = 8 周期一圈，30 周期约 3 圈多，RF[0] 应该 >= 3
        if (dut.rf_ram[0] >= 8'd3)
            $display("[PASS] RF[0] = %0d (counter incremented via JMP loop)", dut.rf_ram[0]);
        else
            $display("[FAIL] RF[0] = %0d (expected >= 3)", dut.rf_ram[0]);

        $finish;
    end
endmodule
