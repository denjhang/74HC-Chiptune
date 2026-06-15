// ls189.v — 74LS189 64×4 位 RAM
//
// 74LS189 — 16-pin DIP 封装
// 64 字 × 4 位 RAM, 三态输出, 反相数据输出
//
// 实际网表引脚映射 (从 AD.net 反推):
//   Pin  1: A0      (地址 0)
//   Pin  2: /CS     (片选, 低有效) → GND
//   Pin  3: /WE     (写使能, 低有效)
//   Pin  4: D3      (数据输入 3)
//   Pin  5: O0      (数据输出 0, 反相, 三态)
//   Pin  6: D2      (数据输入 2)
//   Pin  7: O1      (数据输出 1, 反相)
//   Pin  8: GND
//   Pin  9: O2      (数据输出 2, 反相)
//   Pin 10: D1      (数据输入 1)
//   Pin 11: O3      (数据输出 3, 反相)
//   Pin 12: D0      (数据输入 0)
//   Pin 13: A3
//   Pin 14: A2
//   Pin 15: A1
//   Pin 16: VDD
//
// 注意: DI 和 DO 是独立引脚 (不是双向)!
// DI = Pin 4, 6, 10, 12 (对应 D3, D2, D1, D0)
// DO = Pin 5, 7, 9, 11 (对应 O0, O1, O2, O3, 反相)
//
// 功能:
//   /CS=0, /WE=0: 写入 (DI → RAM)
//   /CS=0, /WE=1: 读取 (RAM → ~DO, 反相输出)
//   /CS=1: 输出高阻

`timescale 1ns/1ps

module ls189 (
    input  wire        A0, A1, A2, A3,   // 地址 0-3 (Pin 1, 15, 14, 13)
    input  wire        WE_n,             // Pin 3
    input  wire        CS_n,             // Pin 2
    input  wire        D0, D1, D2, D3,   // 数据输入 (Pin 12, 10, 6, 4)
    input  wire        RST_n,            // 复位 (额外引脚, 强制 RST 期间不写)
    output wire        O0, O1, O2, O3    // 反相数据输出 (Pin 5, 7, 9, 11)
);

    // 64×4 RAM 存储阵列 (注意: 实际 LS189 是 16×4 = 4-bit 地址)
    reg [3:0] mem [0:15];
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            mem[i] = 4'b0000;
    end

    // 地址解码 (4-bit)
    wire [3:0] addr = {A3, A2, A1, A0};

    // 写入: /WE 下降沿锁存, 且 RST_n=1 期间才允许
    always @(negedge WE_n) begin
        if (CS_n == 1'b0 && RST_n === 1'b1) begin
            if (^{D3, D2, D1, D0} === 1'bx)
                $display("    [LS189-X-WRITE @%0t inst=%S addr=%0d D=%b%b%b%b hcnt=%02X active=%b u6_cs=%b u6_we=%b",
                    $time, $sformatf("%m"), addr, D3, D2, D1, D0,
                    wsg3_func_tb.u_dut.hcnt_r, wsg3_func_tb.u_dut.spfm_write_active,
                    wsg3_func_tb.u_dut.u6_cs_n, wsg3_func_tb.u_dut.u6_we_n);
            mem[addr] = {D3, D2, D1, D0};
        end
    end

    // 读出: 组合逻辑, 反相输出, /CS=1 时高阻 (用 z)
    // 注意: 仿真中高阻用 'z 表示
    assign O0 = (CS_n == 1'b0) ? ~mem[addr][0] : 1'bz;
    assign O1 = (CS_n == 1'b0) ? ~mem[addr][1] : 1'bz;
    assign O2 = (CS_n == 1'b0) ? ~mem[addr][2] : 1'bz;
    assign O3 = (CS_n == 1'b0) ? ~mem[addr][3] : 1'bz;

endmodule
