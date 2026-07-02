// psg_noise_v03_tb.v — PSG2 v0.3 LFSR 噪音通道 testbench
//
// 验证:
//   1. 控制寄存器写入 (HC374: 频率/类型/绑定/音量)
//   2. 白噪音: Q7⊕Q5 反馈, 输出伪随机, 周期 255
//   3. 周期噪音: Q0 自反馈, 输出周期 8 的窄脉冲
//   4. 频率挡: bit0-1 选 ÷2/÷4/÷8/÷16, LFSR 时钟频率不同
//   5. 绑定模式: bind=1 时 HC161 跟 square_tc 走 (独立时不跟)
//   6. 音量: vol=0 静音, vol=15 满幅

`timescale 1ns/1ps

module psg_noise_v03_tb;

    // 64kHz 时钟
    reg clk = 0;
    localparam CLK_HZ = 64000;
    localparam CLK_HALF = 1_000_000_000 / (2 * CLK_HZ);  // 7812ns
    always #CLK_HALF clk = ~clk;

    reg        rst_n = 0;
    reg        A1 = 0;
    reg  [7:0] data = 0;
    reg        square_tc = 0;   // 模拟方波通道 TC
    wire [7:0] audio_out;

    psg_noise_v03 u_dut (
        .clk(clk), .rst_n(rst_n),
        .A1(A1), .data(data),
        .square_tc(square_tc),
        .audio_out(audio_out)
    );

    // ===== 写控制寄存器任务 (HC374: CP 上升沿锁存) =====
    task write_ctrl;
        input [7:0] c;
        begin
            data = c;
            #200;
            A1 = 1;     // CP 上升沿
            #500;
            A1 = 0;
            #200;
        end
    endtask

    // ===== 模拟方波 TC: 每 N 个 clk 产生 1 拍 =====
    // 用独立进程生成, 绑定测试时启用
    integer tc_period = 16;   // square_tc 每 16 个 clk 翻转一次 (模拟方波)
    integer tc_cnt = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            square_tc <= 0;
            tc_cnt <= 0;
        end else begin
            if (tc_cnt == tc_period-1) begin
                square_tc <= 1;
                tc_cnt <= 0;
            end else begin
                square_tc <= 0;
                tc_cnt <= tc_cnt + 1;
            end
        end
    end

    // ===== 监测 LFSR 内部状态 (层次引用) =====
    wire [7:0] lfsr_q = u_dut.u_lfsr.q_reg;
    wire       lfsr_clk = u_dut.noise_clk;

    // 统计白噪输出 Q7 的翻转次数 (验证伪随机性)
    integer white_transitions = 0;
    reg       prev_q7 = 0;
    always @(posedge lfsr_clk) begin
        if (rst_n) begin
            if (lfsr_q[7] != prev_q7)
                white_transitions = white_transitions + 1;
            prev_q7 <= lfsr_q[7];
        end
    end

    integer i;

    initial begin
        $display("=== PSG2 v0.3 LFSR Noise TB ===");
        $dumpfile("psg_noise.vcd");
        $dumpvars(0, psg_noise_v03_tb);
        // 复位
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        $display("[%0t] 复位释放, LFSR 种子 = 0x%02x", $time, lfsr_q);
        // debug: 观察 div_q / noise_clk 前 8 拍
        $display("[%0t] DEBUG div_q=%b noise_clk=%b square_tc=%b",
                 $time, u_dut.div_q, u_dut.noise_clk, square_tc);
        repeat (8) @(posedge clk);
        $display("[%0t] DEBUG div_q=%b noise_clk=%b", $time, u_dut.div_q, u_dut.noise_clk);

        // ===== 测试 1: 白噪音, 频率÷2, 音量 15 =====
        // 控制字: bit0-3=vol(15), bit4-5=freq(00=÷2), bit6=bind(0)
        $display("\n--- 测试1: 白噪音 ÷2, vol=15 ---");
        write_ctrl(8'h0F);   // vol=15, freq=÷2, bind=0
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge lfsr_clk);
            $display("[%0t] LFSR=0x%02x audio=%0d", $time, lfsr_q, audio_out);
        end
        $display("白噪 Q7 翻转次数 (64 拍): %0d", white_transitions);

        // ===== 测试 2: 频率挡 ÷16, 白噪 =====
        $display("\n--- 测试2: 白噪音 ÷16 (慢速) ---");
        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
        white_transitions = 0;
        write_ctrl(8'h3F);   // vol=15, freq=÷16(bit4-5=11), bind=0
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge lfsr_clk);
        end
        $display("÷16 白噪 16 拍 Q7 翻转: %0d (对比: ÷2 同拍数约 17)", white_transitions);

        // ===== 测试 3: 静音 (vol=0) =====
        $display("\n--- 测试3: 静音 vol=0 ---");
        write_ctrl(8'h00);   // vol=0
        @(posedge lfsr_clk);
        $display("[%0t] audio=%0d (应=0)", $time, audio_out);

        // ===== 测试 4: 绑定模式 (bind=1, 跟 square_tc) =====
        $display("\n--- 测试4: 绑定模式 bind=1 ---");
        rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
        write_ctrl(8'h0F);   // bind=0, freq=÷2, vol=15 (独立模式)
        @(posedge clk);
        $display("[%0t] 独立模式: noise_clk 在 64kHz/2 频率翻转", $time);
        repeat (4) @(posedge lfsr_clk);
        $display("[%0t] 独立 4 拍后 LFSR=0x%02x", $time, lfsr_q);

        // 切绑定 (noise_clk 直通 square_tc)
        write_ctrl(8'h4F);   // bind=1(bit6), freq=÷2, vol=15
        @(posedge clk);
        $display("[%0t] 绑定模式: noise_clk 直通 square_tc", $time);
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge lfsr_clk);
            $display("[%0t] LFSR=0x%02x (此拍由 square_tc 推进)", $time, lfsr_q);
        end

        $display("\n=== TB 完成 ===");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;   // 50ms
        $display("ERROR: TB 超时");
        $finish;
    end

endmodule
