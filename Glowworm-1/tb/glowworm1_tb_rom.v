//==============================================================================
// tb/glowworm1_tb_rom.v —— 加载 glowcc 编译的 rom.bin 端到端测试
//------------------------------------------------------------------------------
// 用法：把 Glowworm-1/sw/test2/rom.bin 复制到本目录或修改 ROM_FILE 路径
//       vvp 会 $readmemh 读 hex，但 rom.bin 是二进制 → 用 $fopen/$fread 加载
//
// 测试 test2/main.c: IO0 = 0x55; while(1);
// 预期：跑若干拍后 IO0 = 0x55
//==============================================================================
`timescale 1ns/1ps
module glowworm1_tb_rom;
    reg clk = 0; reg rst_n = 0;
    wire [7:0] io0_o, io1_o; wire io0_oe, io1_oe;
    reg  [7:0] io0_i = 0, io1_i = 0;
    wire [23:0] dbg_pc; wire [15:0] dbg_ir;
    wire [7:0] dbg_A, dbg_B, dbg_RA;
    wire [23:0] dbg_A2A1A0; wire [7:0] dbg_rf_qa; wire [15:0] dbg_alu_q;

    glowworm1 dut(.*);
    always #5 clk = ~clk;

    // 加载 rom.hex（每行一个 4 位 hex = 一条 16 位指令，大端：opcode 在高位）
    integer i;

    initial begin
        // 初始化 prog_rom 为 NOP
        for (i = 0; i < 65536; i = i + 1) dut.prog_rom[i] = 16'hFFFF;

        // 读 rom.hex（先转 8 位 hex 文本兼容 $readmemh 16 位模式）
        $readmemh("rom.hex", dut.prog_rom);
        $display("Loaded rom.hex");

        repeat (3) @(posedge clk);
        rst_n = 1;

        // 跑 100000 拍（glow_cpu_init 生成的 ALU 表填充代码很长，含大量循环）
        for (i = 0; i < 100000; i = i + 1) begin
            @(negedge clk);
            // 检测 IO0 输出
            if (io0_oe && io0_o === 8'h55) begin
                $display("[PASS] IO0 = 0x55 at cycle %0d (PC=%h)", i, dbg_pc);
                $finish;
            end
        end

        $display("[FAIL] IO0 never reached 0x55 in 100000 cycles");
        $display("       final IO0=%02x oe=%b  PC=%h", io0_o, io0_oe, dbg_pc);
        $finish;
    end
endmodule
