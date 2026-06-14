// wt3_spfm_ram_tb.v — SPFM 总线 + 62256 RAM 验证
// 验证 CPU 通过 SPFM 写入 62256, 再通过 RD_n 读回

`timescale 1ns/1ps

module wt3_spfm_ram_tb;

    reg CLK, RST_n;
    reg [7:0] D;
    reg A0, CS_n, WR_n, RD_n;

    wire [7:0] ram_do;

    wt3_spfm_ram u_dut (
        .CLK(CLK), .RST_n(RST_n),
        .D(D), .A0(A0),
        .CS_n(CS_n), .WR_n(WR_n), .RD_n(RD_n),
        .ram_do(ram_do)
    );

    // 时钟 10MHz
    initial CLK = 0;
    always #50 CLK = ~CLK;

    // SPFM 写操作 task (inline)
    reg [7:0] wr_addr, wr_data;
    integer pass, fail;

    // 写入一个寄存器 (地址+数据)
    task spfm_write;
        input [7:0] addr;
        input [7:0] data;
    begin
        // 写地址
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 0; D = addr;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        // 写数据
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 1; D = data;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
    end
    endtask

    // 读取一个寄存器 (通过 RD_n)
    task spfm_read;
        input  [7:0] addr;
        output [7:0] data;
    begin
        // 写地址
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 0; D = addr;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        // 读数据
        @(negedge CLK);
        CS_n = 0; RD_n = 0; A0 = 1;
        repeat(3) @(posedge CLK);
        data = ram_do;
        CS_n = 1; RD_n = 1;
        repeat(3) @(posedge CLK);
    end
    endtask

    // 验证读回值
    task check;
        input [7:0] addr;
        input [7:0] expected;
        reg [7:0] got;
    begin
        spfm_read(addr, got);
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
        pass = 0; fail = 0;

        #500;
        RST_n = 1;
        #500;

        $display("=== SPFM + 62256 RAM Test ===");

        // 写入 3 个地址
        $display("Writing...");
        spfm_write(8'h00, 8'hAA);
        spfm_write(8'h01, 8'hBB);
        spfm_write(8'h02, 8'h3C);  // wave=0, vol=15
        spfm_write(8'h10, 8'h01);
        spfm_write(8'h1F, 8'hFE);

        // 读回验证
        $display("Readback:");
        check(8'h00, 8'hAA);
        check(8'h01, 8'hBB);
        check(8'h02, 8'h3C);
        check(8'h10, 8'h01);
        check(8'h1F, 8'hFE);

        // 覆写验证
        $display("Overwrite...");
        spfm_write(8'h00, 8'h55);
        check(8'h00, 8'h55);
        check(8'h01, 8'hBB);  // 未被覆盖

        // 未写入地址应为 0x00
        $display("Unwritten:");
        check(8'h03, 8'h00);
        check(8'h05, 8'h00);

        $display("=== Result: %0d pass, %0d fail ===", pass, fail);
        if (fail == 0)
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

endmodule
