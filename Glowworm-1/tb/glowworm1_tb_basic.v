//==============================================================================
// tb/glowworm1_tb_basic.v —— 萤火虫1号基础 ISA 验证测试
//------------------------------------------------------------------------------
// 测试目标：验证"立即数→A→(ALU 加 0)→RF[RA]→IO0" 数据通路
// 预期：IO0 最终输出 0x55
//
// 测试程序（手工编机器码）：
//   addr 0: A  = 0x55       0x0155    立即数→A
//   addr 1: B  = 0x00       0x0600    立即数→B（ALU 第二操作数清零）
//   addr 2: RA = 0x10       0x0510    RF 地址
//   addr 3: RF = ALU[ADD]   0x1000    RF[0x10] = A+B = 0x55
//   addr 4: IO0 = RF        0x2A00    IO0 = RF[RA]
//   addr 5: NOP 死循环      0xFFFF
//==============================================================================
`timescale 1ns/1ps
module glowworm1_tb_basic;
    reg clk = 0;
    reg rst_n = 0;

    wire [7:0]  io0_o, io1_o;
    wire        io0_oe, io1_oe;
    reg  [7:0]  io0_i = 8'h00, io1_i = 8'h00;

    wire [23:0] dbg_pc;
    wire [15:0] dbg_ir;
    wire [7:0]  dbg_A, dbg_B, dbg_RA;
    wire [23:0] dbg_A2A1A0;
    wire [7:0]  dbg_rf_qa;
    wire [15:0] dbg_alu_q;

    glowworm1 #(
        .PROG_AW(16),
        .RF_AW(8),
        .DATA_AW(16)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .io0_o(io0_o), .io0_i(io0_i), .io0_oe(io0_oe),
        .io1_o(io1_o), .io1_i(io1_i), .io1_oe(io1_oe),
        .dbg_pc(dbg_pc), .dbg_ir(dbg_ir),
        .dbg_A(dbg_A), .dbg_B(dbg_B), .dbg_RA(dbg_RA),
        .dbg_A2A1A0(dbg_A2A1A0),
        .dbg_rf_qa(dbg_rf_qa), .dbg_alu_q(dbg_alu_q)
    );

    always #5 clk = ~clk;

    integer i;
    initial begin
        $display("===== 萤火虫1号 基础 ISA 测试 =====");
        $display("时间 | PC    | IR    | A   B   RA  | ALU    | IO0  | 备注");
        $display("-----+-------+-------+-------------+--------+------+----");

        // 加载程序
        dut.prog_rom[0] = 16'h0155;   // A = 0x55
        dut.prog_rom[1] = 16'h0600;   // B = 0x00
        dut.prog_rom[2] = 16'h0510;   // RA = 0x10
        dut.prog_rom[3] = 16'h1000;   // RF = ALU[ADD]
        dut.prog_rom[4] = 16'h2A00;   // IO0 = RF
        dut.prog_rom[5] = 16'hFFFF;   // NOP

        // 复位
        repeat (3) @(posedge clk);
        rst_n = 1;

        // 跑 12 个周期观察
        for (i = 0; i < 12; i = i + 1) begin
            @(negedge clk);
            $display("%4t | %5h | %4h  | %02x  %02x  %02x  | %04x   | %02x   | pc_step",
                $time, dbg_pc[15:0], dbg_ir, dbg_A, dbg_B, dbg_RA,
                dbg_alu_q, io0_o);
        end

        // 验证
        $display("----- verify -----");
        if (dut.rf_ram[8'h10] === 8'h55)
            $display("[PASS] RF[0x10] = 0x55 (ALU add-0 writeback ok)");
        else
            $display("[FAIL] RF[0x10] = %02x (expect 0x55)", dut.rf_ram[8'h10]);

        if (io0_o === 8'h55 && io0_oe === 1'b1)
            $display("[PASS] IO0 = 0x55, oe=1");
        else
            $display("[FAIL] IO0 = %02x, oe=%b (expect 0x55, oe=1)", io0_o, io0_oe);

        $finish;
    end
endmodule
