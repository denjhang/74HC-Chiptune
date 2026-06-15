// spfm_bus_tb.v — SPFM 接口测试
// 验证 373+174+377 能正确锁存地址和数据

`timescale 1ns/1ps

module spfm_bus_tb;
    reg CLK, RST_n;
    reg [7:0] D;
    reg A0, CS_n, WR_n, RD_n;

    wire [7:0] reg_addr;
    wire [7:0] reg_data;
    wire addr_wr_pulse_n;
    wire data_wr_pulse_n;

    // 调试：观察内部信号
    wire le = ~(CS_n | WR_n);
    wire write_active = ~CS_n & ~WR_n & RST_n;
    wire addr_wr_comb = write_active & ~A0;

    // SPFM 接口实例
    wt3_spfm_bus u_spfm (
        .CLK(CLK),
        .RST_n(RST_n),
        .D(D),
        .A0(A0),
        .CS_n(CS_n),
        .WR_n(WR_n),
        .RD_n(RD_n),
        .reg_addr(reg_addr),
        .reg_data(reg_data),
        .addr_wr_pulse_n(addr_wr_pulse_n),
        .data_wr_pulse_n(data_wr_pulse_n)
    );

    // 时钟 10MHz
    initial CLK = 0;
    always #50 CLK = ~CLK;

    // 测试流程
    initial begin
        $display("=== SPFM Bus Test ===");
        RST_n = 0;
        CS_n = 1;
        WR_n = 1;
        RD_n = 1;
        A0 = 0;
        D = 8'h00;

        #100;
        RST_n = 1;
        #500;  // 等待同步链稳定

        // 测试 1: 写地址 0xAB
        $display("Test 1: Write address 0xAB");
        D = 8'hAB;
        A0 = 0;
        #100;
        CS_n = 0;
        WR_n = 0;
        #1000; // 等待同步链稳定
        $display("addr_wr_pulse_n = %b", addr_wr_pulse_n);
        // 等待至少一个时钟边沿，让 377 锁存
        @(posedge CLK);
        #100;
        WR_n = 1;
        CS_n = 1;
        #200;

        if (reg_addr == 8'hAB)
            $display("PASS: reg_addr = 0xAB");
        else
            $display("FAIL: reg_addr = 0x%02X (expected 0xAB)", reg_addr);

        // 测试 2: 写数据 0xCD
        $display("Test 2: Write data 0xCD");
        D = 8'hCD;
        A0 = 1;
        #100;
        CS_n = 0;
        WR_n = 0;
        #100;
        WR_n = 1;
        CS_n = 1;
        #200;

        if (reg_data == 8'hCD)
            $display("PASS: reg_data = 0xCD");
        else
            $display("FAIL: reg_data = 0x%02X (expected 0xCD)", reg_data);

        // 测试 3: 写地址 0x12
        $display("Test 3: Write address 0x12");
        D = 8'h12;
        A0 = 0;
        #100;
        CS_n = 0;
        WR_n = 0;
        #1000;
        @(posedge CLK);
        #100;
        WR_n = 1;
        CS_n = 1;
        #200;

        if (reg_addr == 8'h12)
            $display("PASS: reg_addr = 0x12");
        else
            $display("FAIL: reg_addr = 0x%02X (expected 0x12)", reg_addr);

        $display("=== SPFM Bus Test Complete ===");
        $finish;
    end

endmodule
