`timescale 1ns/1ps

// fsm_player_tb.v - FSM 播放器测试台

module fsm_player_tb;
    reg CLK = 0;
    reg RST_n = 1;
    wire [15:0] DATA_OUT;
    wire        PLAYING;

    fsm_player u_dut (
        .CLK(CLK),
        .RST_n(RST_n),
        .DATA_OUT(DATA_OUT),
        .PLAYING(PLAYING)
    );

    // 时钟: 1MHz
    always #500 CLK = ~CLK;

    integer i;
    integer expected;
    reg [15:0] samples[0:255];
    reg is_ok;

    initial begin
        $dumpfile("fsm_player.vcd");
        $dumpvars(0, fsm_player_tb);

        // 复位
        RST_n = 0;
        #1000;
        RST_n = 1;
        #500;

        $display("=== FSM Player Test ===");
        $display("Collecting 256 samples...");

        // 收集 256 个样本
        // 273 有 15ns 输出延迟, 需等待足够时间
        for (i = 0; i < 256; i = i + 1) begin
            @(posedge CLK);
            #20;
            samples[i] = DATA_OUT;
        end

        $display("\n=== Results ===");
        $display("First 16 samples:");
        for (i = 0; i < 16; i = i + 1) begin
            $display("  [%2d] 0x%04X", i, samples[i]);
        end

        // 验证: sample[i] 应等于 rom[i] (0x00-0xFF)
        is_ok = 1'b1;
        for (i = 0; i < 256; i = i + 1) begin
            expected = i;
            if (samples[i][7:0] !== expected[7:0]) begin
                is_ok = 1'b0;
                $display("ERROR: Sample %0d expected 0x%02X, got 0x%02X",
                         i, expected, samples[i][7:0]);
            end
        end

        if (is_ok)
            $display("PASS: Output matches ROM 0x00-0xFF pattern");
        else
            $display("FAIL: Output mismatch");

        $display("=== Test Complete ===");
        $finish;
    end

endmodule
