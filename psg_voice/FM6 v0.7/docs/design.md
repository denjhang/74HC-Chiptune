# FM6 v0.7 设计文档

> 6 通道 2-op FM 合成器, 查表法, 基于 WSG8 v0.7 TDM 架构
> 创建时间：2026-07-10
> 状态：**架构设计阶段, 待 RTL 验证**
> 算法来源：`STC_Chiptune/STC32G144K246/ym2413.c` (完整路径见 handoff.md)

---

## 0. 本文解决了什么

handoff.md 列了 6 个"待解决问题"和 7 项"待实现"。本文逐个给出架构方案，
作为 RTL 建模和接线表的依据。核心是回答一个问题：

**2-op FM 的 8 步运算序列 (ym_render 里每通道每采样做的事), 怎么映射到
WSG8 的 TDM 分时引擎上, 用哪几片 74 芯片实现?**

---

## 1. 算法精读 (从 ym2413.c ym_render() 提取)

### 1.1 每通道每采样的完整运算 (ym2413.c 第 325-356 行)

```
对每个活跃通道 ch:
  ① phase_m += step * mul_m           // OP1 NCO 累加 (16-bit)
  ② phase_c += step                    // OP2 NCO 累加 (16-bit)
  ③ idx_m = (phase_m >> 10) & 0x3F     // OP1 取相位高 6 位 (64 点正弦)
  ④ idx_m += fb_val; idx_m &= 0x3F     // 加反馈, 模 64
  ⑤ mod_out = conv_vol[env_level_m][idx_m]   // OP1 查表 (有符号 8-bit)
  ⑥ fb_val = mod_out * fb >> 4          // 反馈 (fb=0..7, 移位近似)
  ⑦ idx_c = (phase_c >> 10) & 0x3F      // OP2 取相位高 6 位
  ⑧ idx_c += mod_out; idx_c &= 0x3F     // 加 OP1 输出做相位调制
  ⑨ carrier = conv_vol[env_level_c][idx_c]  // OP2 查表
  ⑩ mix += carrier * (16-vol) >> 2      // 输出缩放并累加
```

**关键观察 (决定硬件映射)**:

1. **两个 NCO (phase_m/phase_c) 结构完全相同**: `phase += step`，16-bit 累加。
   区别只在 step 值 (phase_m 的 step 含 mul_m 倍率)。
   → **可以分时复用同一套 HC283+HC174 累加器**, OP1 步用一次、OP2 步用一次。

2. **两次查 conv_vol 表 (OP1 和 OP2)**: 地址格式都是 `{env_level[4:0], idx[5:0]}`，
   都是 11-bit。区别只在 env_level 来源 (m vs c) 和 idx 来源 (phase_m vs phase_c+mod_out)。
   → **同一片 62256 conv_vol RAM 查两次**, 地址分时切换。

3. **相位调制 (⑧) 是个加法**: `idx_c + mod_out`，但 mod_out 是**有符号 s8**，
   而 idx_c 是 6-bit 无符号 (0-63)。ym2413.c 直接 `& 0x3F` 把进位丢了 (模 64)。
   → **HC283 做 8-bit 加法, 取低 6 位做地址**。mod_out 的有符号性靠查表数据保证
   (conv_vol 表本身是有符号的, 正弦上下半周对称)。

4. **feedback (⑥) 用移位**: `mod_out * fb >> 4`。fb 只有 0-7 八档。
   STC 用整数乘法 + 移位。硬件上 fb 是常数 (查音色参数), 可以预移位或用 HC164。
   → **简化: fb 只支持 0/1/2/4 四档 (移位实现), 砍 fb=3/5/6/7 (音色表里基本是 0/1)**。
   实测 16 个内置音色里只有 Synth (A) 用 fb=1, 其余全 fb=0。
   → **fb=0 时 ⑥ 跳过, fb=1 时 idx_m 直接加 mod_out (不移位), fb=2 时 mod_out>>1**。

5. **ADSR 是 round-robin**: ym2413.c 每 tick 只更新 1 个通道的包络 (第 302-322 行)。
   6 通道要 6 tick 才轮一圈, 包络变化慢但省算力。
   → **硬件上 ADSR 可以放在每通道 TDM 步序列的末尾, 只占 1 子步**。

### 1.2 conv_vol 表结构 (ym2413.c 第 17-50 行)

```
ym_conv_vol[32][64], s8 (有符号 8-bit)
  [32] = env_level (0-31, ADSR 当前电平)
  [64] = sin_index (相位高 6 位)
  值 = sin(index) × level / 31, 范围 ±31

一片 62256 (32KB) 存 16 套 (实际只需 1 套 2048 字节)
地址 = level << 6 | index = 11-bit (0x0000-0x07FF)
```

**符号处理**: conv_vol 数据是有符号的 (s8, -31~+31)。62256 输出 8-bit 直接送 DAC。
TLC7524 是乘法 DAC, REF 接直流偏置, 数据线接 8-bit 补码需要 +128 偏移 (或用双 DAC 差分)。
→ **方案见 §6 输出级**。

### 1.3 ADSR 状态机 (ym2413.c 第 191-216 行)

