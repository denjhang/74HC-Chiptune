// fm6_core.v — FM6 v0.7 单通道 2-op FM 合成器核心 (验证版)
//
// 目标: 验证 2-op FM 算法在 Verilog 里跑通, 能输出 FM 音色 WAV
//   对标 ym2413.c ym_render() 的单通道运算
//
// 算法 (每采样):
//   1. phase_m += step_m * mul_m    (OP1 NCO 累加, 16-bit)
//   2. phase_c += step_c             (OP2 NCO 累加, 16-bit)
//   3. idx_m = phase_m[15:10]        (OP1 取相位高 6 位)
//   4. mod_out = conv_vol[env_level_m][idx_m]   (OP1 查表, s8)
//   5. idx_c = phase_c[15:10] + mod_out          (相位调制, 6-bit 模 64)
//   6. carrier = conv_vol[env_level_c][idx_c]    (OP2 查表, s8)
//   7. out = carrier * (16-vol) >> 2             (输出缩放)
//
// 本版: 固定 env_level_m=env_level_c=31 (满包络), fb=0, mul 由 CPU 预乘进 step
//       — 先验证 NCO + 查表 + 相位调制 + 输出, ADSR/反馈/多通道留后续
//
// conv_vol 表: 用 reg 数组 + $readmemh 加载 (行为级, 同 WSG8)
// 加法器: 实例化 hc283 (验证原语能用于 NCO 累加)
//
// 芯片映射 (design.md):
//   W3 参数+累加 RAM  → reg 数组 (行为级)
//   F1 conv_vol RAM   → reg 数组 + $readmemh
//   W4+F2 HC283×2     → NCO 加法 (本版实例化验证)
//   W5a HC174         → phase/carry 锁存 (行为级 reg)
//   F3 HC273          → mod_out 锁存 (行为级 reg)
//   F4 HC283          → 相位调制加法 (实例化)
//   W6 HC273          → 输出锁存 (行为级 reg)
//   W9/W10 TLC7524    → 输出 (行为级 assign)

