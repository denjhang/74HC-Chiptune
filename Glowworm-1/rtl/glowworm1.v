//==============================================================================
// glowworm1.v —— 萤火虫1号 CPU 行为级抽象模型（v2，更准确）
//------------------------------------------------------------------------------
// 从官方指令集 xls/csv + 编译器后端 glow.cpp 反推
// 纯行为抽象，不实例化具体 74 芯片，用 case 实现 ALU（后续可换 SRAM 查表）
//
// 核心架构（编译器反推确认）：
//   * RF 寄存器堆 = 以 RA 为地址的 256B SRAM（RF_SRAM[RA]）
//     （A_ASGN__RF(ra) 编译成 RA=ra; A=RF）
//   * RAM 数据口 = 以 A2A1A0 为地址的 64K×8 数据 SRAM
//   * ALU = 查表：地址 = {A, B}（64K×16），输出低 8 位是结果，bit0 是条件跳转判据
//     ALU 模式号 XX 当段选择（高 4 位地址），具体模式由 alu_rom 内容决定
//     本模型用 case 实现常用 ALU 函数（ADD/SUB/AND/OR/XOR/...），不做真实查表
//
// 16 位指令 {opcode, xx}：
//   高 4 位 = 源选择：0=imm 1=ALU 2=RF 3=RAM 4=IO0 5=IO1
//   低 4 位 = 目的选择：0=RF 1=A 2=A0 3=A1 4=A2 5=RA 6=B 7=PC 8=RAM 9=ALU A=IO0 B=IO1
//   特殊：07=JMP A2A1A0, 17=JCC (!ALU.bit0), FF= NOP（实际 FFFF）
//==============================================================================
module glowworm1 #(
    parameter PROG_AW = 16,    // 程序 ROM 地址位宽
    parameter RF_AW   = 8,     // RF SRAM 地址位宽（256B）
    parameter DATA_AW = 16     // 数据 RAM 地址位宽（64K）
)(
    input  wire        clk,
    input  wire        rst_n,

    // IO 端口（IO0/IO1 各 8 位双向，简化为输出锁存 + 输入采样）
    output reg  [7:0]  io0_o,
    input  wire [7:0]  io0_i,
    output reg         io0_oe,    // 1=输出模式，0=输入模式
    output reg  [7:0]  io1_o,
    input  wire [7:0]  io1_i,
    output reg         io1_oe,

    // 调试接口（仅仿真）
    output wire [23:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire [7:0]  dbg_A,
    output wire [7:0]  dbg_B,
    output wire [7:0]  dbg_RA,
    output wire [23:0] dbg_A2A1A0,
    output wire [7:0]  dbg_rf_qa,
    output wire [15:0] dbg_alu_q
);

    //--------------------------------------------------------------------------
    // 寄存器
    //--------------------------------------------------------------------------
    reg [23:0] pc;
    reg [7:0]  A, B, RA;
    reg [7:0]  A0, A1, A2;
    reg [7:0]  IO0_r, IO1_r;
    reg        IO0_is_oe, IO1_is_oe;   // 1=上次写过（输出态）

    reg [15:0] ir;
    wire [7:0] opcode = ir[15:8];
    wire [7:0] xx     = ir[7:0];
    wire [3:0] src_hi = opcode[7:4];
    wire [3:0] dst_lo = opcode[3:0];

    //--------------------------------------------------------------------------
    // 存储器
    //--------------------------------------------------------------------------
    reg [15:0] prog_rom [0:(1<<PROG_AW)-1];
    reg [7:0]  rf_ram   [0:(1<<RF_AW)-1];
    reg [7:0]  data_ram [0:(1<<DATA_AW)-1];

    wire [23:0] A2A1A0 = {A2, A1, A0};

    wire [7:0]  rf_rd  = rf_ram[RA];
    wire [7:0]  ram_rd = data_ram[A2A1A0[DATA_AW-1:0]];

    //--------------------------------------------------------------------------
    // ALU（行为实现，不做真实查表）
    //   地址 = {A, B}（16 位），模式由 XX 选
    //   本模型实现的 ALU 函数（与 glow.cpp 的 ALU_ADD/ALU_EQUAL_C 等对应）：
    //     xx=0x00: ADD        (A+B, bit0=进位)
    //     xx=0x01: SUB        (A-B, bit0=借位)
    //     xx=0x02: AND        (A&B)
    //     xx=0x03: OR         (A|B)
    //     xx=0x04: XOR        (A^B)
    //     xx=0x05: EQUAL_C    (A==B?1:0 装到 bit0)
    //     xx=0x06: A_ADD_1    (A+1, bit0=溢出到 0)
    //     其他: 默认 ADD
    //   输出 16 位：低 8 位是运算结果，bit0 用于条件跳转判据（17XX 指令看这个）
    //
    //   注意：xx 段如何映射到 ALU 函数，需对照 glow_cpu_init 生成的 ALU 表
    //   验证；本模型先按上表，TB 测试时会校准。
    //--------------------------------------------------------------------------
    function [15:0] alu_func;
        input [7:0] a_in, b_in, mode;
        reg [8:0] sum;
        reg [8:0] diff;
        begin
            sum  = {1'b0, a_in} + {1'b0, b_in};
            diff = {1'b0, a_in} - {1'b0, b_in};
            case (mode)
                8'h00: alu_func = {7'b0, sum[8], sum[7:0]};          // ADD，bit0=进位（这里用 bit8 当标志位，TB 校准）
                8'h01: alu_func = {7'b0, (~diff[8]), diff[7:0]};     // SUB，bit0=无借位（A>=B 时为 1）
                8'h02: alu_func = {8'b0, a_in & b_in};
                8'h03: alu_func = {8'b0, a_in | b_in};
                8'h04: alu_func = {8'b0, a_in ^ b_in};
                8'h05: alu_func = {15'b0, (a_in == b_in) ? 1'b1 : 1'b0}; // EQUAL，bit0=相等(1)，不等(0)
                8'h06: alu_func = {7'b0, (a_in == 8'hFF) ? 1'b1 : 1'b0, a_in + 8'd1}; // A+1，bit0=溢出
                default: alu_func = {7'b0, sum[8], sum[7:0]};
            endcase
        end
    endfunction

    wire [15:0] alu_rd = alu_func(A, B, xx);

    //--------------------------------------------------------------------------
    // 主时序
    //--------------------------------------------------------------------------
    wire [7:0] src_data =
        (src_hi == 4'h0) ? xx        :
        (src_hi == 4'h1) ? alu_rd[7:0] :
        (src_hi == 4'h2) ? rf_rd     :
        (src_hi == 4'h3) ? ram_rd    :
        (src_hi == 4'h4) ? io0_i     :
        (src_hi == 4'h5) ? io1_i     : 8'hxx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 24'd0;
            A <= 0; B <= 0; RA <= 0;
            A0 <= 0; A1 <= 0; A2 <= 0;
            IO0_r <= 8'hFF; IO1_r <= 8'hFF;
            IO0_is_oe <= 1'b0; IO1_is_oe <= 1'b0;
            io0_o <= 8'hFF; io1_o <= 8'hFF;
            io0_oe <= 1'b0; io1_oe <= 1'b0;
            ir <= 16'hFFFF;
        end else begin
            ir <= prog_rom[pc[PROG_AW-1:0]];

            //---------- 跳转 / NOP / 普通 ----------
            if (opcode == 8'h07) begin
                pc <= A2A1A0;                          // JMP
            end
            else if (opcode == 8'h17) begin
                if (alu_rd[0] == 1'b0) pc <= A2A1A0;   // JCC: ALU.bit0==0 跳
                else                   pc <= pc + 24'd1;
            end
            else if (opcode == 8'hFF) begin
                pc <= pc + 24'd1;                      // NOP
            end
            else begin
                case (dst_lo)
                    4'h0: rf_ram[RA]              <= src_data;   // RF
                    4'h1: A                       <= src_data;
                    4'h2: A0                      <= src_data;
                    4'h3: A1                      <= src_data;
                    4'h4: A2                      <= src_data;
                    4'h5: RA                      <= src_data;
                    4'h6: B                       <= src_data;
                    4'h7: pc <= A2A1A0;                          // PC（普通跳转，备用）
                    4'h8: data_ram[A2A1A0[DATA_AW-1:0]] <= src_data; // RAM
                    4'h9: begin
                        // ALU[XX] = 源：把源数据喂进 ALU 输入。
                        // 编译器用法 ALU_ASGN__RF(op,ra) = RA=ra; ALU[op]=RF;
                        //   即把 RF[ra] 写进 ALU 输入。本模型把 ALU 输入固定为 A、B，
                        //   xx 的某 bit 决定写 A 还是 B。简化：默认写 A。
                        A <= src_data;
                    end
                    4'hA: begin IO0_r <= src_data; IO0_is_oe <= 1'b1; io0_o <= src_data; io0_oe <= 1'b1; end
                    4'hB: begin IO1_r <= src_data; IO1_is_oe <= 1'b1; io1_o <= src_data; io1_oe <= 1'b1; end
                    default: ;
                endcase
                pc <= pc + 24'd1;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 调试
    //--------------------------------------------------------------------------
    assign dbg_pc     = pc;
    assign dbg_ir     = ir;
    assign dbg_A      = A;
    assign dbg_B      = B;
    assign dbg_RA     = RA;
    assign dbg_A2A1A0 = A2A1A0;
    assign dbg_rf_qa  = rf_rd;
    assign dbg_alu_q  = alu_rd;

endmodule