```
ym_update_env(state, cnt, step, sl, level):
  cnt += step
  if (cnt < step):        // 8-bit 溢出 (cnt += step 进位)
    cnt = 0
    switch(state):
      1 (attack):  level++; if(level>=31) state=2
      2 (decay):   level--; if(level<=sl) state=3
      3 (sustain): level--; if(level==0)  state=0   // STC 简化: 无真 sustain 保持
      4 (release): level--; if(level==0)  state=0

step = ym_rate_table[ar/dr & 0x0F]
ym_rate_table[16] = {0,1,2,3,4,6,8,12,16,24,32,48,64,96,128,255}
```

**关键: "cnt += step 溢出" 是时间基准**。step 越大溢出越快 → level 变化越快 → 包络越短。
attack (state=1) 和 decay (state=2) 用不同 step 值控制速度。

**硬件映射**:
- `cnt += step` → **HC283 加法** (复用 NCO 的加法器, 或独立)
- `cnt` 8-bit → HC174/HC273 锁存
- 溢出检测 → HC283 C4 进位输出
- `level++ / level--` → HC161 加减计数 (但 HC161 只能加, 用 32-complement 或 CD4029 可逆)
- 状态 (1/2/3/4) → 2-bit 寄存器 (HC174 两个 FF)
- step 查表 → conv_vol RAM 里存一份, 或参数 RAM 里存

→ **详见 §7 ADSR 实现**。

---

## 2. 整体架构 (继承 WSG8 + 新增 FM 层)

### 2.1 分层

```
┌─────────────────────────────────────────────────────┐
│ 接口层 (6 片, = WSG8, 不变)                           │
│ FT232H → LS373×2 → HC374(地址) → HC04+HC08+HC154    │
│   写参数到参数 RAM, 写 conv_vol 表, 写微码             │
└───────────────┬─────────────────────────────────────┘
                │ ADDR[7:0], D[7:0], CS_n, RST_n, data_strobe
                ▼
┌─────────────────────────────────────────────────────┐
│ TDM 引擎 (11 片, = WSG8 核心, 改步数/地址)             │
│ HC161×2 (HCNT) + 微码 RAM (62256) + HC00 + HC08×2   │
│   生成 TDM 步序列 + 子周期脉冲 (sub0/sub2/clk174...)  │
└───────────────┬─────────────────────────────────────┘
                │ HCNT[7:0], 微码控制信号
                ▼
┌─────────────────────────────────────────────────────┐
│ FM 运算层 (新增 8-10 片)                              │
│ ┌──────────┐  ┌──────────┐  ┌──────────┐            │
│ │参数RAM   │  │累加器    │  │conv_vol  │            │
│ │62256(W3) │  │HC283+174 │  │62256(F1) │            │
│ │freq/vol  │  │OP1+OP2   │  │sin×env   │            │
│ │/patch    │  │分时复用  │  │查表      │            │
│ └──────────┘  └──────────┘  └──────────┘            │
│      ↑              ↑              ↑                 │
│   HC157 mux     HC283 调制     HC157 地址 mux        │
│   (W7,W7b)      (F4)           (F7)                  │
└───────────────┬─────────────────────────────────────┘
                │ carrier[7:0], vol[3:0]
                ▼
┌─────────────────────────────────────────────────────┐
│ 输出+DAC (2 片 TLC7524, = WSG8)                       │
│ HC273 锁存 → TLC7524(波形) → TLC7524(音量级联)       │
└─────────────────────────────────────────────────────┘
```

### 2.2 和 WSG8 的继承/修改关系

| WSG8 组件 | FM6 处理 | 说明 |
|---|---|---|
| 接口层 6 片 | ✅ 完全不变 | FT232H 写入路径一样 |
| HC161×2 HCNT | ⚠️ 改步数 | WSG8 是 40 步(8ch×5), FM6 是 6ch×9步=54 步 (见 §3) |
| 微码 RAM 62256 (W2) | ⚠️ 改内容 | 微码序列变长 (54 步×4 子周期=216 地址) |
| 参数+累加 RAM 62256 (W3) | ⚠️ 改地址映射 | 参数加 patch/env, 累加器加 OP1+OP2 两组相位 (见 §4) |
| 波形 RAM 62256 (W4) | ❌ **删掉** | FM 不查波形表, 查 conv_vol 表 (F1 替代 W4) |
| HC283 加法器 (W4→F2) | ✅ 复用做 NCO | OP1 和 OP2 分时用 |
| HC174 carry (W5a) | ✅ 复用 | OP1/OP2 的 carry+phase 分时锁 |
| HC174 freq 锁存 (W5b) | ✅ 复用 | freq 和 step 锁存 |
| HC273 输出 (W6) | ✅ 复用 | 锁存 carrier + vol |
| HC157 地址 mux×2 (W7a/W7b) | ✅ 复用 | 参数/累加器 RAM 地址 mux |
| HC00 + HC08×2 仲裁时序 | ⚠️ 可能 +1 片 | 步数多, 脉冲多 |
| TLC7524×2 DAC | ✅ 完全复用 | 波形 DAC + 音量 DAC 级联 |

**净变化**: 删 W4 (波形 RAM), 加 F1 (conv_vol RAM) + F2-F8 (FM 运算)。

---

## 3. TDM 步序列 (核心 — 解决 handoff 待解决问题 #2)

### 3.1 每通道 9 步 (对应 ym_render 的 10 步运算, 合并优化)

