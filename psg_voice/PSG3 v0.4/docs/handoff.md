# PSG3 v0.4 交接文档

> PSG3 v0.4 = YM2413 风格地址/数据复用总线 + 方波/噪音两通道 + VGM 预录制播放器
> 交接时间：2026-07-08
> 状态：**总线协议 + 两通道 + 驱动全部上板验证，播放器功能完成**

## 一句话现状

PSG2 v0.3 的"每寄存器一根选通线"模式到极限（FT232H 12 根线用满）。PSG3 v0.4 仿 YM2413，把地址和数据复用到 8 位总线，A0 区分地址/数据，/CS 做事务保护，地址空间从 4 个寄存器扩到 8 个（独热码，无译码器）。**FT232H 物理接线零增减**（仍 12 根线），只改控制线语义。方波 + 噪音两通道挂总线全部上板出声。播放器支持 VGM 式预录制（dump 成事件流回放）、噪音乐器（鼓组）、方波乐器（音色切换）、范围循环。

---

## 🎯 PSG3 完成清单

### 接口层（YM2413 总线，独立 13 片）✅ 上板验证通过

- **8 位总线复用**（地址+数据），A0/WR/CS/RST 4 线控制
- **独热码地址一对一选通** 8 个 HC374 寄存器（reg0-reg7），无译码器
- **/CS 事务保护**消除"短暂地址值"中间态（两拍写一次完整事务，无歧义）
- **HC374 边沿地址锁存**（不用 HC373 透明，避免组合竞争）
- 选通逻辑：`addr_cp = NOT(/CS)·NOT(A0)·/WR`，`data_strobe = NOT(/CS)·A0·/WR`，`reg_cp[n] = ADDR[n]·data_strobe`
- 接口层独立芯片，不借门给通道层（调试隔离）

### 方波通道 CH0（照抄 PSG2 v0.3）✅ 上板验证通过

- reg0(0x01) = period，reg1(0x02) = 控制（音量 bit0-3 / 占空比 bit4-5 / mode bit6 / ref bit7）
- 占空比 4 挡、mode 方波/白噪、ref 占空比变体/Q0 调制
- **占空比补偿默认全 0**（8-bit period 精度有限，补偿引入额外量化误差）

### 噪音通道 CH1（照抄 PSG2 v0.3 rev.a）✅ 上板验证通过

- reg2(0x04) = 控制（音量 bit0-3 / 频率挡 bit4-5 / 绑定 bit6）
- HC374 LFSR + 模拟注入防锁死（HC00 门3 + 2×0.1μF 张弛振荡器）
- 独立模式 4 挡（÷2/÷4/÷8/÷16）全部实用

### 播放器（VGM 预录制 + 乐器系统）✅ 完成

- **VGM 式预录制**：dump 成 `[(time_ms, port, data)]` 事件流，回放按时间戳写硬件
- **噪音乐器**（`[noise_N]` 块）：名称/音量包络/step/模式/频率挡
- **方波乐器**（`[square_N]` 块）：mode/wave/duty/octave_shift/volume，切换保持直到下次切换
- **双轨并行**：方波行/鼓点行各自时间轴，音长统一 = beats × beat_t
- **按 ini 物理行打印**：方波行/鼓点行各自换行，边播边打
- **范围循环**：`--song N-M` 循环播 N 到 M

---

## ⭐ 核心认知（2026-07-08 上板深化）

### 1. YM2413 协议 = 两次写入一次完整事务

真实 YM2413（核对 `Reference_Project/megagrrl-driver-revamp-2-20240226-saa/firmware/main/driver.c` Driver_FmOutopl3）：
- /CS 整个事务期间常低（事务边界，不参与 CP 逻辑）
- /WR 地址拍/数据拍各脉冲一次，A0 区分
- **PSG3 硬件能完美跑 OPLL 驱动时序**（tb/psg3_bus_tb.v 的 bus_write_opll 验证，0 错误）

### 2. /OE 不能省 CP 选通逻辑

HC374 的 /OE 只控输出三态，不控锁存。若所有数据 374 的 CP 直接连 /WR，地址拍 /WR↑ 时所有 374 锁到地址值（污染）。**CP 必须是 `ADDR[n] AND data_strobe`**，8 个与门（3 片 HC08）省不掉。/OE 的真正价值在后续 SCC 阶段（寄存器 Q 并到回读总线做三态隔离）。

