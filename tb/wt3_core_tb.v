// wt3_core_tb.v — 161 + 单 ROM + 157×5 + 62256 + 377×3 + 283×2 + 273 核心验证
// SPFM 写入 phase_acc + phase_step, 微码循环执行 8-bit 相位累加, 273 输出

`timescale 1ns/1ps

module wt3_core_tb;

    reg STEP_CLK, SPFM_CLK, SPFM_RST_n;
    reg [7:0] SPFM_D;
    reg SPFM_A0, SPFM_CS_n, SPFM_WR_n, SPFM_RD_n;

    wire [7:0] reg_a_q;
    wire [7:0] reg_b_q;
    wire [7:0] adder_s;
    wire [7:0] dac_out;

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
        .adder_s(adder_s),
        .dac_out(dac_out)
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

        $display("=== WT3 Core (8-bit 283×2 + 273 output) Test ===");

        // SPFM 写入 phase_acc=0x10 (RAM[0]), phase_step=0x20 (RAM[1])
        // 8-bit 累加: 0x10 + 0x20 = 0x30
        $display("SPFM write phase_acc=0x10, phase_step=0x20...");
        spfm_write(8'h00, 8'h10);
        spfm_write(8'h01, 8'h20);

        #11000;

        $display("After 1 cycle:");
        $display("  reg_a_q = 0x%02X (expect 0x10)", reg_a_q);
        $display("  reg_b_q = 0x%02X (expect 0x20)", reg_b_q);
        $display("  adder_s = 0x%02X (expect 0x30 = 0x10+0x20)", adder_s);
        $display("  dac_out = 0x%02X (expect 0x10)", dac_out);

        if (reg_a_q === 8'h10) begin $display("  reg_a=0x10 OK"); pass = pass + 1;
        end else begin $display("  reg_a=0x%02X FAIL", reg_a_q); fail = fail + 1; end

        if (reg_b_q === 8'h20) begin $display("  reg_b=0x20 OK"); pass = pass + 1;
        end else begin $display("  reg_b=0x%02X FAIL", reg_b_q); fail = fail + 1; end

        if (adder_s === 8'h30) begin $display("  adder_s=0x30 OK (8-bit add works)"); pass = pass + 1;
        end else begin $display("  adder_s=0x%02X FAIL", adder_s); fail = fail + 1; end

        if (dac_out === 8'h10) begin $display("  dac_out=0x10 OK (273 latched)"); pass = pass + 1;
        end else begin $display("  dac_out=0x%02X FAIL", dac_out); fail = fail + 1; end

        // 再等一轮: RAM[0]=0x30 → reg_a=0x30 → adder=0x50
        #10500;
        $display("After 2 cycles, reg_a should be 0x30:");
        $display("  reg_a_q = 0x%02X", reg_a_q);
        $display("  dac_out = 0x%02X", dac_out);
        if (reg_a_q === 8'h30) begin $display("  reg_a=0x30 OK (8-bit accumulate)"); pass = pass + 1;
        end else begin $display("  reg_a=0x%02X FAIL", reg_a_q); fail = fail + 1; end

        // 再等一轮: RAM[0]=0x50 → reg_a=0x50 → adder=0x70
        #10500;
        $display("After 3 cycles, reg_a should be 0x50:");
        $display("  reg_a_q = 0x%02X", reg_a_q);
        $display("  dac_out = 0x%02X", dac_out);
        if (reg_a_q === 8'h50) begin $display("  reg_a=0x50 OK"); pass = pass + 1;
        end else begin $display("  reg_a=0x%02X FAIL", reg_a_q); fail = fail + 1; end

        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0) $display("PASS"); else $display("FAIL");

        $finish;
    end

endmodule
