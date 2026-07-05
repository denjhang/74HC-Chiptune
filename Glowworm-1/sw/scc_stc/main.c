//==============================================================================
// sw/scc_stc/main.c —— SCC 性能基准测试（萤火虫版）
//------------------------------------------------------------------------------
// 程序流程：
//   1. 初始化 5 通道 SCC（设 step/vol/key/wave）
//   2. 循环 N 次调用 scc_render()
//   3. 每次调用后翻转 IO0.0（仿真器 -mark 模式会数周期）
//   4. 最后 IO0 = 0x55 表示完成
//==============================================================================
#include "glow_types.h"

extern u8 REGISTER_IO0;
#define IO0 REGISTER_IO0

extern void scc_set_step(u8 ch, u32 step);
extern void scc_set_vol(u8 ch, u8 vol);
extern void scc_set_key(u8 mask);
extern void scc_set_wave(u8 ch, u8 idx, u8 dat);
extern u8  scc_render(void);

// 简单三角波（32 点，0-255，128 中点）
static const u8 tri_wave[32] = {
    128,144,160,176,192,208,224,240,
    255,240,224,208,192,176,160,144,
    128,112, 96, 80, 64, 48, 32, 16,
      0, 16, 32, 48, 64, 80, 96,112
};

void main() {
    u8 ch, i;
    u16 n;

    // 初始化 5 通道：相同三角波，递减音量，相同步进
    for (ch = 0; ch < 5; ch++) {
        for (i = 0; i < 32; i++)
            scc_set_wave(ch, i, tri_wave[i]);
        scc_set_vol(ch, 15 - ch*2);     // ch0=15, ch1=13, ... 递减
        scc_set_step(ch, 0x00100000u >> (ch*2));  // 不同音高
    }
    scc_set_key(0x1F);                  // 全部 5 通道开

    // 渲染采样，每次累加到 check（阻止编译器优化掉循环）
    // volatile 防 lcc 死代码消除
    volatile u32 check = 0;
    for (n = 0; n < 5; n++) {           // 先 5 次测开销
        u8 s = scc_render();
        check += s;
    }

    IO0 = (u8)(check & 0x7F) | 0x80;    // 完成标记（任意非 0x55 值）
    IO0 = 0x55;                         // 最终标记
    while (1);
}
