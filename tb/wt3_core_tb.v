// wt3_core_tb.v — 161 + 单 ROM + 157×2 + 62256 + 377×3 + 283 核心验证
// SPFM 写入 phase_acc + phase_step, 微码循环执行 4-bit 相位累加

`timescale 1ns/1ps

module wt3_core_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [7:0] reg_a_q;
    wire [7:0] reg_b_q;
    wire [3:0] adder_s;

    wt3_core u_dut (
        .STEP_CLK(STEP_CLK),
        .SPFM_CLK(SPFM_CLK),
        .SPFM_RST_n(SPFM_RST_n),
        .SPFM_D(SPFM_D),
        .SPFM_A0(SPFM_A0),
        .SPFM_CS_n(SPFM_CS_n),
        .SPFM_WR_n(SPFM_WR_n),
        .SPFM_RD_n(SPFM_RD_n),
        .reg_a_q(reg_a_q),
        .reg_b_q(reg_b_q),
        .adder_s(adder_s)
    );

    initial STEP_CLK = 0;
    always #162.5 STEP_CLK = ~STEP_CLK;  // ~3.08 MHz, 96kHz × 32 步

    initial SPFM_CLK = 0;
    always #50 SPFM_CLK = ~SPFM_CLK;  // 10 MHz

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

    initial begin
        SPFM_RST_n = 0; SPFM_CS_n = 1; SPFM_WR_n = 1;
        SPFM_RD_n = 1; SPFM_A0 = 0; SPFM_D = 8'h00;
        pass = 0; fail = 0;

        #1000;
        SPFM_RST_n = 1;
        #1000;

        $display("=== WT3 Core (283 accumulate) Test ===");

        // SPFM 写入 phase_acc=0x03 (RAM[0]), phase_step=0x02 (RAM[1])
        $display("SPFM write phase_acc=0x03, phase_step=0x02...");
        spfm_write(8'h00, 8'h03);
        spfm_write(8'h01, 8'h02);

        // 等微码至少跑 1 个完整 32-step 周期 (32 × 325ns ≈ 10.4us)
        // + 1 个完整周期, 让 latch_a + latch_b + write_back 完成
        #11000;

        $display("After 1 cycle, checking reg_a/reg_b:");
        $display("  reg_a_q = 0x%02X (expect 0x03)", reg_a_q);
        $display("  reg_b_q = 0x%02X (expect 0x02)", reg_b_q);
        $display("  adder_s = 0x%01X (expect 0x5 = 3+2)", adder_s);

        if (reg_a_q[3:0] === 4'h3) begin
            $display("  reg_a[3:0]=0x3 OK"); pass = pass + 1;
        end else begin
            $display("  reg_a[3:0]=0x%01X FAIL", reg_a_q[3:0]); fail = fail + 1;
        end

        if (reg_b_q[3:0] === 4'h2) begin
            $display("  reg_b[3:0]=0x2 OK"); pass = pass + 1;
        end else begin
            $display("  reg_b[3:0]=0x%01X FAIL", reg_b_q[3:0]); fail = fail + 1;
        end

        if (adder_s === 4'h5) begin
            $display("  adder_s=0x5 OK"); pass = pass + 1;
        end else begin
            $display("  adder_s=0x%01X FAIL", adder_s); fail = fail + 1;
        end

        // 再等一轮, 验证累加继续: RAM[0]=0x05 → reg_a=0x05 → adder=0x07
        #10500;
        $display("After 2 cycles, reg_a should be 0x05:");
        $display("  reg_a_q = 0x%02X", reg_a_q);
        if (reg_a_q[3:0] === 4'h5) begin
            $display("  reg_a[3:0]=0x5 OK (accumulate working)"); pass = pass + 1;
        end else begin
            $display("  reg_a[3:0]=0x%01X FAIL", reg_a_q[3:0]); fail = fail + 1;
        end

        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0) $display("PASS"); else $display("FAIL");

        $finish;
    end

endmodule
