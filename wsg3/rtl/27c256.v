// 27c256.v — 27C256 32KB EPROM
//
// 27C256 — 28-pin DIP 封装
// 32K × 8 位 EPROM, 150ns 访问时间
//
// 引脚映射 (DIP-28):
//   Pin  1-15: A14-A0 (地址)
//   Pin 16-23: DQ0-DQ7 (数据, 双向)
//   Pin 24: A15 (地址)
//   Pin 25: /CE (片选使能, 低有效)
//   Pin 26: /OE (输出使能, 低有效)
//   Pin 27: PGM/A16 (编程/A16)
//   Pin 28: VDD
//   Pin 14: GND
//
// 功能: EPROM, 读取模式下 DQ 输出数据

`timescale 1ns/1ps

module hc27c256 #(
    parameter ADDR_WIDTH = 15,
    parameter DATA_WIDTH = 8,
    parameter MEM_FILE = ""
)(
    input  wire [ADDR_WIDTH-1:0] A,
    inout  wire [DATA_WIDTH-1:0] DQ,
    input  wire                   CE_n,
    input  wire                   OE_n,
    input  wire                   WE_n  // 写使能 (仅用于编程模式)
);

    // 32KB 存储阵列
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    // 初始化: 从文件加载
    initial begin
        if (MEM_FILE != "") begin
            $display("Loading 27C256 from %s...", MEM_FILE);
            $readmemh(MEM_FILE, mem);
        end else begin
            // 默认全 0
            for (integer i = 0; i < (1<<ADDR_WIDTH); i = i + 1) begin
                mem[i] = 8'h00;
            end
        end
    end

    // 三态输出缓冲
    reg [DATA_WIDTH-1:0] do_data;
    reg oe_valid;

    always @(A or CE_n or OE_n) begin
        if (CE_n == 1'b0 && OE_n == 1'b0) begin
            do_data = mem[A];
            oe_valid = 1'b1;
        end else begin
            oe_valid = 1'b0;
        end
    end

    // 输出使能
    assign DQ = oe_valid ? do_data : {DATA_WIDTH{1'bz}};

    // 写入 (仅用于编程模式)
    always @(negedge WE_n) begin
        if (CE_n == 1'b0) begin
            mem[A] = DQ;
        end
    end

endmodule
