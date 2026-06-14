// wt3_core_tb.v — 161 + 单片 ROM + 157 + 62256 + 377 核心验证
// SPFM 写入参数, 微码循环读 RAM, 377 锁存输出验证

`timescale 1ns/1ps

module wt3_core_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [7:0] reg_out;

    wt3_core u_dut (
        .STEP_CLK(STEP_CLK),
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .reg_out(reg_out)
    );

    initial STEP_CLK = 0;
    always #162.5 STEP_CLK = ~STEP_CLK;

    initial SPFM_CLK = 0;
    always #50 SPFM_CLK = ~SPFM_CLK;

    integer pass, fail;

    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
    begin
        @(negedge SPFM_CLK);
        SPFM_CS_n = 0; SPFM_WR_n = 0; SPFM_A0 = 0; SPFM_D = addr;
        repeat(5) @(posedge SPFM_CLK);
        SPFM_CS_n = 1; SPFM_WR_n = 1;
        repeat(5) @(posedge SPFM_CLK);
        @(negedge SPFM_CLK);
        SPFM_CS_n = 0; SPFM_WR_n = 0; SPFM_A0 = 1; SPFM_D = data;
        repeat(5) @(posedge SPFM_CLK);
        SPFM_CS_n = 1; SPFM_WR_n = 1;
        repeat(5) @(posedge SPFM_CLK);
    end
    endtask

    task wait_step;
        input [4:0] target;
    begin
        @(negedge STEP_CLK);
        while (u_dut.step !== target) @(negedge STEP_CLK);
        #200;  // 等 62256 tAA + 377 tpd
    end
    endtask

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;
        pass = 0; fail = 0;

        #1000;
        SPFM_RST_n = 1;
        #1000;

        $display("=== WT3 Core Test ===");

        // SPFM 写入
        $display("SPFM write...");
        spfm_write(8'h00, 8'hAA);
        spfm_write(8'h01, 8'h55);
        spfm_write(8'h02, 8'h3C);
        spfm_write(8'h0A, 8'hDE);
        spfm_write(8'h0E, 8'hF0);
        spfm_write(8'h05, 8'h11);

        // 等两轮微码
        #25000;

        // 验证 latch 输出
        $display("Verify:");
        // step 1: latch RAM[0x00]
        wait_step(5'd1);
        if (reg_out === 8'hAA) begin $display("  step 1: 0xAA OK"); pass = pass + 1;
        end else begin $display("  step 1: 0x%02X FAIL", reg_out); fail = fail + 1; end

        // step 3: latch RAM[0x01]
        wait_step(5'd3);
        if (reg_out === 8'h55) begin $display("  step 3: 0x55 OK"); pass = pass + 1;
        end else begin $display("  step 3: 0x%02X FAIL", reg_out); fail = fail + 1; end

        // step 5: latch RAM[0x02]
        wait_step(5'd5);
        if (reg_out === 8'h3C) begin $display("  step 5: 0x3C OK"); pass = pass + 1;
        end else begin $display("  step 5: 0x%02X FAIL", reg_out); fail = fail + 1; end

        // step 7: latch RAM[0x0A]
        wait_step(5'd7);
        if (reg_out === 8'hDE) begin $display("  step 7: 0xDE OK"); pass = pass + 1;
        end else begin $display("  step 7: 0x%02X FAIL", reg_out); fail = fail + 1; end

        // step 9: latch RAM[0x0E]
        wait_step(5'd9);
        if (reg_out === 8'hF0) begin $display("  step 9: 0xF0 OK"); pass = pass + 1;
        end else begin $display("  step 9: 0x%02X FAIL", reg_out); fail = fail + 1; end

        // step 11: latch RAM[0x05]
        wait_step(5'd11);
        if (reg_out === 8'h11) begin $display("  step 11: 0x11 OK"); pass = pass + 1;
        end else begin $display("  step 11: 0x%02X FAIL", reg_out); fail = fail + 1; end

        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0) $display("PASS"); else $display("FAIL");

        $finish;
    end

endmodule
