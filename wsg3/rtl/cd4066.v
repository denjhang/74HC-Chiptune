// cd4066.v — CD4066 四路双向模拟开关
//
// CD4066 — 14-pin DIP 封装
// 4 个独立的双向模拟开关, 由 CTRL 控制
//
// 引脚映射 (DIP-14):
//   Pin  1: IN1/OUT1   Pin 13: CTRL1
//   Pin  2: OUT1/IN1   Pin 12: CTRL4
//   Pin  3: OUT2/IN2   Pin 11: IN4/OUT4
//   Pin  4: IN2/OUT2   Pin 10: OUT4/IN4
//   Pin  5: CTRL2      Pin  9: OUT3/IN3
//   Pin  6: CTRL3      Pin  8: IN3/OUT3
//   Pin  7: VSS (GND)
//   Pin 14: VDD
//
// 功能:
//   CTRL=1: 开关闭合 (导通)
//   CTRL=0: 开关断开 (高阻)

`timescale 1ns/1ps

module cd4066 (
    input  wire CTRL1,
    input  wire CTRL2,
    input  wire CTRL3,
    input  wire CTRL4,
    inout  wire IO1A,  // Pin 1
    inout  wire IO1B,  // Pin 2
    inout  wire IO2A,  // Pin 4
    inout  wire IO2B,  // Pin 3
    inout  wire IO3A,  // Pin 8
    inout  wire IO3B,  // Pin 9
    inout  wire IO4A,  // Pin 11
    inout  wire IO4B   // Pin 10
);

    // 双向开关: 简化为单向 (IO_A 作输入, IO_B 作三态输出)
    // 真实 cd4066 是双向的, 但仿真中只在 B 侧驱动, 避免反馈环
    assign IO1B = CTRL1 ? IO1A : 1'bz;
    assign IO2B = CTRL2 ? IO2A : 1'bz;
    assign IO3B = CTRL3 ? IO3A : 1'bz;
    assign IO4B = CTRL4 ? IO4A : 1'bz;

endmodule
