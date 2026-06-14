// sq_tb.v — 一通道方波 testbench (SPFM 总线接口)
//
// SPFM 主时钟: 1.789773 MHz (PSG 标准)
// 协议: 主机写 addr (A0=0) + 写 data (A0=1) → 触发 data_wr 锁存

`timescale 1ns/1ps

module sq_tb;

    reg SPFM_CLK;
    reg SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0;
    reg SPFM_CS_n;
    reg SPFM_WR_n;
    reg SPFM_RD_n;

    wire sq_out;

    sq_top u_dut (
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .sq_out(sq_out)
    );

    // 主时钟: 1.789773 MHz → 周期 558.73 ns
    initial SPFM_CLK = 0;
    always #279.36 SPFM_CLK = ~SPFM_CLK;

    // SPFM 写: 先写 addr (A0=0), 再写 data (A0=1)
    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
        begin
            SPFM_CS_n = 0; SPFM_WR_n = 0;
            SPFM_A0 = 0; SPFM_D = addr;
            #2000;
            SPFM_CS_n = 1; SPFM_WR_n = 1;
            #2000;
            SPFM_CS_n = 0; SPFM_WR_n = 0;
            SPFM_A0 = 1; SPFM_D = data;
            #2000;
            SPFM_CS_n = 1; SPFM_WR_n = 1;
            #2000;
        end
    endtask

    task write_freq;
        input [15:0] f;
        begin
            spfm_write(8'd0, f[7:0]);    // 低字节, addr=0
            spfm_write(8'd1, f[15:8]);   // 高字节, addr=1
        end
    endtask

    integer f_csv;
    integer sample_count;

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1; SPFM_RD_n = 1;
        SPFM_A0 = 0; SPFM_D = 8'h00;

        #5000;
        SPFM_RST_n = 1;
        #5000;

        $display("=== sq_top Testbench (SPFM) ===");

        // C4 261.6 Hz @ 1.789773 MHz: FREQ = 65536 - 3419 = 0xF2A5
        write_freq(16'hF2A5);
        $display("--- C4 261.6 Hz, FREQ=0xF2A5 ---");

        // 采样 900,000 STEP ≈ 0.503 秒实时
        f_csv = $fopen("sq_output.csv", "w");
        $fwrite(f_csv, "sample,sq_out\n");

        for (sample_count = 0; sample_count < 900000; sample_count = sample_count + 1) begin
            @(posedge SPFM_CLK);
            #10;
            $fwrite(f_csv, "%0d,%0d\n", sample_count, sq_out);
        end

        $fclose(f_csv);
        $display("--- Done ---");
        $finish;
    end

endmodule
