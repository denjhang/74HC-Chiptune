// wsg3_channel_tb.v — RAM + 273 测试

`timescale 1ns/1ps

module wsg3_channel_tb;
    reg CLK, RST_n;
    reg [7:0] reg_addr;
    reg [7:0] reg_data;
    reg ram_we_n;
    reg [7:0] phase_acc;
    reg [7:0] wave_data;

    wire [7:0] ram_out;
    wire [7:0] dac_out;

    wsg3_channel u_channel (
        .CLK(CLK),
        .RST_n(RST_n),
        .reg_addr(reg_addr),
        .reg_data(reg_data),
        .ram_we_n(ram_we_n),
        .phase_acc(phase_acc),
        .wave_data(wave_data),
        .ram_out(ram_out),
        .dac_out(dac_out)
    );

    initial CLK = 0;
    always #50 CLK = ~CLK;

    initial begin
        $display("=== WSG3 Channel (RAM + 273) Test ===");
        RST_n = 0;
        reg_addr = 8'h00;
        reg_data = 8'h00;
        ram_we_n = 1;
        phase_acc = 8'h00;
        wave_data = 8'h00;

        #100;
        RST_n = 1;
        #100;

        // 测试 1: 写 RAM 地址 0x05 = 0xAB
        $display("Test 1: Write RAM[0x05] = 0xAB");
        reg_addr = 8'h05;
        reg_data = 8'hAB;
        ram_we_n = 0;
        #200;
        ram_we_n = 1;
        #200;

        // 读 RAM
        reg_addr = 8'h05;
        #100;
        if (ram_out == 8'hAB)
            $display("PASS: RAM[0x05] = 0xAB");
        else
            $display("FAIL: RAM[0x05] = 0x%02X (expected 0xAB)", ram_out);

        // 测试 2: 273 锁存波形数据
        $display("Test 2: Latch wave_data = 0xCD to 273");
        wave_data = 8'hCD;
        #200;
        if (dac_out == 8'hCD)
            $display("PASS: dac_out = 0xCD");
        else
            $display("FAIL: dac_out = 0x%02X (expected 0xCD)", dac_out);

        $display("=== Test Complete ===");
        $finish;
    end

endmodule
