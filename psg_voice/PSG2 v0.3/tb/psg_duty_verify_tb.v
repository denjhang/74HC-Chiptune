// psg_duty_verify_tb.v — 验证 4 挡占空比的实际波形 (占空比 + 频率)
//
// 弹一个固定音 (A4=440Hz, period=183), 测 4 挡的占空比和频率。

`timescale 1ns/1ps

module psg_duty_verify_tb;

    reg clk = 0;
    localparam CLK_HZ = 64000;
    localparam CLK_HALF = 1_000_000_000 / (2 * CLK_HZ);
    always #CLK_HALF clk = ~clk;

    reg        rst_n = 0;
    reg        period_le = 0;
    reg        A0 = 0;
    reg  [7:0] data = 0;
    wire [7:0] audio_out;
    wire       tc_out;

    psg_square_duty_v03 u_dut (
        .clk(clk), .rst_n(rst_n),
        .period_le(period_le), .A0(A0),
        .data(data),
        .audio_out(audio_out),
        .tc_out(tc_out)
    );

    task write_period;
        input [7:0] p;
        begin
            data = p; #200;
            period_le = 1; #500;
            period_le = 0; #200;
        end
    endtask

    task write_ctrl;
        input [7:0] c;
        begin
            data = c; #200;
            A0 = 1; #500;
            A0 = 0; #200;
        end
    endtask

    // 测占空比: 在足够长窗口内统计高/低采样数和过零
    integer i, high_cnt, total, transitions, prev_high;
    reg prev_wave;

    task measure_duty;
        input [1:0] duty;
        integer cycles;
        begin
            // 写占空比挡 (vol=15)
            write_ctrl(8'h0F | (duty << 4));   // vol=15 在 bit0-3, duty 在 bit4-5
            // 等 LFSR/toggle 稳定
            repeat (2000) @(posedge clk);
            // 测量 64000 个 clk (1 秒)
            high_cnt = 0; total = 0; transitions = 0; prev_wave = 1'b0;
            for (i = 0; i < 64000; i = i + 1) begin
                @(posedge clk); #1;
                total = total + 1;
                if (audio_out != 0) high_cnt = high_cnt + 1;
                if ((audio_out != 0) !== prev_wave) begin
                    transitions = transitions + 1;
                    prev_wave = (audio_out != 0);
                end
            end
            $display("挡位 %b: 高电平 %0d/%0d = %0d%%, 过零 %0d 次 (频率≈%0d Hz)",
                     duty, high_cnt, total, 100*high_cnt/total,
                     transitions/2, transitions/2);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // A4 = 440Hz, period = 256 - 64000/(2*440) = 256 - 73 = 183
        write_period(8'd183);
        $display("=== 占空比验证 (A4=440Hz, period=183) ===");

        measure_duty(2'b00);   // 50%
        measure_duty(2'b01);   // 25%
        measure_duty(2'b10);   // 12.5%
        measure_duty(2'b11);   // 6.25% 变体

        $display("=== 完成 ===");
        $finish;
    end

    initial begin
        #10_000_000_000;   // 10s 超时 (4挡×66000 clk 测量)
        $display("ERROR: 超时");
        $finish;
    end

endmodule
