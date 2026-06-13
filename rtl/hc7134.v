// hc7134.v — IDT7134 4K×8 双端口静态 RAM 模型
//
// IDT7134SA/LA — 48-pin DIP 封装 (P48-1)
// 4K×8 = 4096 bytes, 12-bit 地址 (A0-A11) × 2 端口
//
// 引脚映射 (48-pin DIP):
//
//   Left 端口 (Pin 1-24):           Right 端口 (Pin 25-48):
//    1: A0L      13: I/O2L           25: VCC      37: A3R
//    2: A1L      14: I/O3L           26: A10R     38: A2R
//    3: A2L      15: I/O4L           27: A11R     39: A1R
//    4: A3L      16: I/O5L           28: CE_R     40: A0R
//    5: A4L      17: I/O6L           29: R/W_R    41: I/O0R
//    6: A5L      18: I/O7L           30: OE_R     42: I/O1R
//    7: A6L      19: A11L            31: A9R      43: I/O2R
//    8: A7L      20: A10L            32: A8R      44: I/O3R
//    9: A8L      21: OE_L            33: A7R      45: I/O4R
//   10: A9L      22: R/W_L           34: A6R      46: I/O5R
//   11: I/O0L    23: CE_L            35: A5R      47: I/O6R
//   12: I/O1L    24: GND             36: A4R      48: I/O7R
//
// 读操作: CE#=0, OE#=0, R/W=1 → 输出数据
// 写操作: CE#=0, R/W=0 → 写入数据 (OE# 无关)
//
// 两个端口完全独立, 可同时访问不同地址
// 同时写同一地址时由用户保证数据完整性 (无片内仲裁)

`timescale 1ns/1ps

module hc7134 (
    // Left 端口 — 12-bit 地址
    input         A0L, A1L, A2L, A3L, A4L, A5L, A6L, A7L,
    input         A8L, A9L, A10L, A11L,
    // Left 端口 — 8-bit 数据 (inout → 拆分为 input 写 + output 读)
    input  [7:0]  DI_L,     // 写数据 (外部驱动)
    output [7:0]  DO_L,     // 读数据 (内部输出)
    // Left 端口 — 控制
    input         CE_L_n,   // Pin 23: 片选 (低有效)
    input         OE_L_n,   // Pin 21: 输出使能 (低有效)
    input         RW_L,     // Pin 22: 读/写 (1=读, 0=写)

    // Right 端口 — 12-bit 地址
    input         A0R, A1R, A2R, A3R, A4R, A5R, A6R, A7R,
    input         A8R, A9R, A10R, A11R,
    // Right 端口 — 8-bit 数据
    input  [7:0]  DI_R,     // 写数据
    output [7:0]  DO_R,     // 读数据
    // Right 端口 — 控制
    input         CE_R_n,   // Pin 28: 片选 (低有效)
    input         OE_R_n,   // Pin 30: 输出使能 (低有效)
    input         RW_R      // Pin 29: 读/写 (1=读, 0=写)
);

    // 内部存储阵列 (4K×8, 两端口共享)
    reg [7:0] mem [0:4095];

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1)
            mem[i] = 8'h00;
    end

    // ============================================================
    // Left 端口
    // ============================================================
    wire [11:0] addr_L = {A11L, A10L, A9L, A8L, A7L, A6L, A5L, A4L,
                          A3L, A2L, A1L, A0L};

    // Left 端口 写: CE#=0 且 R/W=0 的重叠期间写入
    always @(CE_L_n or RW_L or DI_L or A0L or A1L or A2L or A3L
             or A4L or A5L or A6L or A7L or A8L or A9L or A10L or A11L) begin
        if (!CE_L_n && !RW_L)
            mem[addr_L] = DI_L;
    end

    // Left 端口 读
    assign DO_L = (!CE_L_n && !OE_L_n && RW_L) ? mem[addr_L] : 8'hzz;

    // ============================================================
    // Right 端口
    // ============================================================
    wire [11:0] addr_R = {A11R, A10R, A9R, A8R, A7R, A6R, A5R, A4R,
                          A3R, A2R, A1R, A0R};

    // Right 端口 写
    always @(CE_R_n or RW_R or DI_R or A0R or A1R or A2R or A3R
             or A4R or A5R or A6R or A7R or A8R or A9R or A10R or A11R) begin
        if (!CE_R_n && !RW_R)
            mem[addr_R] = DI_R;
    end

    // Right 端口 读
    assign DO_R = (!CE_R_n && !OE_R_n && RW_R) ? mem[addr_R] : 8'hzz;

endmodule
