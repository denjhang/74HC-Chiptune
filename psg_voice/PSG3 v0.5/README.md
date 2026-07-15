# PSG3 v0.5 — 三通道波形音源 (方波 + 噪音 + 任意波形/PCM)

> v0.5 = v0.4 (方波 + 噪音) **原样保留** + **新增波形通道** (rev.a→e2 架构演进).
> 三通道并存, 各自独立 TLC7524 输出, 寄存器 reg0/1/2 (v0.4) + reg3/4/5 (波形, 新增).
> clk: 方波/噪音 = 64kHz 预分频, 波形通道 = 4MHz 直连.

---

## 状态总览 (2026-07-15)

| 部分 | 状态 | 说明 |
|------|------|------|
| 接口层 (YM2413 总线) | ✅ 上板 (v0.4) | A0/CS/WR, 8 寄存器独热码, FT232H 12 线 |
| 方波通道 CH0 | ✅ 上板 (v0.4) | 占空比 4 挡 + mode + ref 调制 |
| 噪音通道 CH1 | ✅ 上板 (v0.4) | LFSR + 模拟噪声注入, 独立/绑定模式 |
| 波形通道 CH2 rev.a | ✅ 上板 (2026-07-14) | HCT74 分频链锯齿波, 4-bit/5-bit 干净 |
| 波形通道 rev.b | ❌ 失败 | XOR 折返三角, 锯齿泛音 |
| 波形通道 rev.c | 📋 设计完成 | rev.a + HC86 占空比调音 + CD4066 RC 滤波, 未上板 |
| 波形通道 rev.d | 📋 待上板 | ROM 查表 256 点, 256 种任意波形 |
| 波形通道 rev.d2 | 📋 仿真通过 | ROM 查表 64 点, 高音精度版 |
| **波形通道 rev.e2** | 📋 **接线表完成** | 双模式: 16 波形 + 16 PCM 采样 |

⭐ **当前最新进度 = rev.e2** (接线表 + ROM + 驱动完成, 待上板).

---

## 波形通道架构演进 (rev.a → e2)

完整发现记录: [`docs/findings-2026-07-14.md`](docs/findings-2026-07-14.md)

```
v0.5 原版 (CD4029 波形计数器)
    ↓ ❌ 失败 (CMOS 4MHz Q2-4 噪音, 高频不用 CD 系列)
HC161 Q 直接进 DAC
    ↓ ❌ 失败 (Q 是分频抽头 Q0=clk/2..., 不是同步计数值; HC273 救不了)
rev.a (HCT74 分频链叠加: tc_hi→÷2→÷4→÷8 → DB4-7)
    ↓ ✅ 成功 (锯齿波, CS=clk 同步采样, 2026-07-14 上板)
rev.b (分频链 + HC86 XOR 折返)
    ↓ ❌ 失败 (三角带锯齿泛音, 抽头相位不同步)
rev.c (rev.a + HC86 占空比调音 + CD4066 RC 滤波)
    ↓ 📋 设计完成, 未上板
rev.d (HC161 地址计数器 → ROM → DAC, 256 点)
    ↓ 📋 真 8-bit 任意波形, reg5 全 8 位选 256 种, 待上板
rev.d2 (ROM 64 点, 高音精度)
    ↓ 📋 仿真通过, 待上板
rev.e2 (双模式: 16 波形 + 16 PCM 采样)
    ↓ 📋 接线表完成, 待上板
```

**核心铁律 (全部上板验证)**:
1. 高频 (≥1MHz) 不用 CD 系列 — CD4029 4MHz 噪音.
2. HC161 的 Q 是分频抽头, 不能直 DAC — 直接进 = 白噪/音色循环.
3. HC161 的 Q/TC 可直连任何 TTL (级联/ROM/地址计数器), 不需整形.
4. "TC 必须整形" 只针对 Q→DAC 方案 (生成纯净方波叠加锯齿), 不泛化.
5. ROM 直连 DAC + CS=clk 同步采样, 无需 HC273 (rev.d 验证稳定).

---

## rev.e2 — 双模式波形/采样通道 (最新)

**16 波形 (mode=0) + 16 PCM 采样 (mode=1)**, 12 片芯片 (U1-U12).

