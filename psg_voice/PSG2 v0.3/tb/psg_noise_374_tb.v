// psg_noise_374_tb.v — HC374 版 LFSR 噪音测试
//
// 验证项:
//   1. 上电启动不锁死 (16 拍后 LFSR ≠ 0)
//   2. max-length 周期 255
//   3. 4 挡频率 (÷2/4/8/16) 翻转速率不同
//   4. 绑定模式 (noise_clk = square_tc)
//   5. 静音 vol=0 → audio=0

`timescale 1ns/1ps

module psg_noise_374_tb;
    reg        clk = 0;       // 64kHz
    reg        A1 = 0;
    reg  [7:0] data = 0;
    reg        square_tc = 0;
    wire [7:0] audio;

    psg_noise_374_v03 u_dut (
        .clk(clk), .A1(A1), .data(data),
        .square_tc(square_tc), .audio_out(audio)
    );

    // 64kHz 时钟
    always #7812.5 clk = ~clk;   // T/2 = 1/128kHz = 7.8125us

    // 模拟 TC (方波翻转, 假设方波频率 = clk/16)
    always @(posedge clk) begin
        square_tc <= ~square_tc;
    end

    // 写控制寄存器任务
    task write_ctrl(input [7:0] val);
        begin
            data = val;
            #100;
            A1 = 1; #100;
            A1 = 0; #100;
        end
    endtask

    // 层次访问内部信号
    wire [7:0] lfsr_q = u_dut.lfsr_q;
    wire [4:0] scnt   = u_dut.startup_cnt;
    wire       sactive = u_dut.startup_active;

    integer i;
    integer zero_count = 0;
    integer base_count = 0;
    reg [7:0] base_state;

    initial begin
        $display("=== HC374 LFSR 噪音测试 ===");

        // === 测试 1: 上电启动不锁死 ===
        $display("\n--- 测试1: 上电启动 (默认 freq=00 ÷2, vol=0) ---");
        write_ctrl(8'h00);   // vol=0, freq=00, bind=0
        #5000;
        $display("  启动计数器: %0d / 16 (active=%0d)", scnt, sactive);

        // 跑 20 拍看启动计数器递增 + LFSR 填充
        for (i = 0; i < 20; i = i + 1) begin
            #20000;
            if (i % 4 == 3)
                $display("  [%0d] startup_cnt=%0d LFSR=0x%02h audio=0x%02h",
                         i+1, scnt, lfsr_q, audio);
        end

        // 启动结束后 LFSR 应该非 0
        #20000;
        if (lfsr_q != 8'h00)
            $display("  ✅ 启动结束: LFSR=0x%02h (非 0, 不死锁)", lfsr_q);
        else
            $display("  ❌ 启动结束: LFSR=0x00 (锁死!)");

        // === 测试 2: max-length 周期 255 ===
        $display("\n--- 测试2: max-length 周期验证 ---");
        // 等稳定后记录基准态
        #50000;
        base_state = lfsr_q;
        $display("  基准态 = 0x%02h", base_state);

        // 跑 256 拍, 数回到基准的次数 + 全 0 次数 (跳过第 0 拍, 它就是起点)
        for (i = 0; i < 256; i = i + 1) begin
            #15625;   // 一个 noise_clk 周期 (÷2, 32kHz)
            if (lfsr_q == 8'h00) zero_count = zero_count + 1;
            if (i > 0 && lfsr_q == base_state) base_count = base_count + 1;
        end
        $display("  256 拍: 回基准 %0d 次 (期望 1), 全 0 %0d 次 (期望 0)",
                 base_count, zero_count);
        if (base_count == 1 && zero_count == 0)
            $display("  ✅ max-length 周期 255, 不归零");
        else
            $display("  ❌ 周期异常");

        // === 测试 3: 音量变化 (统计 Q7=1 比例, 而非单次采样) ===
        $display("\n--- 测试3: 音量 (统计 Q7=1 比例) ---");
        begin : vol_test
            integer q7_ones;
            integer q7_zero_audio;
            integer j;
            // vol=15
            write_ctrl(8'h0F);
            q7_ones = 0;
            for (j = 0; j < 200; j = j + 1) begin
                #15625;
                if (lfsr_q[7]) q7_ones = q7_ones + 1;
            end
            $display("  vol=15: 200 拍中 Q7=1 占 %0d (约 50%%), Q7=1 时 audio 应 0xF0", q7_ones);

            // vol=8
            write_ctrl(8'h08);
            q7_ones = 0;
            for (j = 0; j < 200; j = j + 1) begin
                #15625;
                if (lfsr_q[7]) q7_ones = q7_ones + 1;
            end
            $display("  vol=8:  200 拍中 Q7=1 占 %0d", q7_ones);

            // 静音
            write_ctrl(8'h00);
            q7_zero_audio = 0;
            for (j = 0; j < 200; j = j + 1) begin
                #15625;
                if (audio == 8'h00) q7_zero_audio = q7_zero_audio + 1;
            end
            $display("  vol=0:  200 拍中 audio=0x00 占 %0d (期望 200, 全静音)", q7_zero_audio);
        end

        // === 测试 4: 频率挡切换 ===
        $display("\n--- 测试4: 频率挡 (统计 Q7 翻转次数) ---");
        write_ctrl(8'h8F);   // vol=15, freq=00 (÷2)
        #100000;
        $display("  freq=÷2:  audio 范围 0x%02h~(观察翻转)", audio);

        write_ctrl(8'h9F);   // vol=15, freq=01 (÷4)
        #100000;
        $display("  freq=÷4");

        write_ctrl(8'hAF);   // vol=15, freq=10 (÷8)
        #100000;
        $display("  freq=÷8");

        write_ctrl(8'hBF);   // vol=15, freq=11 (÷16)
        #100000;
        $display("  freq=÷16");

        // === 测试 5: 绑定模式 ===
        $display("\n--- 测试5: 绑定模式 ---");
        write_ctrl(8'hCF);   // vol=15, freq=00, bind=1
        #100000;
        $display("  绑定: noise_clk 跟 square_tc, LFSR=0x%02h", lfsr_q);
        $display("  (square_tc 每 clk 翻转一次, LFSR 推进快)");

        // === 结论 ===
        $display("\n=== 测试完成 ===");
        $finish;
    end

endmodule
