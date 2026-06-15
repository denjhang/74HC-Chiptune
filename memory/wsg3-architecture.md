---
name: wsg3-architecture
description: WSG3 功能等效架构 - 按芯片类型实现 Pac-Man WSG 行为 (3M=微码ROM, 1M=波形ROM, 14 IC, TDM 16 步)
metadata:
  type: project
---

## 设计原则 (用户 2026-06-15 确认)

> **"按 verilog 做功能等效, 不纠结原版网表"**

不再追求 PADS.net 引脚级 1:1 复刻 (那是死胡同, 174 反馈环 + 157 Select=2H 把架构卡死).
正确做法: 按芯片**类型**保留 14 片 IC, 按**技术文档描述的功能行为**接线.

**Why**: 原版 1980 板用了 Signetics 08282 定制 IC + 82S126 PROM, 现代 74HC 复刻无法逐针复现;
但功能行为 (TDM 多通道、相位累加、波形查表、音量乘法) 可以用标准 74HC 等效.

**How to apply**:
1. 芯片类型清单严格保留 (11 WSG + 3 SPFM = 14 IC)
2. 每片 IC 实例化, 但端口连接按技术文档 Verilog 示例来, 不照搬 PADS.net 引脚号
3. 隐藏门规则不变: 所有布尔操作必须在显式 IC 实例里

---

## 14 片 IC 清单 (类型保留, 功能等效)

**SPFM (3)**: 373 + 174 + 377 — 主机写 voice 参数
**WSG 核心 (11)**:
- U2 = 74HC86 (XOR, 生成 mux Select)
- U3 = 39SF040 (**3M 微码 ROM**, 16 步 × 16-bit)
- U4 = 74HC157 (AB mux: CPU addr / HCNT)
- U5 = 74HC158 (DB 反相 mux: CPU data / acc 反馈)
- U6 = 74LS189 (**acc RAM**, 累加器值 4-bit × 16)
- U7 = 74LS189 (**freq/vol RAM**, 4-bit × 16)
- U8 = 74HC283 (4-bit 加法器, time-shared 串行)
- U9 = 74HC174 (6-bit 累加器锁存 + 进位链)
- U10 = 39SF040 (**1M 波形 ROM**, 8 波 × 32 点 × 4-bit)
- U11 = 74HC273 (输出锁存)
- U12 = CD4066 (4 路模拟开关, 音量乘法)

---

## 3M 微码字 16-bit 位定义

来自技术文档 `reference/Namco WSG/Pac-Man技术文档_extracted/document_text.txt`:

| bit 段 | 含义 |
|--------|------|
| `[15:12]` | 1M ROM 控制 |
| `[11:8]`  | 273 CP 控制 |
| `[7:4]`   | 174 /CLR 控制 |
| `[3:0]`   | 174 CLK 控制 |

**16 步循环 (HCNT[5:2])**:
- 步 0-4: ch0 相位累加 (5 次, 因为 20-bit)
- 步 5: ch0 输出 (`1011_1111_1111_1111`)
- 步 6-9: ch1 相位累加 (4 次, 16-bit)
- 步 A: ch1 输出
- 步 B-E: ch2 相位累加
- 步 F: ch2 输出

累加步微码: `1101_1110_1111_0111` (清零开始) / `1101_1110_1111_1111` (持续)
输出步微码: `1011_1111_1111_1111`

---

## 关键算法 (技术文档 Verilog 直接引用)

### 加法器 + 累加器 (time-shared)

```verilog
wire [5:0] sum_1K = acc_dout + freq_dout + carry_chain[5];

always @(posedge u3_dq[0] or negedge u3_dq[3]) begin
    if (!u3_dq[3]) carry_chain <= 0;
    else carry_chain <= {sum_1K, carry_chain[3]};
end
```

每次锁存把新加法结果 (5-bit: 4-bit 和 + 1-bit 进位) 拼进累加器, 串行 4-5 次完成 16/20-bit 累加.

### 1M 波形 ROM 地址

```verilog
assign rom1m_addr[7:5] = acc_dout[2:0];   // 波形号 (0-7)
assign rom1m_addr[4:0] = carry_chain[4:0]; // 相位高 5 位 (32 样本/波)
```

---

## CPU 寄存器映射 (Pac-Man 地址空间)

| 地址 | RAM 字 | 含义 |
|------|--------|------|
| 0x40-0x44 | U6[0-4] | ch0 累加器 (H/W only) |
| 0x45      | U6[5]   | ch0 波形号 (低 3-bit) |
| 0x46-0x49 | U6[6-9] | ch1 累加器 |
| 0x4A      | U6[A]   | ch1 波形号 |
| 0x4B-0x4E | U6[B-E] | ch2 累加器 |
| 0x4F      | U6[F]   | ch2 波形号 |
| 0x50-0x54 | U7[0-4] | ch0 频率 (20-bit) |
| 0x55      | U7[5]   | ch0 音量 |
| 0x56-0x59 | U7[6-9] | ch1 频率 (16-bit) |
| 0x5A      | U7[A]   | ch1 音量 |
| 0x5B-0x5E | U7[B-E] | ch2 频率 |
| 0x5F      | U7[F]   | ch2 音量 |

---

## A4 = 440Hz 测试向量

频率值 = `0x12C6` (20-bit), 写到 0x50-0x54:
- 0x50 ← 6, 0x51 ← C, 0x52 ← 2, 0x53 ← 1, 0x54 ← 0

音量 0xF → 0x55, 波形 0 (sine) → 0x45.

采样率 96kHz, sine 32 样本/周期, 每秒需要 440×32 = 14080 样本.
`2^15 / (96000/14080) ≈ 4806 = 0x12C6`.

---

## 相关文件

- 设计文档: `wsg3/docs/wsg3-architecture.md`
- 技术文档: `reference/Namco WSG/Pac-Man技术文档_extracted/document_text.txt`
- 网表参考: `reference/Namco WSG/easyeda/PADS.net`
- 原 ROM 数据: `reference/Namco WSG/rom/82s126.1m`, `82s126.3m`

参见: [[wsg3-core-status]] 当前实现状态, [[rom-39sf040-only]] ROM 硬规则
