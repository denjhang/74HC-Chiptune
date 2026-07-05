//==============================================================================
// tb/glowworm1_tb_jcc.v —— 条件跳转测试 (17XX, JCC)
//------------------------------------------------------------------------------
// 循环计数 counter 到 3 退出（验证 ALU[EQUAL].bit0 判据）
//
//   PC=0:  RA=0           0x0500
//   PC=1:  RF[0]=0        0x0000   init counter
//   PC=2:  A=RF           0x2100   loop: A=counter
//   PC=3:  B=0x01         0x0601
//   PC=4:  RA=0           0x0500
//   PC=5:  RF=ALU[ADD]    0x1000   counter += 1
//   PC=6:  A=RF           0x2100   A = new counter
//   PC=7:  B=0x03         0x0603   threshold
//   PC=8:  A2=0           0x0400   A2A1A0 = 2 (loop start)
//   PC=9:  A1=0           0x0300
//   PC=10: A0=2           0x0202
//   PC=11: JCC EQUAL      0x1705   if(counter!=3) PC=A2A1A0(=2)
//   PC=12: RA=0           0x0500
//   PC=13: IO0=RF         0x2A00   output counter (=3)
//   PC=14: NOP            0xFFFF
//
// 预期: IO0 = 3 (循环到 counter==3 退出)
//==============================================================================
`timescale 1ns/1ps
module glowworm1_tb_jcc;
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
        dut.prog_rom[0]  = 16'h0500;
        dut.prog_rom[1]  = 16'h0000;
        dut.prog_rom[2]  = 16'h2100;
        dut.prog_rom[3]  = 16'h0601;
        dut.prog_rom[4]  = 16'h0500;
        dut.prog_rom[5]  = 16'h1000;
        dut.prog_rom[6]  = 16'h2100;
        dut.prog_rom[7]  = 16'h0603;
        dut.prog_rom[8]  = 16'h0400;
        dut.prog_rom[9]  = 16'h0300;
        dut.prog_rom[10] = 16'h0202;
        dut.prog_rom[11] = 16'h1705;   // JCC EQUAL
        dut.prog_rom[12] = 16'h0500;
        dut.prog_rom[13] = 16'h2A00;
        dut.prog_rom[14] = 16'hFFFF;

        repeat (3) @(posedge clk);
        rst_n = 1;

        $display("===== JCC (conditional jump) test =====");
        $display("t     | PC  IR   A  B  | ALU  | RF[0] IO0");
        for (i = 0; i < 60; i = i + 1) begin
            @(negedge clk);
            $display("%4t  | %2x  %04x %02x %02x | %04x | %02x   %02x",
                $time, dbg_pc[7:0], dbg_ir, dbg_A, dbg_B,
                dbg_alu_q, dut.rf_ram[0], io0_o);
            // 提前结束：检测到 IO0 输出有效
            if (io0_oe && io0_o === 8'd3) begin
                $display("(IO0 output detected, exiting early)");
                i = 999;   // 跳出
            end
        end

        $display("----- verify -----");
        if (io0_o === 8'd3 && io0_oe)
            $display("[PASS] IO0 = 3 (loop exited at counter==3 via JCC EQUAL)");
        else
            $display("[FAIL] IO0 = %02x oe=%b (expect 3)", io0_o, io0_oe);

        $finish;
    end
endmodule