```
步  动作                        子步  数据流
─────────────────────────────────────────────────────
0   读 step_m 到加法器 B        sub0  RAM[step_m_addr] → HC174(freq锁存)
1   OP1 累加: phase_m += step_m sub0 读 phase_m_lo, sub1 读 phase_m_hi
                                sub2 HC283 加法 (分 2 次: lo+lo, hi+hi+carry)
                                sub3 写回 phase_m
2   OP1 查 conv_vol             sub0 给地址 {env_m, phase_m[15:10]}
                                sub1 读出 mod_out → 锁存 HC174(F3)
3   反馈加法 (可选)             sub2 idx_m = phase_m[15:10] + fb_val
                                (fb=0 跳过此步, 直接用 phase_m[15:10])
4   读 step_c 到加法器 B        sub0  RAM[step_c_addr] → HC174(freq锁存)
5   OP2 累加: phase_c += step_c sub0-3 同步 1 (分时复用同一加法器)
6   相位调制: idx_c = phase_c + mod_out  sub2 HC283(F4) 加法
7   OP2 查 conv_vol             sub0 给地址 {env_c, idx_c}
                                sub1 读出 carrier → HC273(W6) 锁存
8   ADSR 更新 (轮询)            sub2 env_cnt += rate; 溢出则 level±1
                                (6 通道轮流, 每采样只更新当前通道)
```

### 3.2 为什么是 9 步不是 10 步

- ym_render 步骤 ③④ 合并: 取相位高位 + 加反馈, 一步内 HC283 做完 (反馈是常数, 预移位)
- 步骤 ⑥ (feedback 计算) 放在步 2 的查表后, 不单独占步 (mod_out 锁存后, fb_val 用
  HC164 移位或直接 wire 接 idx_m 加法器, 和步 3 合并)

### 3.3 HCNT 和采样率

```
6 通道 × 9 步 × 4 子周期 = 216 主时钟/采样
14.318MHz / 216 = 66.3kHz 采样率
Nyquist = 33.1kHz → 覆盖全人耳 (C8=4186Hz 远在内)

HCNT[7:0]:
  HCNT[7:3] = 通道内步号 + 通道号 (需要 6ch×9step=54, 但 6-bit=64 够)
    实际编码: step_total = ch×9 + step (0-53), 用 HCNT[7:3] 的 6-bit
    → 不对, 54 < 64 但 9 不是 2 的幂, 通道边界不能用纯位切片
    → 用比较器或 HC161 计数 + PE reload 在 54 回零

  ★ 简化方案: 接受 6ch×9step, 但 HCNT 用 ÷216 自然回绕 (接 256-216=40 的 gap)
    不行, 会导致采样率不均。
    → 用 PE reload: HCNT==215 时下一拍 PE=0 回零。215=0b11010111。
    检测: W1b.Q3=1,Q2=1,Q1=0,Q0=1, W1a 全 1(TC)。需要 5 输入比较。
    用 HC30 (8 输入 NAND, 库存有) 做, 或 HC08+HC00 组合。

  ★★ 更简: 6 通道 × 16 步 = 96 步 × 4 = 384 clk/采样。但浪费步。
      或: 把 9 步补齐到 16 步 (7 步 NOP), 采样率降到 14.318M/(6×16×4)=37.3kHz。
      Nyquist=18.6kHz, 够人耳到 ~18kHz。但浪费 44% 算力。

  ★★★ 决定: 用 9 步精确方案 + HC30 做 215 检测。理由: 采样率 66kHz 比 37kHz
        好太多, 而且 HC30 库存有, 不增成本。
```

**÷216 实现**:
```
HCNT = W1a(低4) + W1b(高4) = 8-bit 计数器
215 = 0xD7 = 1101_0111
检测: HCNT==215 → 用 HC30 (8-input NAND, 反相后 AND 全部位)
  HC30 输入 = 8 个 HCNT 位的反 (HC04 反相), 全 1 时 NAND 输出 0
  → /PE = NOT(HCNT==215) → 215 时 /PE=0, W1a/W1b 的 PE 有效
  PE reload 数据 = 全 0 (D0-D7 接 GND), 下一拍回 0

或更简单: 检测 TC 级联 + 低位。
  W1a 计满 (TC=1) → W1b 计数。W1b 到 13 (0b1101=215>>4) 且 W1a=0x7 时 reload。
  W1b==13: Q3Q2Q1Q0 = 1101, 用 HC08 (Q3 AND Q2 AND /Q1 AND Q0) + W1a.TC
```

> ⚠️ ÷216 的 reload 逻辑是 RTL 验证重点 #1。

---

## 4. RAM 地址空间 (3 片 62256, 解决 handoff 待解决问题 #1/#6)

### 4.1 W3: 参数+累加器 RAM (32K×8)

