// hc39sf040.v — SST39SF040A 512K×8 Flash ROM 模型
//
// SST39SF040A — 32-pin PDIP 封装
// 512K×8 = 524,288 bytes, 19-bit 地址 (A0-A18)
//
// 引脚映射 (PDIP-32):
//   Pin  1: A18     Pin 32: VDD (5V)
//   Pin  2: A16     Pin 31: A17
//   Pin  3: A15     Pin 30: A14
//   Pin  4: A12     Pin 29: A13
//   Pin  5: A7      Pin 28: A8
//   Pin  6: A6      Pin 27: A9
//   Pin  7: A5      Pin 26: A11
//   Pin  8: A4      Pin 25: OE#
//   Pin  9: A3      Pin 24: A10
//   Pin 10: A2      Pin 23: CE#
//   Pin 11: A1      Pin 22: DQ7
//   Pin 12: A0      Pin 21: DQ6
//   Pin 13: DQ0     Pin 20: DQ5
//   Pin 14: DQ1     Pin 19: DQ4
//   Pin 15: DQ2     Pin 18: DQ3
//   Pin 16: VSS     Pin 17: WE#
//
// 读操作: CE#=0, OE#=0, WE#=1
//   地址锁存后 tAA (55/70ns) 数据有效
//   仿真中简化为组合逻辑输出

`timescale 1ns/1ps

module hc39sf040 #(
    parameter INIT_FILE = "",
    parameter ADDR_WIDTH = 19,
    parameter DATA_WIDTH = 8,
    parameter DEPTH = 524288
) (
    // 地址输入 (19-bit, 按 PDIP 引脚命名)
    input         A0, A1, A2, A3, A4, A5, A6, A7,
    input         A8, A9, A10, A11, A12, A13, A14, A15,
    input         A16, A17, A18,

    // 数据输入/输出 (8-bit, 按 PDIP 引脚命名)
    inout  [7:0]  DQ,

    // 控制
    input         CE_n,   // Pin 23: 片选 (低有效)
    input         OE_n,   // Pin 25: 输出使能 (低有效)
    input         WE_n    // Pin 17: 写使能 (低有效)
);

    // 内部存储阵列
    reg [7:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 8'hFF;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // 地址拼接 (按位组合 19-bit 地址)
    wire [18:0] addr = {A18, A17, A16, A15, A14, A13, A12, A11,
                        A10, A9, A8, A7, A6, A5, A4, A3, A2, A1, A0};

    // 读操作: CE#=0 且 OE#=0 时输出数据
    // 硬件 tAA=55ns (SST39SF040A-55), 仿真中建模此延迟
    // 延迟确保 posedge 时 FF 采样的仍是旧地址的数据
    assign #55 DQ = (!CE_n && !OE_n) ? mem[addr] : 8'hzz;

endmodule