### 3. A0/CS 跳变必须在 WR=0 期间

`addr_cp = cs&a0_n&wr`，`data_strobe = cs&A0&wr`——任何让 strobe 从 0→1 的跳变都是锁存触发。A0/CS 在 WR=1 时跳变会误锁存到错误值（总线此时是上一个数据）。**所有 A0/CS 跳变都在 WR=0 期间**，WR 上升沿只在 A0/CS 稳定后给出。

---

## 🔧 上板踩坑（design.md 7.2 节，下个窗口必读）

1. **噪音 HC00 振荡器必须独立芯片**（串扰方波 /PE → 频率抖动）
2. **噪音绑定 tc_hi 须经 HC00 反相隔离**（反向干扰方波）
3. **占空比分频链必须 HCT74**（国产 HC74 toggle 失效，第三次踩坑）
4. **驱动 _bus_write 必须 MPSSE 批量打包**（逐条发 + sleep 太慢，ADSR 卡顿 + 噪音频率挡失效）
5. **A0/CS 跳变必须在 WR=0 期间**（避免 strobe 误上升沿 → 频率抖动 + 占空比失效）

---

## 📋 播放器使用

### ini 格式

```ini
; 噪音乐器 (鼓组)
[noise_1]
noise_ins_name = bd              乐器名
noise_volume = 15,13,10          音量包络
noise_step = 0.1s                包络步进 (不影响音长)
noise_mode = independent          independent / bind
noise_freq = /16                  /2 /4 /8 /16

; 方波乐器
[square_1]
noise_ins_name = sq50            乐器名
square_mode = square             square / noise
wave = square                    square / q0
square_duty = 50                 50 / 25 / 12.5 / 6.25
octave_shift = 0                 -1 / 0 / +1
square_volume = default          default(ADSR) / 手动序列

; 曲目
[song_1]
name = 两只老虎
octave = 4
notes = 1:1 2:1 3:1 1:1 |        方波旋律行
        bd:1 hh:1 sd:1 hh:1 |    鼓点行 (并行)
        sq50:1:1 2:1 3:1 1:1 |   方波乐器切换 (保持直到下次切换)
```

### 运行

```bash
python psg_adsr_songs_v04.py              # 循环全部
python psg_adsr_songs_v04.py --song 1     # 单曲循环
python psg_adsr_songs_v04.py --song 1-4   # 范围循环 1-4
python psg_noisetest_v04.py               # 噪音手动测试
python psg_squaretest_v04.py              # 方波手动测试
```

### 键盘（播放中）

- n/b 切歌（立即中断，下一曲 dump 时生效新设置）
- ./, 速度
- v 颤音开关；;/' 颤音频率；[/] 颤音幅度；-/= 颤音延迟
- D 占空比循环；S 方波/白噪；W REF 切换
- q/ESC 退出

---

## 📁 关键文件

```
PSG3 v0.4/
├── docs/
│   ├── design.md                # 架构 (7.2 上板踩坑 / 7.3 VGM 预录制+乐器)
│   ├── handoff.md               # 本文件
│   ├── wiring-table-bus.md      # ⭐ 接口层接线表 (独立, 完整逐脚)
│   ├── wiring-table-square.md   # 方波通道 (照抄 PSG2 v0.3, 标注 reg 来源)
│   └── wiring-table-noise.md    # 噪音通道 (照抄 PSG2 v0.3 rev.a, 标注 reg 来源)
├── rtl/
│   └── psg3_top.v               # 顶层 (总线层 + 方波 + 噪音)
├── host/
│   ├── psg_adsr_songs_v04.py    # ⭐ 播放器 (VGM 预录制 + 噪音/方波乐器 + 范围循环)
│   ├── psg_noisetest_v04.py     # 噪音手动测试
│   ├── psg_squaretest_v04.py    # 方波手动测试
│   ├── psg_config.ini           # 速度+颤音配置
│   └── psg_songs.ini            # ⭐ 曲目库 (含噪音/方波乐器定义 + 测试曲)
└── tb/
    ├── psg3_bus_tb.v            # 总线协议验证 (含 OPLL 时序, 0 错误)
    └── psg3_top_tb.v            # 两通道挂总线验证 (0 错误)
```

---

## 📋 下一站：PSG3 v0.5 — 锯齿波/三角波通道（12-bit 频率）

