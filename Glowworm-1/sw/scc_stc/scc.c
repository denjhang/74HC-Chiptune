//==============================================================================
// sw/scc_stc/scc.c —— SCC (K051649) 仿真核心（萤火虫版，移植自 STC_Chiptune）
//------------------------------------------------------------------------------
// 移植自 D:\working\vscode-projects\STC_Chiptune\STC32G144K246\scc.c
// 仅改：去掉 STC32G.H，用 glow_types.h，类型映射对齐萤火虫（int=4字节）
// 算法 100% 保留，作为 Glowworm-1 性能基准 + SCC 专用架构设计的依据
//==============================================================================
#include "glow_types.h"

#define SCC_CHANS    5
#define SCC_WAVELEN  32

static u32 scc_cnt[SCC_CHANS];
static u32 scc_step_val[SCC_CHANS];
static u8  scc_vol[SCC_CHANS];
static u8  scc_key[SCC_CHANS];
static u16 scc_freq[SCC_CHANS];
static u8  scc_wav[SCC_CHANS][SCC_WAVELEN];

// 预计算的步进值（避免每次 render 都做 double 除法）
// STC 版在 scc_wr 里用 double 算 step，萤火虫支持 double，但 render 内只做整数加法
void scc_set_step(u8 ch, u32 step) {
    if (ch < SCC_CHANS) scc_step_val[ch] = step;
}

void scc_set_vol(u8 ch, u8 vol) {
    if (ch < SCC_CHANS) scc_vol[ch] = vol & 0x0F;
}

void scc_set_key(u8 mask) {
    u8 ch;
    for (ch = 0; ch < SCC_CHANS; ch++)
        scc_key[ch] = (mask >> ch) & 1;
}

void scc_set_wave(u8 ch, u8 idx, u8 dat) {
    if (ch < SCC_CHANS && idx < SCC_WAVELEN)
        scc_wav[ch][idx] = dat;
}

//==============================================================================
// SCC_MIX_CH —— 单通道混音（这是性能热点，每个采样执行 5 次）
//==============================================================================
#define SCC_MIX_CH(ch, mix_var) do { \
    if (scc_step_val[ch] > 0) { \
        scc_cnt[ch] += scc_step_val[ch]; \
        if (scc_key[ch]) { \
            u8  _offs = (u8)(scc_cnt[ch] >> 16) & 0x1F; \
            u8  _vol  = scc_vol[ch]; \
            u8  _b    = scc_wav[ch][_offs]; \
            s16 _tmp; \
            if (_b >= 128) \
                _tmp = -(s16)(((u16)(256 - _b) * _vol) >> 4); \
            else \
                _tmp = (s16)(((u16)_b * _vol) >> 4); \
            mix_var += _tmp; \
        } \
    } \
} while(0)

//==============================================================================
// scc_render —— 渲染一个采样（5 通道混音）
//==============================================================================
u8 scc_render(void) {
    s16 mix = 0;
    SCC_MIX_CH(0, mix);
    SCC_MIX_CH(1, mix);
    SCC_MIX_CH(2, mix);
    SCC_MIX_CH(3, mix);
    SCC_MIX_CH(4, mix);
    if (mix > 127)  mix = 127;
    if (mix < -128) mix = -128;
    return (u8)(128 + mix);
}