```
=== 参数区 (A14=0, CPU 写) ===
0x0000-0x005F  通道参数 (6ch × 16 字节, 留足空间)
  每通道 16 字节:
    +0: step_lo      (freq 低 8 位, ym2413 的 step=u16)
    +1: step_hi      (freq 高 8 位)
    +2: mul_m        (OP1 频率倍率, 0-7)
    +3: mul_c        (OP2 频率倍率, 0-7)
    +4: fb           (反馈档, 0-7)
    +5: vol          (音量 0-15)
    +6: patch        (音色号, 预留)
    +7: ar_m | dr_m  (attack/decay 速率索引, 各 4-bit)
    +8: ar_c | dr_c
    +9: sl_m | sl_c  (sustain level)
    +A: key | env_state_m | env_state_c  (控制位)
    +B-+F: 预留

0x0060-0x007F  ADSR 运行时状态 (6ch × 4 字节)
  每通道:
    +0: env_cnt_m    (OP1 包络计数器, 8-bit)
    +1: env_level_m  (OP1 包络电平, 0-31, 5-bit)
    +2: env_cnt_c    (OP2 包络计数器)
    +3: env_level_c  (OP2 包络电平)

=== 累加器区 (A14=1, TDM 读写) ===
0x4000-0x402F  NCO 相位 (6ch × 8 字节: phase_m_lo/hi + phase_c_lo/hi + carry + fb_val + mod_out + reserved)
  每通道 8 字节:
    +0: phase_m_lo   (OP1 相位低 8 位)
    +1: phase_m_hi   (OP1 相位高 8 位)
    +2: phase_c_lo   (OP2 相位低 8 位)
    +3: phase_c_hi   (OP2 相位高 8 位)
    +4: carry        (跨字节进位暂存)
    +5: fb_val       (反馈值, 8-bit 有符号)
    +6: mod_out      (OP1 查表输出, 暂存给相位调制)
    +7: reserved

0x4030-0x7FFF  空闲
```

**关键: phase 是 16-bit, 但 HC283 是 4-bit 加法器**。
和 WSG8 一样分 nibble 做, 但 WSG8 是 16-bit acc 分 4 个 nibble。
FM6 的 phase 也是 16-bit → 分 4 个 nibble 累加 (2 片 HC283 或分 4 次)。

→ **优化: 用 2 片 HC283 并联做 8-bit 加法** (W4 加法器 + F2 调制加法器, 不同时用)。
8-bit 加法 = 2 片 HC283 级联 (C0→C4)。
phase_m 16-bit = 2 次 8-bit 加法 (先 lo 后 hi+carry), 占 2 子步。

### 4.2 F1: conv_vol 查表 RAM (32K×8)

```
0x0000-0x07FF  conv_vol 表 (2048B = 32 levels × 64 indices)
  地址 = {env_level[4:0], sin_index[5:0]}  = 11-bit
  数据 = s8 有符号 (-31 ~ +31)

0x0800-0x0FFF  conv_vol 表副本 (带 +128 偏移, 给 DAC 用) ★可选
  如果 DAC 需要 0-255 无符号, 这里存 conv_vol[i] + 128

0x1000-0x7FFF  空闲 (可存多套波形变形, 预留)

CPU 初始化: 从 ym2413.c ym_conv_vol[32][64] 提取 2048 字节, 写入 0x0000-0x07FF。
```

**conv_vol 地址 mux (F7 HC157)** — 解决 handoff 问题 #6:

```
11-bit 地址 = {env_level[4:0], sin_index[5:0]}
  env_level 来源: OP1 步用 env_level_m, OP2 步用 env_level_c (5-bit)
  sin_index 来源: OP1 步用 phase_m[15:10], OP2 步用 idx_c (6-bit)

env_level 是 5-bit, sin_index 是 6-bit, 共 11-bit。
HC157 是 4-bit mux, 需要:
  F7 HC157 (env_level mux, 5-bit 要 2 片或 1 片 4-bit + 1 路余门)
    Select = is_op2 (微码信号: 当前是 OP2 步还是 OP1 步)
    A = env_level_m[4:0] (从参数 RAM 读)
    B = env_level_c[4:0]
    Y = env_level[4:0] → F1.A10-A6

  F7b HC157 (sin_index mux, 6-bit)
    Select = is_op2
    A = phase_m[15:10] (HC174 carry 寄存器输出, 或相位调制加法结果)
    B = idx_c[5:0] (相位调制加法器 F4 输出)
    Y = sin_index[5:0] → F1.A5-A0
```

→ **需要 2 片 HC157 做 conv_vol 地址 mux (F7 + F7b)**。

### 4.3 W2: 微码 RAM (32K×8) — 步序列控制

```
地址 = HCNT[7:0] (216 步 × 4 子周期 = 864 地址, 远小于 32K)
  A8-A14 = 页面 (可存多套微码程序, 切换音色算法)

每字节微码 8-bit:
  bit7 = clk_174_fm    (HC174 运算寄存器时钟: OP1/OP2 phase 锁存)
  bit6 = cp_273_out    (HC273 输出锁存: 步 7 carrier 输出)
  bit5 = is_op2        (conv_vol 地址 mux 选择: 0=OP1, 1=OP2)
  bit4 = we_acc        (累加器 RAM 写使能: NCO 写回)
  bit3 = ram_sel       (参数 RAM 区域: 0=freq/step, 1=phase 累加器)
  bit2 = we_conv       (conv_vol RAM 不写, TDM 只读; 此位预留给 ADSR 写)
  bit1 = oe_conv       (conv_vol RAM 输出使能: 查表步有效)
  bit0 = adsr_step     (ADSR 更新脉冲: 步 8 有效)
```

---