PSG3 v0.4 圆满完成（接口 5 片 + 方波 11 片 + 噪音 8 片 = 24 片，相当完善的 PSG）。下一版 PSG3 v0.5 加锯齿波/三角波通道，核心升级是 **12-bit 频率精度**。

### 为什么 12-bit（design.md 8.5 节实测结论）

8-bit period 在高音区量化崩盘：C6-C7 每 period 档 = 1.6-3% 跳变（接近一个半音，音准失控）。12-bit 降到 0.01% 以下（人耳极限 ~0.1%），全音域解决。

| 音 | freq | 256-p | 8-bit 误差 | 12-bit 误差 |
|----|------|-------|-----------|------------|
| C5 | 523Hz | 61 | 0.8% ✅ | 0.0004% |
| C6 | 1047Hz | 30 | **1.6% ❌** | 0.001% |
| C7 | 2093Hz | 15 | **3.0% ❌** | 0.003% |

### v0.5 锯齿/三角通道设计要点

**寄存器**（用掉 2 个地址，独热码）：
- reg3(0x08) = period 低 8 位
- reg4(0x10) = period 高 4 位 + 4-bit 音量（高 4 位存 period[11:8]，低 4 位存 vol）
- 12-bit period = {reg4[7:4], reg3[7:0]}

**频率公式**（12-bit）：
- 锯齿/三角的 HC161 满幅度 0-255 计数（8-bit 波形幅度），period 控制计数步进
- 12-bit period 意味着 reload 间隔更精细，高音区音准解决
- 具体公式待 design 阶段推导（HC161 级联 3 片 vs 2 片+预分频）

**锯齿波架构**（design.md 5.5 节）：
```
clk → HC161×N (满幅度 0-255 计数, 12-bit period 控频)
        │ Q0-7 (有毛刺)
        ▼
   HC273 (clk 同步锁存, 滤毛刺)  ← 必须有, design.md 2.1 节
        │ Q0-7 (干净阶梯)
        ▼
   TLC7524#1 (DB0-7=波形, REF=5V) → 阶梯锯齿模拟量
        ▼
   TLC7524#2 (DB4-7=音量, REF=#1输出) → 衰减后锯齿
```

**三角波**：HC161 换 CD4029（可逆计数）+ CD4027（JK 方向控制），0→255→0 折线。

**HC273 毛刺滤除是刚需**（design.md 2.1 节）：HC161/4029 的 Q 翻转瞬间有毛刺（各位不同步跳变），TLC7524 自带的 WR 锁存是电平透明型挡不住。必须用 HC273 边沿寄存器在 clk 沿采样稳定值（Gigatron 同款解法）。

### v0.5 待定（design 阶段解决）

1. **12-bit period 怎么用 3×HC161 实现**：reload 机制（TC→PE 预置）在 12-bit 下怎么级联，满幅度 0-255 计数和 12-bit reload 怎么共存（period 控步进 vs 满幅度控波形）
2. **三角波方向控制的触发逻辑**：CD4029 的 Carry 脚 + CD4027 JK 怎么接（计满→减，计到 0→加）
3. **TLC7524 级联的 REF 阻抗**：第一片输出阻抗 5-20kΩ，能否直接驱动第二片 REF，需实测
4. **reg4 的 period/vol 复用**：8 位总线写 period 高 4 位 + vol 低 4 位，软件怎么拆分写入

### 长远（PSG3 之后）

- **SCC**（查表机路线，design.md 8.6 节）：HC138 译码扩展地址空间，SRAM 存波形表
- **第二方波通道**：reg5/reg6 + 第二套方波硬件（复用接口层）

总线协议一次定终身，加通道不改总线——这是 YM2413 复用的核心好处。

---

## 📝 沟通纪律（下个窗口必读 CLAUDE.md）

- **接口层独立用芯片**，不借门给通道层（PSG3 确立的原则）
- **驱动写入必须 MPSSE 批量打包**（v0.3 的逐条 + sleep 在两拍写协议下完全行不通）
- **A0/CS 跳变必须在 WR=0 期间**（组合选通对跳变顺序敏感）
- **噪音通道电路会回灌干扰方波**（振荡器 + 绑定 tc_hi 都要隔离）
- **所有 HC74 做 toggle/分频必须用 HCT74**（国产 HC74 高频失效，项目第三次踩坑）
- **VGM 预录制**：dump 成事件流回放，无运行时调度，确定性高