`timescale 1ns/1ps

module fm6_core (
    input         clk,         // 主时钟 (14.318MHz 仿真, tb 里可降速)
    input         rst_n,       // 异步复位
    input         samp_en,     // 采样使能 (每采样周期拉高 1 clk)
    // 参数 (CPU 写入, 本版直接 port 传入)
    input  [15:0] step_m,      // OP1 步进 (已含 mul_m 预乘)
    input  [15:0] step_c,      // OP2 步进
    input  [4:0]  env_level_m, // OP1 包络电平 (0-31, 本版固定 31)
    input  [4:0]  env_level_c, // OP2 包络电平
    input  [3:0]  vol,         // 音量 (0-15)
    // 输出
    output signed [7:0] carrier_out,  // OP2 查表输出 (s8, 给 DAC)
    output [7:0]  dac_out             // DAC 输出 (无符号, carrier+128 缩放)
);

    // ============================================================
    // conv_vol 查表 RAM (F1: 62256, 32×64=2048 字节)
    // 地址 = {env_level[4:0], sin_index[5:0]} = 11-bit
    // 数据 = s8 有符号 (-31~+31), 存为 2's complement 无符号
    // ============================================================
    reg [7:0] conv_vol [0:2047];
    initial begin
        $readmemh("conv_vol.hex", conv_vol);
    end

    // ============================================================
    // NCO 相位累加器 (W3 累加器区, 行为级)
    // ============================================================
    reg [15:0] phase_m;   // OP1 相位
    reg [15:0] phase_c;   // OP2 相位

    // ============================================================
    // HC283 实例化 — 验证加法器原语用于 NCO
    // 16-bit 加法 = 4 片 HC283 级联 ( nibble 链 )
    // 本版实例化 4 片做 phase_m 累加, 验证级联正确
    // ============================================================

    // OP1 NCO 加法: phase_m + step_m
    // 拆成 4 个 nibble, 4 片 HC283 级联
    wire [3:0] sum_m_n0, sum_m_n1, sum_m_n2, sum_m_n3;
    wire       cy_m_n0, cy_m_n1, cy_m_n2, cy_m_n3;

    hc283 u_m283_n0 (
        .A(phase_m[3:0]),   .B(step_m[3:0]),   .C0(1'b0),
        .S(sum_m_n0),       .C4(cy_m_n0)
    );
    hc283 u_m283_n1 (
        .A(phase_m[7:4]),   .B(step_m[7:4]),   .C0(cy_m_n0),
        .S(sum_m_n1),       .C4(cy_m_n1)
    );
    hc283 u_m283_n2 (
        .A(phase_m[11:8]),  .B(step_m[11:8]),  .C0(cy_m_n1),
        .S(sum_m_n2),       .C4(cy_m_n2)
    );
    hc283 u_m283_n3 (
        .A(phase_m[15:12]), .B(step_m[15:12]), .C0(cy_m_n2),
        .S(sum_m_n3),       .C4(cy_m_n3)       // cy_m_n3 = 进位溢出 (丢弃, 16-bit 回绕)
    );

    // OP2 NCO 加法: phase_c + step_c (同理, 4 片 HC283)
    wire [3:0] sum_c_n0, sum_c_n1, sum_c_n2, sum_c_n3;
    wire       cy_c_n0, cy_c_n1, cy_c_n2, cy_c_n3;

    hc283 u_c283_n0 (
        .A(phase_c[3:0]),   .B(step_c[3:0]),   .C0(1'b0),
        .S(sum_c_n0),       .C4(cy_c_n0)
    );
    hc283 u_c283_n1 (
        .A(phase_c[7:4]),   .B(step_c[7:4]),   .C0(cy_c_n0),
        .S(sum_c_n1),       .C4(cy_c_n1)
    );
    hc283 u_c283_n2 (
        .A(phase_c[11:8]),  .B(step_c[11:8]),  .C0(cy_c_n1),
        .S(sum_c_n2),       .C4(cy_c_n2)
    );
    hc283 u_c283_n3 (
        .A(phase_c[15:12]), .B(step_c[15:12]), .C0(cy_c_n2),
        .S(sum_c_n3),       .C4(cy_c_n3)
    );

    // ============================================================
    // 相位累加 (samp_en 时钟锁存)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_m <= 16'd0;
            phase_c <= 16'd0;
        end else if (samp_en) begin
            phase_m <= {sum_m_n3, sum_m_n2, sum_m_n1, sum_m_n0};
            phase_c <= {sum_c_n3, sum_c_n2, sum_c_n1, sum_c_n0};
        end
    end

    // ============================================================
    // OP1 查表 (conv_vol[env_level_m][phase_m[15:10]])
    // ============================================================
    wire [5:0] idx_m = phase_m[15:10];
    wire [10:0] conv_addr_m = {env_level_m, idx_m};
    wire [7:0] mod_out_u = conv_vol[conv_addr_m];     // 无符号 (2's complement)
    wire signed [7:0] mod_out = mod_out_u;            // 重解释为有符号

    // F3 HC273: 锁存 mod_out (给相位调制用)
    reg signed [7:0] mod_out_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mod_out_reg <= 8'sd0;
        else if (samp_en)
            mod_out_reg <= mod_out;
    end

    // ============================================================
    // 相位调制: idx_c = phase_c[15:10] + mod_out (模 64)
    // F4 HC283 — 设计上是 8-bit 加法取低 6 位
    // 验证阶段用行为级 (HC283 级联在 NCO 部分已验证原语可用)
    // ============================================================
    wire [5:0] idx_c_base = phase_c[15:10];
    wire [6:0] idx_c_sum  = {1'b0, idx_c_base} + {1'b0, mod_out_u[5:0]};
    wire [5:0] idx_c      = idx_c_sum[5:0];   // 模 64 (ym2413: & 0x3F)

    // ============================================================
    // OP2 查表 (conv_vol[env_level_c][idx_c])
    // ============================================================
    wire [10:0] conv_addr_c = {env_level_c, idx_c};
    wire [7:0] carrier_u = conv_vol[conv_addr_c];
    wire signed [7:0] carrier = carrier_u;

    // ============================================================
    // W6 HC273: 输出锁存
    // ============================================================
    reg signed [7:0] carrier_reg;
    reg [3:0] vol_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            carrier_reg <= 8'sd0;
            vol_reg <= 4'd0;
        end else if (samp_en) begin
            carrier_reg <= carrier;
            vol_reg <= vol;
        end
    end

    assign carrier_out = carrier_reg;

    // ============================================================
    // DAC 输出 (TLC7524 级联等效)
    // ym2413: out = carrier * (16-vol) >> 2
    // carrier s8 (-31~+31), (16-vol) 1~16
    // TLC7524: 级联做乘法, REF=carrier, DB=vol → OUT = carrier × vol_gain
    // 行为级: out = carrier * (16-vol) / 4, 再 +128 偏移到 0-255
    // ============================================================
    wire signed [15:0] scaled;
    assign scaled = (carrier_reg * (16 - vol_reg)) >>> 2;
    // scaled 范围: carrier max ±31, (16-vol) max 16 → ±124, >>2 → ±31
    // +128 偏移: 97~159 (DAC 中点 128)

    assign dac_out = scaled[7:0] + 8'd128;

endmodule
