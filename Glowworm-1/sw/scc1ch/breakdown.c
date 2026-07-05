//==============================================================================
// sw/scc1ch/breakdown.c —— SCC 混音 580 拍分解（按操作段分别测开销）
//------------------------------------------------------------------------------
// 把 DO_MIX 拆成 4 段，每段单独测，差分得出每段拍数：
//   段 1：相位累加 cnt += step（32 位加法）
//   段 2：地址提取 + 查表 offs = (cnt>>16)&0x1F; b = wav[offs]
//   段 3：乘音量 (b*vol)>>4 或补码版
//   段 4：饱和 + 输出
// 每段前后 IO0 = 不同标记，mark 模式数 delta
//==============================================================================
#include "../scc_stc/glow_types.h"

extern u8 REGISTER_IO0;
#define IO0 REGISTER_IO0

static u32 cnt = 0;
static u32 step_val = 0x00100000u;
static u8  vol = 12;
static u8  wav[32];
static u8  dummy;        // 防优化

void main() {
    u8 i;
    // 初始化波形
    for (i = 0; i < 32; i++) wav[i] = i * 8;

    //==== 段 1：相位累加（32 位加法）测 50 次平均 ====
    IO0 = 0xA0;  // mark
    for (i = 0; i < 50; i++) {
        cnt += step_val;
    }
    IO0 = 0xA1;  // mark

    //==== 段 2：地址提取 + 查表（测 50 次）====
    IO0 = 0xB0;
    for (i = 0; i < 50; i++) {
        u8 offs = (u8)(cnt >> 16) & 0x1F;
        dummy = wav[offs];
    }
    IO0 = 0xB1;

    //==== 段 3：乘音量（测 50 次，含分支）====
    IO0 = 0xC0;
    for (i = 0; i < 50; i++) {
        u8 b = dummy;
        s16 t;
        if (b >= 128)
            t = -(s16)(((u16)(256 - b) * vol) >> 4);
        else
            t = (s16)(((u16)b * vol) >> 4);
        dummy = (u8)(t & 0xFF);
    }
    IO0 = 0xC1;

    //==== 段 4：完整 DO_MIX（参照，应该 ≈ 段1+段2+段3+开销）====
    IO0 = 0xD0;
    for (i = 0; i < 50; i++) {
        s16 mix = 0;
        cnt += step_val;
        {
            u8 offs = (u8)(cnt >> 16) & 0x1F;
            u8 b    = wav[offs];
            s16 _tmp;
            if (b >= 128)
                _tmp = -(s16)(((u16)(256 - b) * vol) >> 4);
            else
                _tmp = (s16)(((u16)b * vol) >> 4);
            mix += _tmp;
        }
        if (mix > 127)  mix = 127;
        if (mix < -128) mix = -128;
        dummy = (u8)(128 + mix);
    }
    IO0 = 0xD1;

    IO0 = 0x55;
    while (1);
}
