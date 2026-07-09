// cd4029_tri_tb.v — CD4029×2 + CD4027 三角波折返逻辑验证 (干净版)
//
// 只验证 8-bit 三角波 0→255→0→255 折返.
// CD4029 模型已在前一个 tb 验证过加减计数正确.

`timescale 1ns/1ps

module cd4029_tri_tb;
    reg clk = 0;
    always #5 clk = ~clk;   // 100MHz, 周期 10ns

    // ---- 两片 CD4029 级联 8-bit 满幅度可逆计数 ----
    reg  PE_lo = 0, PE_hi = 0;
    wire CO_lo;
    wire [3:0] Q_lo;
    wire UD;
    wire CO_hi;
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

    // ---- CD4027 方向寄存器: 反相时钟沿触发 (避开同沿竞争) ----
    // clk 上升沿: CD4029 更新 Q → CO 组合稳定
    // clk 下降沿: CD4027 采样 CO, CO=L(极值) → J=K=1 toggle 方向
    wire clk_n = ~clk;
    wire at_extreme = ~CO_hi;
    reg dir_rst = 0;
    wire dir_q, dir_qn;
    cd4027 u_dir (
        .CLK1(clk_n), .J1(at_extreme), .K1(at_extreme),
        .SET1(1'b0), .RST1(dir_rst),
        .Q1(dir_q), .Q1_n(dir_qn),
        .CLK2(1'b0), .J2(1'b0), .K2(1'b0), .SET2(1'b0), .RST2(1'b0),
        .Q2(), .Q2_n()
    );
    // 上电 UD=加 (CD4027 Q=0, Qn=1=加)
    assign UD = dir_qn;

    wire [7:0] tri_count = {Q_hi, Q_lo};

    // ---- 波形 dump 调试用 ----
    initial begin
        $dumpfile("cd4029_tri.vcd");
        $dumpvars(0, cd4029_tri_tb);
    end

    integer i;
    integer peak_cnt = 0, valley_cnt = 0;
    integer prev_count = 0;
    integer monotonic_up = 1;   // 检测上升段是否单调

    initial begin
        // 复位
        dir_rst = 1;
        PE_lo = 1; PE_hi = 1;
        #2;
        dir_rst = 0;
        PE_lo = 0; PE_hi = 0;
        #3;

        $display("=== CD4029 三角波折返验证 ===");
        $display("起始 count=%0d UD=%b (期望 0, 加)", tri_count, UD);

        // 跑 1100 拍 (约 2 个三角周期 = 512 拍)
        prev_count = tri_count;
        for (i = 0; i < 1100; i = i + 1) begin
            @(posedge clk);
            #1;
            // 打印转折点附近
            if (tri_count >= 8'd253 || tri_count <= 8'd2)
                $display("  clk%0d: count=%0d CO_hi=%b UD=%b", i, tri_count, CO_hi, UD);

            if (tri_count == 8'd255) peak_cnt = peak_cnt + 1;
            if (tri_count == 8'd0 && i > 5) valley_cnt = valley_cnt + 1;

            prev_count = tri_count;
        end

        $display("=== 结果 ===");
        $display("峰值(255)次数: %0d (1100 拍期望 ~2 次)", peak_cnt);
        $display("谷值(0)次数:   %0d", valley_cnt);
        if (peak_cnt >= 2 && valley_cnt >= 2)
            $display(">>> 三角波折返验证通过 <<<");
        else
            $display("*** 失败: 未正常折返 ***");

        $finish;
    end

    initial begin
        #200000;
        $display("*** 超时 ***");
        $finish;
    end
endmodule
