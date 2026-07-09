// cd4029_tb.v — CD4029 模型验证 (4-bit 可逆计数 + 级联 8-bit 三角波方向控制)
//
// 验证:
//   1. 单片 CD4029 二进制加计数 0→15, 计满 CO=L, 回绕到 0
//   2. 单片 CD4029 二进制减计数 15→0, 计空 CO=L, 回绕到 15
//   3. 两片级联 8-bit 加计数, 高位 CO 在 255 时 = L
//   4. 三角波模拟: CD4027 方向寄存器 + 8-bit 可逆, 0→255→0 折线

`timescale 1ns/1ps

module cd4029_tb;
    reg clk = 0;
    always #5 clk = ~clk;   // 100MHz 仿真时钟

    // ---- 单片 CD4029 测试 (加计数) ----
    reg  PE_a = 1, CI_a = 0, BD_a = 1, UD_a = 1;
    reg  CLK_a = 0;
    wire [3:0] Q_a;
    wire CO_a;
    cd4029 u_a (
        .PE(PE_a), .CI(CI_a), .BD(BD_a), .UD(UD_a), .CLK(CLK_a),
        .JAM1(1'b0), .JAM2(1'b0), .JAM3(1'b0), .JAM4(1'b0),
        .Q1(Q_a[0]), .Q2(Q_a[1]), .Q3(Q_a[2]), .Q4(Q_a[3]),
        .CO(CO_a)
    );

    // ---- 两片级联 8-bit (三角波: CD4027 控方向) ----
    reg  PE_lo = 0, PE_hi = 0;   // 预置使能 (测试用 reg 驱动)
    wire CO_lo;
    wire [3:0] Q_lo;
    wire UD;              // 方向 (来自 CD4027)
    wire CO_hi;           // 高位 CO = 8-bit 计满/计空
    wire [3:0] Q_hi;

    cd4029 u_lo (
        .PE(PE_lo), .CI(1'b0), .BD(1'b1), .UD(UD), .CLK(clk),
        .JAM1(1'b0), .JAM2(1'b0), .JAM3(1'b0), .JAM4(1'b0),
        .Q1(Q_lo[0]), .Q2(Q_lo[1]), .Q3(Q_lo[2]), .Q4(Q_lo[3]),
        .CO(CO_lo)
    );
    cd4029 u_hi (
        .PE(PE_hi), .CI(CO_lo), .BD(1'b1), .UD(UD), .CLK(clk),
        .JAM1(1'b0), .JAM2(1'b0), .JAM3(1'b0), .JAM4(1'b0),
        .Q1(Q_hi[0]), .Q2(Q_hi[1]), .Q3(Q_hi[2]), .Q4(Q_hi[3]),
        .CO(CO_hi)
    );

    // ---- CD4027 方向寄存器: 用 clk 反相沿触发, 避开同沿竞争 ----
    // clk 上升沿: CD4029 更新 Q → CO 稳定 (组合)
    // clk 下降沿 (~clk 上升沿): CD4027 采样稳定的 CO, 决定是否翻转方向
    // 硬件实现: clk 经 HC04 反相后接 CD4027.CLK1
    reg dir_rst = 0;
    wire clk_n = ~clk;        // 反相时钟给 CD4027
    wire at_extreme = ~CO_hi; // CO=L 表示在极值
    wire dir_q, dir_qn;
    cd4027 u_dir (
        .CLK1(clk_n), .J1(at_extreme), .K1(at_extreme), .SET1(1'b0), .RST1(dir_rst),
        .Q1(dir_q), .Q1_n(dir_qn),
        .CLK2(1'b0), .J2(1'b0), .K2(1'b0), .SET2(1'b0), .RST2(1'b0),
        .Q2(), .Q2_n()
    );
    // 上电方向 = 加: CD4027 Q 上电=0, 取 Qn 当 UD (上电 Qn=1=加)
    assign UD = dir_qn;

    wire [7:0] tri_count = {Q_hi, Q_lo};

    integer i;
    integer peak_count = 0;   // 到达 255 的次数
    integer valley_count = 0; // 到达 0 的次数

    initial begin
        $display("=== CD4029 + CD4027 模型验证 ===");

        // ---- Test 1: 单片加计数 ----
        PE_a = 1; UD_a = 1; BD_a = 1; CI_a = 0;
        CLK_a = 0;
        #2 PE_a = 0;     // 释放预置 (Q_a 应该是 0)
        #2;
        $display("Test1 加计数起始 Q_a=%0d (期望 0)", Q_a);
        for (i = 0; i < 20; i = i + 1) begin
            CLK_a = 1; #5; CLK_a = 0; #5;
            if (Q_a == 15) $display("  加计数满: Q_a=15, CO_a=%b (期望 0)", CO_a);
            if (i < 18 && Q_a == 0 && i > 0)
                $display("  回绕到 0 (第 %0d 拍)", i);
        end

        // ---- Test 2: 单片减计数 ----
        UD_a = 0; PE_a = 1;
        #2 PE_a = 0;     // 从 JAM=0 开始减会先回绕到 15
        #2;
        $display("Test2 减计数起始 Q_a=%0d (JAM=0 减计数先回绕到 15)", Q_a);
        for (i = 0; i < 20; i = i + 1) begin
            CLK_a = 1; #5; CLK_a = 0; #5;
            if (CO_a == 0 && Q_a == 0)
                $display("  减计数空: Q_a=0, CO_a=0");
        end

        // ---- Test 3: 8-bit 级联三角波 (监测峰谷) ----
        // 先复位 CD4027 (RST1 拉高再低)
        dir_rst = 1; #2; dir_rst = 0;
        // 复位 CD4029 两片: 用 PE 预置 0
        PE_lo = 1; PE_hi = 1; #2;
        PE_lo = 0; PE_hi = 0; #2;

        $display("Test3 8-bit 三角波起始 count=%0d, UD=%b (期望 0, 加)", tri_count, UD);

        // 跑 600 个 clk, 应该完成 ~2 个完整三角周期 (256*2=512 clk/周期)
        peak_count = 0; valley_count = 0;
        for (i = 0; i < 600; i = i + 1) begin
            @(posedge clk);
            #1;   // 等信号稳定
            if (i < 12 || (i >= 250 && i < 265))
                $display("  clk%0d: count=%0d CO_hi=%b UD=%b at_extreme=%b",
                         i, tri_count, CO_hi, UD, at_extreme);
            if (tri_count == 8'd255) begin
                peak_count = peak_count + 1;
                if (i < 600) $display("  到达峰值 255 (第 %0d clk), UD=%b", i, UD);
            end
            if (tri_count == 8'd0 && i > 2) begin
                valley_count = valley_count + 1;
            end
        end

        $display("=== 结果 ===");
        $display("峰值(255)次数: %0d", peak_count);
        $display("谷值(0)次数:   %0d", valley_count);
        if (peak_count >= 2 && valley_count >= 2)
            $display(">>> CD4029 三角波折线验证通过 (0->255->0 循环) <<<");
        else
            $display("*** 失败: 三角波未正常折返 ***");

        $finish;
    end

    // 防止仿真挂死
    initial begin
        #100000;
        $display("*** 超时 ***");
        $finish;
    end
endmodule