## 5. NCO 累加器 (OP1 + OP2 分时复用) — 解决问题 #2/#3

### 5.1 硬件: 2 片 HC283 + 1 片 HC174 (复用 WSG8 的 W4/W5a)

```
                ┌─────────────────────────────┐
  step_lo ──B──►│ HC283 #1 (W4)    C4 ────────┼──► carry → HC174
  phase_lo ─A──►│ 8-bit adder (2×HC283级联)   │
                │                  Σ[7:0] ────┼──► 写回 RAM (phase_lo)
  step_hi ──B──►│ HC283 #2 (F2)               │
  phase_hi ─A──►│ + carry_in from #1          │
                │                  Σ[15:8] ───┼──► 写回 RAM (phase_hi)
                └─────────────────────────────┘

HC174 (W5a): 锁存 carry + 相位高位 (phase[15:10] 给 conv_vol 地址)
  CLK = clk_174_fm (微码 bit7, 在累加步 sub2 上升沿)
```

### 5.2 OP1 vs OP2 分时

```
步 1 (OP1 累加):
  A 输入 = phase_m (从 RAM 累加器区读)
  B 输入 = step_m (从 RAM 参数区读)
  结果写回 phase_m

步 5 (OP2 累加):
  A 输入 = phase_c
  B 输入 = step_c
  结果写回 phase_c

→ 同一套 HC283+HC174, RAM 地址不同区分 OP1/OP2。
  freq 锁存 (W5b HC174) 在 sub0 锁存当前步的 step。
```

**mul_m 倍率处理**: ym2413 里 `step_m = step * mul_m`。
mul_m 是 0-7 的常数。硬件上不直接乘, 而是**预计算**:
CPU 写参数时, 把 `step × mul_m` 算好存进 RAM (step_m 字段)。
→ **硬件不需要乘法器, CPU 软件做乘法** (FT232H 控制)。

---

## 6. 相位调制 (FM 的本质) — 解决问题 #3

### 6.1 F4: 调制加法器 (HC283)

```
步 6 (相位调制):
  idx_c = (phase_c >> 10) & 0x3F    // 6-bit, 来自 HC174 相位输出
  idx_c += mod_out                   // mod_out 是步 2 查表锁存的 s8

F4 HC283:
  A[3:0] = phase_c[15:12] (HC174 输出, 取高 4 位 + 低 2 位拼 6-bit)
  B[3:0] = mod_out[7:4]   (HC174 F3 锁存的 OP1 输出高 4 位)
  → 只加高 4 位近似? 不行, 6-bit 精度不能砍。

★ 正确方案: 8-bit 加法 (2 片 HC283, 或复用 W4+F2):
  idx_c[7:0] = phase_c[15:8] + mod_out[7:0]   // 8-bit 加法
  sin_index = idx_c[7:2]                        // 取高 6 位 (>>2)
  → 这改变了 sin_index 的取法 (ym2413 是 >>10 取 6 位)

★★ 必须对齐 ym2413 的位宽:
  phase_c 是 16-bit, ym2413: idx_c = (phase_c >> 10) & 0x3F
  = phase_c 的 bit15..bit10 (高 6 位)
  mod_out 是 s8 (-31..+31), 直接加到 6-bit idx 上 (& 0x3F 模 64)

  硬件: 取 phase_c[15:10] (6-bit) + mod_out[5:0] (6-bit) → 7-bit 加法 → 取低 6 位
  用 1 片 HC283 (4-bit) 不够 (要 6-bit), 用 2 片 HC283 做 8-bit 加法取低 6 位。
  → 复用 W4 + F2 (NCO 加法器在步 6 空闲, 可复用做调制加法)。
```

**mod_out 暂存 (F3 HC174)**:
```
步 2 (OP1 查表): conv_vol RAM 输出 mod_out (s8)
  → F3 HC174 在 sub1 上升沿锁存 mod_out[7:0]
  → F3.Q 保持到步 6 (相位调制时用)
  → 步 7 (OP2 查表) 后 mod_out 不再需要

F3 HC174 (DIP-16, 8-bit 锁存, 只用 HC174 的 6 个 D):
  其实需要 8-bit, HC174 只有 6 个 D-FF。
  → 用 HC273 (8-bit) 或 2 片 HC174。
  → ★ 用 1 片 HC273 做 mod_out 锁存 (F3 改型号)。
  → 或: 复用 W6 HC273 输出锁存? 不行, W6 在步 7 才锁存, 步 6 要用 mod_out。
  → 结论: F3 用 HC273 (8-bit 锁存 mod_out)。
```

### 6.2 反馈 (fb) — 解决问题 #5

