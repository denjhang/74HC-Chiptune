// wt3_spfm_mux_tb.v — SPFM + 157 mux + 62256 验证
// SPFM 写入数据, 然后 157 mux 切换到微码地址读出验证

`timescale 1ns/1ps

module wt3_spfm_mux_tb;

    reg CLK, RST_n;
    reg [7:0] D;
    reg A0, CS_n, WR_n, RD_n;

    // 微码接口 (行为模拟)
    reg [7:0] mc_ram_addr;
    reg       mc_oe_n;

    wire [7:0] ram_do;

    wt3_spfm_mux u_dut (
        .CLK(CLK), .RST_n(RST_n),
        .D(D), .A0(A0),
        .CS_n(CS_n), .WR_n(WR_n), .RD_n(RD_n),
        .mc_ram_addr(mc_ram_addr),
        .mc_oe_n(mc_oe_n),
        .ram_do(ram_do)
    );

    // 时钟 10MHz
    initial CLK = 0;
    always #50 CLK = ~CLK;

    integer pass, fail, i;

    // SPFM 写操作
    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
    begin
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 0; D = addr;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 1; D = data;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
    end
    endtask

    // 微码读操作
    task mc_read;
        input  [7:0] addr;
        output [7:0] data;
    begin
        CS_n = 1; WR_n = 1; RD_n = 1;
        mc_ram_addr = addr;
        mc_oe_n = 0;
        repeat(3) @(posedge CLK);
        data = ram_do;
        mc_oe_n = 1;
        repeat(1) @(posedge CLK);
    end
    endtask

    // 验证
    task check;
        input [7:0] addr;
        input [7:0] expected;
        reg [7:0] got;
    begin
        mc_read(addr, got);
        if (got === expected) begin
            $display("  [0x%02X] = 0x%02X OK", addr, got);
            pass = pass + 1;
        end else begin
            $display("  [0x%02X] = 0x%02X EXPECTED 0x%02X FAIL", addr, got, expected);
            fail = fail + 1;
        end
    end
    endtask

    initial begin
        RST_n = 0; CS_n = 1; WR_n = 1; RD_n = 1; A0 = 0; D = 8'h00;
        mc_ram_addr = 8'h00; mc_oe_n = 1;
        pass = 0; fail = 0;

        #500;
        RST_n = 1;
        #500;

        $display("=== SPFM + 157 Mux + 62256 Test ===");

        // Phase 1: SPFM 写入
        $display("Phase 1: SPFM write");
        spfm_write(8'h00, 8'hAA);
        spfm_write(8'h01, 8'h55);
        spfm_write(8'h02, 8'h3C);
        spfm_write(8'h0A, 8'hDE);
        spfm_write(8'h0E, 8'hF0);

        // Phase 2: 微码读出验证
        $display("Phase 2: microcode read");
        check(8'h00, 8'hAA);
        check(8'h01, 8'h55);
        check(8'h02, 8'h3C);
        check(8'h0A, 8'hDE);
        check(8'h0E, 8'hF0);

        // Phase 3: 未写入地址
        $display("Phase 3: unwritten");
        check(8'h03, 8'h00);
        check(8'h0B, 8'h00);

        // Phase 4: 交替写读
        $display("Phase 4: interleaved write/read");
        spfm_write(8'h05, 8'h11);
        check(8'h05, 8'h11);
        check(8'h00, 8'hAA);

        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0)
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

endmodule
