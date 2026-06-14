// wt3_spfm_bus_tb.v — SPFM 总线接口独立验证
// 只验证 373/174/377 + RAM 写入读取

`timescale 1ns/1ps

module wt3_spfm_bus_tb;

    reg CLK, RST_n;
    reg [7:0] D;
    reg A0, CS_n, WR_n, RD_n;

    wire [7:0] reg_addr, reg_data;
    wire addr_wr_pulse, data_wr_pulse;

    wt3_spfm_bus u_spfm (
        .CLK(CLK), .RST_n(RST_n),
        .D(D), .A0(A0),
        .CS_n(CS_n), .WR_n(WR_n), .RD_n(RD_n),
        .reg_addr(reg_addr), .reg_data(reg_data),
        .addr_wr_pulse(addr_wr_pulse),
        .data_wr_pulse(data_wr_pulse)
    );

    // 仿真用 RAM (data_wr_pulse 上升沿写入)
    reg [7:0] test_ram [0:15];
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            test_ram[i] = 8'h00;
    end

    reg data_wr_prev = 1'b0;
    always @(posedge CLK) begin
        if (!data_wr_prev && data_wr_pulse)
            test_ram[reg_addr] <= reg_data;
        data_wr_prev <= data_wr_pulse;
    end

    // 时钟 10MHz
    initial CLK = 0;
    always #50 CLK = ~CLK;

    initial begin
        RST_n = 0; CS_n = 1; WR_n = 1; RD_n = 1; A0 = 0; D = 8'h00;

        #500;
        RST_n = 1;
        #500;

        $display("=== SPFM Bus Test ===");

        // 写地址 0x02, 数据 0xAA
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 0; D = 8'h02;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 1; D = 8'hAA;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        $display("Wrote addr=0x02 data=0xAA  reg_addr=0x%02X reg_data=0x%02X addr_wr_p=%b data_wr_p=%b",
            reg_addr, reg_data, addr_wr_pulse, data_wr_pulse);

        // 写地址 0x05, 数据 0x55
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 0; D = 8'h05;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 1; D = 8'h55;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        $display("Wrote addr=0x05 data=0x55");

        // 写地址 0x0E, 数据 0xFF
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 0; D = 8'h0E;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        @(negedge CLK);
        CS_n = 0; WR_n = 0; A0 = 1; D = 8'hFF;
        repeat(3) @(posedge CLK);
        CS_n = 1; WR_n = 1;
        repeat(3) @(posedge CLK);
        $display("Wrote addr=0x0E data=0xFF");

        #1000;

        $display("=== Readback ===");
        for (i = 0; i < 16; i = i + 1)
            $display("RAM[0x%02X] = 0x%02X", i, test_ram[i]);

        if (test_ram[2] === 8'hAA &&
            test_ram[5] === 8'h55 &&
            test_ram[14] === 8'hFF)
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

endmodule