```
ym2413: fb_val = mod_out * fb >> 4  (fb=0..7)

16 个内置音色的 fb 分布:
  fb=0: 14 个 (几乎所有)
  fb=1: 1 个 (Synth)
  fb=3: 1 个 (Synth Bass, Synth ... 实际查表)

→ 实用档: fb=0 (跳过), fb=1 (idx_m += mod_out), fb=2 (idx_m += mod_out>>1), fb=3 (idx_m += mod_out + mod_out>>1)

硬件: fb 是 3-bit 参数, 存在参数 RAM。
  fb=0: 反馈加法器 B 输入 = 0 (HC157 mux 选 GND)
  fb=1: B 输入 = mod_out (直通)
  fb=2: B 输入 = mod_out >> 1 (右移 1 位, wire 接法: B[i] = mod_out[i+1])
  fb=3+: 砍掉或用查表近似

→ 用 HC157 (1 片) 做 fb 移位 mux: 选 GND / mod_out / mod_out>>1。
  → 这片 HC157 可以和 F7b (sin_index mux) 共享? 不行, 信号不同。
  → ★ fb 移位用 HC157, 但如果只支持 fb=0/1, 可以省掉 (fb=1 直接加 mod_out, fb=0 加 0)。
  → 决定: 第一版只支持 fb=0/1, 用参数 RAM 的 fb bit 控制 HC157 选 GND/mod_out。
     fb=1 时: 步 3 的相位调制加法 (idx_m = phase_m[15:10] + mod_out) 用 F4。
     fb=0 时: 跳过步 3, idx_m = phase_m[15:10] 直接送 conv_vol 地址。
```

---

## 7. ADSR 包络状态机 — 解决问题 #4

### 7.1 数据通路

```
步 8 (ADSR 更新, 每通道轮询):
  env_cnt += env_step     (8-bit 加法, 复用 HC283)
  if (carry_out):         (8-bit 溢出)
    env_cnt = 0
    switch(env_state):
      attack:  env_level++
      decay:   env_level-- (到 sl 停)
      sustain: env_level-- (到 0 停)
      release: env_level-- (到 0 停)
```

### 7.2 硬件实现

```
F5: HC161 (env_cnt, 8-bit 计数器, 2 片级联)
  CP = adsr_step 脉冲 (微码 bit0, 步 8 的 sub2)
  CET/CEP = env_state != 0 (活跃时才计数)
  TC (溢出) → 触发 env_level 更新

F6: env_level 存储
  env_level 是 0-31 (5-bit), 需要加减。
  HC161 只能加。方案:
  a) 用 CD4029 (可逆计数器, 库存有!) → 5-bit 要 2 片级联
  b) 用 HC161 + 32-complement: level-- = level + 31 (mod 32)
  c) 用 HC174 锁存 + HC283 加法 (level += ±1, 补码)

  → ★ 用 CD4029 (可逆, 库存确认有):
     F6a CD4029 (低 4 位), F6b CD4029 (高位, 只用 1 位)
     U/D = env_state==1 (attack 时加, 其他减)
     PE = 溢出脉冲 (F5 的 TC)
     D = attack: 00001 (+1), decay/release: 11111 (-1, = +31 mod 32)
     → D 输入用 HC157 mux 选 +1/-1 (由 env_state 控制)

F6b_alt: env_state 寄存器 (2-bit, HC174 两个 FF)
  state[1:0]: 1=attack, 2=decay, 3=sustain, 4=release (编码 00-11)
  状态转换:
    attack → decay: level==31
    decay → sustain: level==sl (比较器, 用 HC283 减法看零标志)
    sustain → idle: level==0
    release → idle: level==0
```

### 7.3 env_step 查表

```
env_step = ym_rate_table[ar/dr & 0x0F]
ym_rate_table[16] = {0,1,2,3,4,6,8,12,16,24,32,48,64,96,128,255}

→ 16 字节表, 存在参数 RAM 里 (CPU 写入), 或存在 conv_vol RAM 空闲区。
→ env_state==1 (attack) 时读 ar, env_state==2 (decay) 时读 dr。
→ HC157 mux 选 ar/dr (由 env_state bit 控制)。
```

### 7.4 env_level → conv_vol 地址

```
env_level[4:0] → conv_vol 地址高 5 位 (F1.A10-A6)
  OP1 用 env_level_m, OP2 用 env_level_c
  → F7 HC157 mux (§4.2) 选 m/c
```

---

## 8. 输出级和 DAC (符号处理)

### 8.1 conv_vol 数据是有符号 s8, TLC7524 需要无符号

```
conv_vol 范围: -31 ~ +31 (s8)
TLC7524 数据: 0-255 (无符号), VO = VREF × D/256

方案 A (偏移二进制):
  存表时 +128: conv_vol_dac[i] = conv_vol[i] + 128 → 97~159
  DAC 输出在 VREF × 128/256 = 中点 (直流偏置)
  → 耦合电容隔直, 取交流分量
  → ★ 简单, 推荐。F1 RAM 存两套: 0x0000 原始 (运算用), 0x0800 偏移 (DAC 用)

方案 B (双 DAC 差分):
  conv_vol 正值送 DAC1, 负值送 DAC2, 差分输出
  → 浪费 DAC, 不推荐

方案 C (REF 交流偏置):
  REF 接 2.5V 直流偏置, 数据 0-255 中 128 = 零点
  → = 方案 A 的变体

→ 决定: 方案 A, F1 存偏移版本 (0x0800-0x0FFF), 查表输出直接送 HC273 → DAC。
  运算用的原始表 (0x0000-0x07FF) 给相位调制加法用 (mod_out 需要有符号)。
```

### 8.2 输出缩放

