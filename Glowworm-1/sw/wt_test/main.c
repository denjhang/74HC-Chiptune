//==============================================================================
// sw/wt_test/main.c —— WT 单通道混音基准（对照 scc1ch）
//------------------------------------------------------------------------------
// 测 WT 算法的核心循环开销，对比 SCC：
//   SCC: cnt(32位) += step; offs = (cnt>>16)&0x1F; b = wav[offs]; tmp = (b*vol)>>4
//   WT : pos(16位) += step; idx = (pos>>5)&0x7F;   b = wav[idx];  tmp = b*lvl*vol>>10
// WT 用 16 位相位（萤火虫 short=2字节，加法开销减半）但多一次乘法
//==============================================================================
#include "glow_types.h"

extern u8 REGISTER_IO0;
#define IO0 REGISTER_IO0

static u16 pos = 0;
static u16 step_val;
static u8  level = 15;       // ADSR 输出（CPU 端算）
static u8  vol = 31;
static s8  wav[128];         // 128 点波形（带符号）

#define DO_WT_MIX() do { \
    s16 mix = 0; \
    pos += step_val; \
    { \
        u8  idx = (u8)(pos >> 5) & 0x7F; \
        s8  b   = wav[idx]; \
        s16 tmp = (s16)b * (s16)(level + 1) * (s16)(vol + 1); \
        tmp >>= 10; \
        mix += tmp; \
    } \
    if (mix > 127)  mix = 127; \
    if (mix < -128) mix = -128; \
    IO0 = (u8)(128 + mix); \
} while(0)

void main() {
    u8 i;
    // 初始化锯齿波
    for (i = 0; i < 128; i++) wav[i] = (s8)(i - 64);
    step_val = 0x0800;   // 16 位步进

    IO0 = 0xAA;
    DO_WT_MIX();
    IO0 = 0xBB;
    DO_WT_MIX();
    IO0 = 0xCC;
    DO_WT_MIX();
    IO0 = 0xDD;
    DO_WT_MIX();
    IO0 = 0xEE;
    DO_WT_MIX();
    IO0 = 0x55;
    while (1);
}
