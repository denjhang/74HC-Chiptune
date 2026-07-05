//==============================================================================
// sw/scc_stc/glow_types.h —— 萤火虫基本类型（适配 STC 移植）
//------------------------------------------------------------------------------
// 注意：萤火虫 int = 4 字节，与 STC32G（int=2字节）不同
//   所以 STC 代码里的 u16/s16 不能直接映射到 int，必须用 short
//==============================================================================
#ifndef GLOW_TYPES_H
#define GLOW_TYPES_H

typedef unsigned char      u8;
typedef unsigned short     u16;   // 萤火虫 short=2字节
typedef unsigned int       u32;   // 萤火虫 int=4字节
typedef signed char        s8;
typedef signed short       s16;
typedef signed int         s32;

#endif