```
ym2413: mix += carrier × (16-vol) >> 2

→ carrier 是 s8 (-31~+31), vol 是 0-15。
→ 缩放 = carrier × (16-vol) / 4

硬件: 用 TLC7524 级联 (和 WSG8/PSG 一样):
  DAC1 (W9): carrier[7:0] → DB0-7 (8-bit 波形)
  DAC2 (W10): (16-vol)[3:0] → DB4-7 (4-bit 音量衰减)
  DAC2.REF = DAC1.OUT → 级联乘法
  → 输出 = carrier × (16-vol) / 256 × 缩放系数

  (16-vol) 是 1-16, 4-bit 只能表 0-15, vol=0 时 16-vol=16 溢出。
  → 实际用 vol[3:0] 取反: dac_vol = ~vol = 15-vol, 范围 0-15。
  → 输出 ≈ carrier × (15-vol) / 256。和 ym2413 差 4× 增益, 可接受 (运放放大)。

  >>2 的除 4: TLC7524 级联本身有 /256, 再加运放增益调整。
  → 不需要额外移位硬件, 运放电阻比搞定。
```

### 8.3 混音 (6 通道累加)

```
ym2413: 所有通道 mix 累加到一个 s16。

硬件: WSG8 架构是**分时复用单 DAC**, 每通道轮流输出到 HC273。
6 通道在同一采样周期内分时占用 DAC, 输出是脉冲序列, 低通滤波后自然叠加。

→ 不需要硬件加法器做混音, DAC 分时输出 + 低通滤波 = 混音。
→ 和 WSG8 的 8 通道混音一样。
```

---

## 9. 芯片清单 (修订: 26 片)

### 9.1 复用 WSG8 (18 片, 删 W4 波形 RAM)

| 位号 | 型号 | 功能 | 改动 |
|---|---|---|---|
| U0a/b | LS373×2 | 电平转换 | 不变 |
| U1 | HC374 | 地址锁存 | 不变 |
| U10 | HC04 | 反相器 | 不变 |
| U11 | HC08 | 接口逻辑 | 不变 |
| U12 | HC154 | 区域译码 | 不变 |
| W1a/b | HC161×2 | HCNT 计数器 | ÷216 改 |
| W2 | 62256 | 微码 RAM | 内容改 |
| W3 | 62256 | 参数+累加 RAM | 地址映射改 |
| ~~W4~~ | ~~62256~~ | ~~波形 RAM~~ | **删除** (被 F1 替代) |
| W4 | HC283 | NCO 加法器 | 复用 (OP1+OP2 分时) |
| W5a | HC174 | carry/phase | 复用 |
| W5b | HC174 | freq/step 锁存 | 复用 |
| W6 | HC273 | 输出锁存 | 复用 |
| W7a/b | HC157×2 | 参数 RAM 地址 mux | 复用 |
| W8 | HC00 | 仲裁 | 改 (3 片 RAM 的 /OE /WE) |
| W8b | HC08 | 时序控制 | 改 (步数多) |
| W9/W10 | TLC7524×2 | DAC | 不变 |

**复用小计**: 6(接口) + 11(核心, 含 W1×2) - 1(删 W4 RAM) + 2(DAC) = **18 片**

### 9.2 FM 新增 (8 片)

| 位号 | 型号 | 功能 | 解决的问题 |
|---|---|---|---|
| F1 | 62256 | conv_vol 查表 RAM | #1 conv_vol 存储 |
| F2 | HC283 | NCO 高位加法 (和 W4 级联做 8/16-bit) | NCO 精度 |
| F3 | HC273 | mod_out 锁存 (8-bit, OP1 输出暂存) | #3 相位调制数据暂存 |
| F4 | HC283 | 相位调制加法 (idx_c + mod_out) | #3 FM 调制核心 |
| F5 | HC161 | ADSR env_cnt 计数器 | #4 ADSR 计时 |
| F6 | CD4029×2 | env_level 可逆计数 (OP1+OP2 各 1 套) | #4 env_level 存储 |
| F7 | HC157 | conv_vol 地址 mux (env_level + sin_index) | #6 地址拼接 |
| F8 | HC08 | 时序控制扩展 (更多步脉冲) | 步数多 |

> F6 用 2 片 CD4029 (可逆计数器), 算 2 片。
> 如果 OP1/OP2 共享 env_level 计数器 (分时), 可省 1 片 → 25 片。
> 但 OP1/OP2 包络独立 (不同 ar/dr), 共享要分时切换, 复杂度高。第一版用 2 片。

### 9.3 合计

```
复用 WSG8:  18 片 (删了 W4 波形 RAM)
FM 新增:     8 片 (F1-F8, F6 算 2 片 CD4029)
─────────────────
总计:       26 片

(交接文档预估 27 片, 实际 26 片 — 删了 W4 波形 RAM)
```

**全部芯片库存确认**: 62256 ✅ HC283 ✅ HC174 ✅ HC161 ✅ HC273 ✅
HC157 ✅ HC08 ✅ CD4029 ✅ TLC7524 ✅ — 全在 inventory.md 里。

---

## 10. 上电引导序列