```
reg5: bit7=mode, bit6=trig, bit3-0=sel[3:0]
         │
         ▼
U1-U3 HC161×3 (period12) → freq_tc
                              │
U4-U6 HC161×3 (地址 a0-a11) ← step (U8 门4: freq_tc AND ~at_8191)
   ↘ U7 HCT74 (a12 toggle)
         │ a0-a12 + sel0-3
         ▼
U10 SST39SF010 ROM (128K = 16 槽 × 8K) → d0-7
         │
U11 TLC7524 (CS=clk) → U12 TLC7524 (vol) → 喇叭

U8 HC08 (4门: tc_pcm/trig_clr/at_8191/step)
U9 HC04 (2门: n_trig_clr/n_at8191)
```

- **波形模式** (mode=0): U6 冻结 (tc_pcm=0), a8-12=0, ROM 读每槽前 256 字节.
- **采样模式** (mode=1): U6 级联, a0-a12 连续跑 0-8191, 单次播放到 8191 自动停 (step=0).
- 详见 [`docs/wiring-table-rev-e2.md`](docs/wiring-table-rev-e2.md) (五列接线表, U1-U12).

---

## 目录结构

```
PSG3 v0.5/
├── README.md                 # 本文件
├── docs/
│   ├── handoff.md            # 交接文档 (注意: 开头还停留在 v0.5 原版描述, 以本 README 为准)
│   ├── findings-2026-07-14.md # ⭐ 上板发现全记录 (CD4029/HC161 Q/分频链/XOR 折返)
│   ├── bus-write-timing.md   # FT232H 总线时序 (A0/CS 在 WR=0 切换, WR↑锁存)
│   ├── inventory.md          # 芯片库存表
│   ├── wiring-table-rev-e2.md # ⭐ 最新接线表 (五列, U1-U12)
│   ├── wiring-table-rev-d.md / -d2.md / -e.md  # 旧版接线表 (参考)
│   ├── wiring-table-rev-a.md ~ -c.md           # rev.a-c 接线表
│   ├── wiring-table-bus.md / -noise.md / -prescaler.md / -uni.md
│   └── wavetable-rev-d-list.md
├── host/                     # Python 驱动 + ROM 生成
│   ├── psg3_rev_d_test.py / psg3_rev_d2_test.py / psg3_rev_e_test.py
│   ├── gen_rev_d_rom.py / gen_rev_d2_rom.py / gen_rev_e_rom.py
│   ├── rev_d_wavetable.bin / rev_d2_wavetable.bin / rev_e_rom.bin
│   └── uni_period_table.h
├── rtl/                      # Verilog
│   ├── psg3_top.v            # 顶层 (总线 + 三通道)
│   ├── rev_d2/psg3_rev_d2_top.v
│   └── rev_e/                # rev_e_inst.v / rev_e_top.v / rev_e_rom_init.hex
├── tb/                       # testbench + WAV 试听
├── pcm/                      # PCM 采样源 (drum/ins)
└── sch/                      # 原理图 (PSG4-v0.52 Schematic + Noise netlist)
```

---

## 寄存器

```
reg0 (0x01): 方波 period[7:0]              ← v0.4
reg1 (0x02): 方波 vol[3:0]/duty[4-5]/mode[6]/ref[7]  ← v0.4
reg2 (0x04): 噪音 vol[3:0]/freq[4-5]/bind[6]         ← v0.4
reg3 (0x08): 波形 period12[7:0]            ← v0.5 新增
reg4 (0x10): 波形 period12[11:8]<<4 | vol[3:0]
reg5 (0x20):
  rev.d:  wave_sel[7:0] (256 种波形)
  rev.e2: bit7=mode, bit6=trig, bit5-4=预留, bit3-0=sel[3:0]
```

---

## 与 v0.4 的关系

**v0.4 是已定案版本 (已上板验证), v0.5 不改 v0.4 任何文件.**
- v0.4 的 RTL/docs/host 全部保持原样 (在 `PSG3 v0.4/` 目录).
- v0.5 把 v0.4 的方波 + 噪音**原样合入** v0.5 顶层 + 新增波形通道.
- 寄存器: reg0/1=方波, reg2=噪音, **reg3/4/5=波形** (新增, 避开 v0.4 地址).

详见 [`PSG3 v0.4/docs/handoff.md`](../PSG3%20v0.4/docs/handoff.md).

---

## 后续方向 (设计思路, 未验证)

- rev.e2 PCM 采样模式上板验证.
- 极简 CPU (只做指令/数据路由, 运算全用专用硬件) — 相比 miniglow/Glowworm 更精简.
- PSG4 v0.6 / WSG3 v0.6 / FM6 v0.7 — 纯设计阶段, 无硬件验证.
