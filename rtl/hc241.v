// hc241.v — 74HC241 八缓冲器/线驱动器 (3 态, 两组使能, 一组同相一组反相)
//
// 74HC241 — 20-pin DIP 封装
// 与 74HC244 引脚兼容，区别在于：
//   74HC244: /1G 和 /2G 都低有效，两组都是同相缓冲
//   74HC241: /1G 低有效（组1同相），2G 高有效（组2同相）—— 使能极性相反
//
// 这个极性相反的特性使 HC241 非常适合做"二选一"总线切换：
//   将 /1G 和 2G 接同一个 MODE 信号：
//     MODE=0 → 组1导通（同相），组2高阻
//     MODE=1 → 组1高阻，组2导通（同相）
//   实现无竞争的总线切换（两组永远不会同时导通）。
//
// 引脚映射 (DIP-20, Nexperia 74HC244D/74HC241D 通用):
//   Pin  1: /1G   (组 1 输出使能, 低有效)
//   Pin  2: 1A1   Pin 11: 2A4
//   Pin  3: 1Y1   Pin 12: 1Y4
//   Pin  4: 1A2   Pin 13: 2A3
//   Pin  5: 1Y2   Pin 14: 2Y3
//   Pin  6: 1A3   Pin 15: 2A2
//   Pin  7: 1Y3   Pin 16: 2Y2
//   Pin  8: 1A4   Pin 17: 2A1
//   Pin  9: 1Y4   Pin 18: 2Y1
//   Pin 10: GND   Pin 19: 2G    (高有效, 与 /1G 极性相反)
//   Pin 20: VDD
//
// 功能:
//   /1G=L: 1Yn = 1An (组 1 同相透明)
//   /1G=H: 1Yn = Z  (组 1 高阻)
//   2G=H:  2Yn = 2An (组 2 同相透明)
//   2G=L:  2Yn = Z  (组 2 高阻)
//
// 用途 (miniglow): MODE 信号线切换下载/运行总线仲裁
//   MODE=0 (下载): FT232H → SRAM 通道导通 (组1), CPU IO 通道高阻 (组2)
//   MODE=1 (运行): CPU IO ↔ FT232H 通道导通 (组2), FT232H→SRAM 高阻 (组1)

`timescale 1ns/1ps

module hc241 (
    input        G1_n,    // Pin 1:  组 1 输出使能 (低有效)
    input  [3:0] A1,      // 组 1 输入 (1A1-1A4)
    output [3:0] Y1,      // 组 1 输出 (1Y1-1Y4)
    input        G2,      // Pin 19: 组 2 输出使能 (高有效, 与 74HC244 的 /2G 极性相反)
    input  [3:0] A2,      // 组 2 输入 (2A1-2A4)
    output [3:0] Y2       // 组 2 输出 (2Y1-2Y4)
);

    // 传播延迟 tPHL/tPLH ≈ 11ns (VDD=4.5V)
    assign #11 Y1 = (!G1_n) ? A1 : 4'bzzzz;
    assign #11 Y2 = ( G2  ) ? A2 : 4'bzzzz;

endmodule
