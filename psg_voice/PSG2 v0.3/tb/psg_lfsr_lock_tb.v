// psg_lfsr_lock_tb.v — 验证 LFSR 运行中是否归零死锁 (无防护版)
//
// 目的: 确认 max-length LFSR (Q7⊕Q5 反馈, 种子非0) 是否会在运行中归零。
// 方法: 去掉 CD4078 防护, 直接搭最小 LFSR (HC164 + CD4070), 种子 0x01, 跑满 N 拍,
//       统计: (1) 是否出现 0x00  (2) LFSR 实际周期  (3) 走过多少不同状态。
// 结论决定: 若永不归零 → RST 注入种子即可, 不需 CD4078。
//          若会归零   → 必须保留 CD4078 (或其它防护)。

`timescale 1ns/1ps

module psg_lfsr_lock_tb;

    reg clk = 0;
    always #5 clk = ~clk;   // 任意快时钟, 只为推进 LFSR

    reg rst_n = 0;
    wire [7:0] lfsr_q;
    wire lfsr_clk = clk;   // 直接用 clk 当 LFSR 时钟 (最简, 只看序列)

    // LFSR 反馈: Q7 ⊕ Q5 ⊕ Q4 ⊕ Q3 (8 位 max-length, 多项式 x^8+x^6+x^5+x^4+1)
    wire xor_a, xor_b, xor_fb;
    wire serial_in = xor_fb;   // 无防护, 纯反馈

    cd4070 u_xor (
        .A1(lfsr_q[7]), .B1(lfsr_q[5]), .Y1(xor_a),   // Q7⊕Q5
        .A2(lfsr_q[4]), .B2(lfsr_q[3]), .Y2(xor_b),   // Q4⊕Q3
        .A3(xor_a),     .B3(xor_b),     .Y3(xor_fb),  // (Q7⊕Q5)⊕(Q4⊕Q3)
        .A4(1'b0), .B4(1'b0), .Y4()
    );

    hc164 u_lfsr (
        .DSA(serial_in), .DSB(1'b1),
        .CP(lfsr_clk), .MR_n(rst_n),
        .Q0(lfsr_q[0]),.Q1(lfsr_q[1]),.Q2(lfsr_q[2]),.Q3(lfsr_q[3]),
        .Q4(lfsr_q[4]),.Q5(lfsr_q[5]),.Q6(lfsr_q[6]),.Q7(lfsr_q[7])
    );

    integer i;
    integer hit_zero = 0;        // 归零次数
    integer hit_seed = 0;        // 回到种子次数 (周期)
    integer seen_states = 0;     // 经过的不同状态数 (估算)
    reg [7:0] first_state;

    // 记录前 300 拍的状态序列 (检测周期)
    reg [7:0] hist [0:299];

    initial begin
        $display("=== LFSR 归零死锁验证 (无防护, 不拉RST靠初值) ===");
        rst_n = 1;   // 全程不复位
        @(posedge clk);
        #1;
        first_state = lfsr_q;   // 第一拍移位后的值作为基准
        $display("[%0t] 基准态 = 0x%02x", $time, lfsr_q);

        // 跑 2000 拍 (够覆盖周期 255 约 7 次)
        for (i = 0; i < 2000; i = i + 1) begin
            @(posedge clk);
            #1;   // 等稳定
            if (lfsr_q == 8'h00) begin
                hit_zero = hit_zero + 1;
                if (hit_zero <= 3)
                    $display("[%0t] ⚠️ 第 %0d 拍归零! LFSR=0x00", $time, i+1);
            end
            if (lfsr_q == first_state && i > 0) begin
                hit_seed = hit_seed + 1;
                if (hit_seed == 1)
                    $display("[%0t] ✅ 第 %0d 拍回到基准态, LFSR 周期 = %0d",
                             $time, i+1, i+1);
            end
        end

        $display("\n=== 结论 ===");
        $display("总拍数: 2000");
        $display("归零次数: %0d", hit_zero);
        $display("回到基准态次数: %0d", hit_seed);
        if (hit_zero == 0)
            $display(">>> max-length LFSR 永不归零, RST 注入种子即可, 不需 CD4078 <<<");
        else
            $display(">>> 会归零死锁, 必须保留防护 <<<");

        $finish;
    end

    initial begin
        #100_000;
        $display("ERROR: TB 超时");
        $finish;
    end

endmodule