```
1. RST_n=0, TDM 停止
2. CPU 写 conv_vol 表到 F1 (0x0000-0x07FF, 2048B)
   - 数据: 从 ym2413.c ym_conv_vol[32][64] 提取
   - 写偏移版本到 0x0800-0x0FFF (DAC 用, +128)
3. CPU 写微码到 W2 (216 步 × 4 子周期 = 864B)
   - 微码内容: 按 §4.3 的 bit 定义生成
4. CPU 写通道参数到 W3 参数区 (6ch × 16B = 96B)
   - step/mul/fb/vol/ar/dr/sl/env_state
5. CPU 写 ADSR rate_table (16B) 到 W3 或 conv_vol RAM 空闲区
6. RST_n=1, TDM 开始运行
7. 运行中 CPU 写参数 RAM 改频率/音量/包络 (不停 TDM)
8. Key On/Off: CPU 写 env_state=1 (attack) 或 env_state=4 (release)
```

---

## 11. RTL 验证计划

### 11.1 验证重点 (优先级排序)

1. **÷216 HCNT 计数器** (§3.3): PE reload 在 215 回零, 采样率 66.3kHz
2. **OP1 NCO 累加**: phase_m += step_m, 16-bit, 分 nibble
3. **conv_vol 查表**: 地址 {env_level, sin_index} → 数据 mod_out
4. **相位调制**: idx_c = phase_c[15:10] + mod_out, 6-bit 模 64
5. **OP2 查表 + 输出**: carrier → HC273 → DAC
6. **ADSR 状态机**: env_cnt 溢出 → env_level ±1, 状态切换
7. **6 通道分时**: HCNT 译码选通道, 参数/累加器地址正确

### 11.2 单通道最小验证 (先跑通 1 通道)

```
RTL: fm6_core.v (先实例化 1 通道, 不做 TDM 分时)
tb:  fm6_note_tb.v
  - 固定 step_m=某值 (对应 A4=440Hz)
  - 固定 env_level_m=31, env_level_c=31 (满包络)
  - 固定 fb=0
  - 观察 phase_m/phase_c 波形 + conv_vol 查表输出
  - 写 WAV 试听: 应该是 FM 音色 (carrier 被调制, 有泛音)
```

### 11.3 WAV 试听验证

```
和 PSG/WSG 一样:
  - 仿真输出按 66.3kHz 采样写 WAV
  - 试听: 纯正弦 (fb=0, 无调制) → 单音
         FM (fb=1 或 mod_out 大) → 有泛音的 FM 音色
  - 对比 ym2413.c 软件仿真的输出 (同一 conv_vol 表, 同一参数)
```

---

## 12. 和 ym2413.c 的差异 (简化项)

| ym2413 特性 | FM6 实现 | 理由 |
|---|---|---|
| 9 通道 (6旋律+3鼓) | 6 旋律 | 鼓用 PSG3 噪音, FM 专注旋律 |
| mul_m/mul_c 倍率 | CPU 预乘后写入 | 硬件不乘法, step_m = base_step × mul |
| fb 0-7 | fb 0/1 (第一版) | 14/16 音色用 fb=0, 1 个用 fb=1 |
| 15 内置音色 | RAM 参数表 (CPU 写入) | 音色 = 参数组, 不固化 |
| sustain (state 3) 保持 | STC 简化: sustain 也 decay 到 0 | 和 ym2413.c 一致 (STC 就这么干的) |
| ticks 多次累加 | 每采样 phase += step (单次) | 采样率 66kHz > ym2413 的 49.7kHz, 不需要 ticks 补偿 |
| mix 累加 s16 | DAC 分时 + 低通滤波 | 硬件混音, 不加法器 |

---

## 13. 待解决问题清单 (handoff 6 个问题的方案总结)

| # | handoff 问题 | 本文档方案 | 章节 |
|---|---|---|---|
| 1 | conv_vol RAM 写入 | CPU 初始化时写 F1 (同 WSG8 波形写入), 2048B 从 ym_conv_vol 提取 | §4.2 §10 |
| 2 | OP1/OP2 共享 TDM 步序列 | 9 步/通道: OP1(步0-3) + OP2(步4-7) + ADSR(步8), 同一加法器分时 | §3 §5 |
| 3 | 相位调制 mod_out 暂存 | F3 HC273 锁存 mod_out, F4 HC283 做 idx_c+mod_out 加法 | §6 |
| 4 | ADSR 状态机 | F5 HC161(env_cnt) + F6 CD4029(env_level 可逆) + 2-bit state 寄存器 | §7 |
| 5 | 频率倍率 mul_m/c | CPU 预乘, 硬件不乘法; fb 移位用 HC157 (第一版只 fb=0/1) | §5.2 §6.2 |
| 6 | conv_vol 地址 mux | F7 HC157×2: env_level(5-bit) + sin_index(6-bit) 拼 11-bit | §4.2 |

---

## 14. 下一步

1. [ ] **C 仿真器** (fm6_sim.c): 移植 ym_render() 到纯 C, 验证 conv_vol 查表 + 相位调制 + ADSR,
        输出 WAV 和 ym2413.c 对比 (确认算法移植正确)
2. [ ] **conv_vol hex 生成**: 从 ym2413.c ym_conv_vol[32][64] 提取 2048B + 偏移版本
3. [ ] **微码生成** (gen_microcode.py): 按 §4.3 bit 定义生成 864B 微码
4. [ ] **RTL**: fm6_core.v (先 1 通道, 再 6 通道 TDM)
5. [ ] **tb**: fm6_note_tb.v + WAV 试听
6. [ ] **接线表** (26 片逐脚)
7. [ ] 上板验证
