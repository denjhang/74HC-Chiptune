//==============================================================================
// miniglow_sim.c —— miniglow CPU 指令级仿真器
//------------------------------------------------------------------------------
// 目的：
//   1. 严格按 miniglow ISA 实现，与 iverilog RTL 仿真逐拍对拍
//   2. 快速跑测试程序（比 iverilog 快几百倍），支持大规模回归
//   3. 后续加指令/时钟统计，为协处理器集成和 SCC 算法提供验证平台
//
// 风格对齐：Glowworm-1/sim/glowworm_sim.c（萤火虫原版仿真器）
//   区别：miniglow 用字寻址 PC（+1 步进），SRAM 统一 512KB，ALU 直接 ADD/SUB
//
// ISA（16 位定长，机器码 {opcode[7:0], xx[7:0]}）：
//   源（高 4 位）：0=imm 1=ALU 3=RAM 4=IO0(=IO_OUT)
//   目的（低 4 位）：1=A 2=RA_L 3=RA_H 6=B 8=RAM A=IO0(=IO_OUT)
//   跳转：07=JMP 17=JCC(SUB判零) FF=NOP
//   段选：0CXX = SEG<-xx[2:0]
//
// 地址空间（19 位 = SEG[2:0] + RA[15:0]）：
//   SEG=0 程序, SEG=1 RF/变量, SEG=2 参数, SEG=3 FT232H通信, SEG=4 协处理器
//
// 编译：gcc -O2 -Wall -o miniglow_sim miniglow_sim.c
// 用法：./miniglow_sim prog.bin [max_cycles] [-v] [-trace start end] [-check a_val io_out_val]
//==============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

//---------- 配置 ----------
#define PROG_ROM_SIZE 65536     // 64K 字（16 位指令），与 RTL 一致
#define SRAM_SIZE     524288    // 512KB（19 位地址）

//---------- 状态 ----------
static uint16_t prog_rom[PROG_ROM_SIZE];   // 程序 ROM（16 位字）
static uint8_t  sram[SRAM_SIZE];           // 统一 SRAM（SEG+RA 映射）

static uint16_t pc;            // 程序计数器（字地址，+1 步进）
static uint8_t  A, B;
static uint8_t  RA_L, RA_H;    // RA 16 位（高/低字节）
static uint8_t  SEG;           // 段寄存器（3 位）
static uint8_t  IO_OUT;        // CPU → FT232H（SEG=3 段 RA=0 写）
static uint8_t  IO_IN;         // FT232H → CPU（SEG=3 段 RA=1 读）
static uint8_t  AUDIO_OUT;     // CPU → TLC7524 DAC（IO0 = sample，机器码 0Axx，独立音频口）

// 协处理器接口（dummy，和 TB 一致）
static uint8_t  cp_reg_data = 0;
static uint8_t  cp_out_l    = 0;

// 统计
static uint64_t cycle_count = 0;
static uint64_t insn_count  = 0;
static uint64_t stat_by_op[256];

//---------- 调试 ----------
static int      verbose = 0;
static uint64_t trace_start = 0, trace_end = 0;
static int      trace_on = 0;

//---------- 检查点（自动对拍）----------
static int      check_enable = 0;
static uint8_t  check_a      = 0;
static uint8_t  check_audio  = 0;   // 检查 AUDIO_OUT（音频输出口）

//---------- 工具 ----------
// 19 位地址合成（与 RTL 一致：{SEG, RA_H, RA_L}）
static inline uint32_t make_addr(void) {
    return ((uint32_t)SEG << 16) | ((uint32_t)RA_H << 8) | RA_L;
}

// ALU（HC283 + HC86 实现 ADD/SUB，与 RTL 一致）
//   xx=0 → ADD：A + B
//   xx=1 → SUB：A + (~B) + 1 = A - B
static inline uint8_t alu_compute(uint8_t xx_mode) {
    if (xx_mode == 0x01) {
        return A - B;          // SUB
    }
    return A + B;              // ADD（默认）
}

// 协处理器读（SEG=4 段 RA<8）
//   CP_REG_IDX=0: TYPE=0xAA; =5: OUT_L; 其他: 0
static uint8_t cp_read(uint8_t idx) {
    if (idx == 0) return 0xAA;
    if (idx == 5) return cp_out_l;
    return 0;
}

// 协处理器写（SEG=4 段 RA<8）
//   CP_REG_IDX=2: REG_DATA; =3: START(触发 out_l = ~REG_DATA)
static void cp_write(uint8_t idx, uint8_t data) {
    if (idx == 2) cp_reg_data = data;
    else if (idx == 3) cp_out_l = ~cp_reg_data;   // dummy: START 计算
}

// FT232H 通信段读（SEG=3 段 RA<3）
//   RA=0: IO_OUT; RA=1: IO_IN; RA=2: STATUS=0x01
static uint8_t comm_read(uint8_t idx) {
    if (idx == 0) return IO_OUT;
    if (idx == 1) return IO_IN;
    return 0x01;
}

//---------- 反汇编（trace 用）----------
static const char *disasm(uint8_t opcode, uint8_t xx) {
    static char buf[64];
    uint8_t src = opcode >> 4;
    uint8_t dst = opcode & 0xF;
    const char *dst_name[] = {"RF","A","RA_L","RA_H","A2","RA","B","PC","RAM","ALU","IO_OUT","IO1"};
    const char *src_name[] = {"imm","ALU","RF","RAM","IO_OUT","IO1"};

    if (opcode == 0x07) { snprintf(buf, sizeof buf, "JMP RA"); return buf; }
    if (opcode == 0x17) { snprintf(buf, sizeof buf, "JCC_SUB RA (if A==B)"); return buf; }
    if (opcode == 0xFF) { snprintf(buf, sizeof buf, "NOP"); return buf; }
    if (opcode == 0x0C) { snprintf(buf, sizeof buf, "SEG = 0x%X", xx & 7); return buf; }

    if (src == 0) {
        snprintf(buf, sizeof buf, "%s = 0x%02X", dst_name[dst], xx);
    } else if (src == 1) {
        snprintf(buf, sizeof buf, "%s = ALU[%s](=0x%02X)",
                 dst_name[dst], xx==0?"ADD":(xx==1?"SUB":"?"), alu_compute(xx));
    } else {
        snprintf(buf, sizeof buf, "%s = %s", dst_name[dst], src_name[src]);
    }
    return buf;
}

//---------- 单步执行 ----------
static void step(void) {
    uint16_t ir = prog_rom[pc & 0xFFFF];
    uint8_t  opcode = ir >> 8;
    uint8_t  xx     = ir & 0xFF;
    uint8_t  src    = opcode >> 4;
    uint8_t  dst    = opcode & 0xF;

    cycle_count++;
    insn_count++;
    stat_by_op[opcode]++;

    if (trace_on && cycle_count >= trace_start && cycle_count <= trace_end) {
        printf("[%6lu] PC=%04X IR=%04X op=%02X xx=%02X | A=%02X B=%02X RA=%02X%02X SEG=%X AUDIO=%02X IO_OUT=%02X | %s\n",
               (unsigned long)cycle_count, pc, ir, opcode, xx,
               A, B, RA_H, RA_L, SEG, AUDIO_OUT, IO_OUT, disasm(opcode, xx));
    }

    // 指令分类
    int is_JMP = (opcode == 0x07);
    int is_JCC = (opcode == 0x17);
    int is_NOP = (opcode == 0xFF);
    int is_SEG = (opcode == 0x0C);

    // 段选
    if (is_SEG) {
        SEG = xx & 7;
        pc++;
        return;
    }
    if (is_NOP) {
        pc++;
        return;
    }

    // 跳转
    if (is_JMP) {
        pc = ((uint16_t)RA_H << 8) | RA_L;
        return;
    }
    uint8_t alu_out = alu_compute(xx);
    int     alu_zero = (alu_out == 0);
    if (is_JCC) {
        // 17XX: SUB 后判零，相等（zero）则跳
        if (alu_zero) pc = ((uint16_t)RA_H << 8) | RA_L;
        else          pc++;
        return;
    }

    // 数据指令：先算源（DB 值）
    uint8_t db;
    uint32_t addr = make_addr();
    int seg3_comm = (SEG == 3) && (RA_H == 0) && ((RA_L & 0xF8) == 0);
    int seg4_cp   = (SEG == 4) && (RA_H == 0) && ((RA_L & 0xF8) == 0);

    switch (src) {
        case 0: db = xx; break;                          // imm
        case 1: db = alu_out; break;                     // ALU
        case 3: // RAM
            if (seg4_cp)        db = cp_read(RA_L & 7);
            else if (seg3_comm) db = comm_read(RA_L & 7);
            else                db = sram[addr & (SRAM_SIZE-1)];
            break;
        case 4: db = AUDIO_OUT; break;                   // IO0 当源 = 读上次写的音频值（影子）
        default: db = 0; break;
    }

    // 目的写入
    int dst_is_ram_write = (dst == 8);
    if (dst_is_ram_write) {
        if (seg4_cp)        cp_write(RA_L & 7, db);
        else if (seg3_comm) { if ((RA_L & 7) == 0) IO_OUT = db; }
        else                sram[addr & (SRAM_SIZE-1)] = db;
    } else {
        switch (dst) {
            case 1: A     = db; break;
            case 2: RA_L  = db; break;
            case 3: RA_H  = db; break;
            case 6: B     = db; break;
            case 0xA: AUDIO_OUT = db; break;             // IO0 = xx → 音频输出口
            default: break;
        }
    }

    pc++;
}

//---------- 加载程序（hex 格式：每行一个 16 位字，地址 值）----------
// 格式：@ADDR VALUE  （ADDR 是字地址，VALUE 是 4 位 hex）
// 也支持纯二进制（每 2 字节一个字，大端）
static int load_prog(const char *fname) {
    FILE *fp = fopen(fname, "r");
    if (!fp) { perror(fname); return -1; }

    // 判断格式：首字符是 '@' 或数字
    int c = fgetc(fp);
    ungetc(c, fp);

    // 判断格式：跳过开头的注释/空白行，看第一个有效字符
    // hex 格式：每行 '@' 或数字开头；二进制格式：任意字节
    int peek = fgetc(fp);
    while (peek == '#' || peek == ';' || peek == '\n' || peek == '\r' || peek == ' ' || peek == '\t') {
        // 跳到行尾
        while (peek != '\n' && peek != EOF) peek = fgetc(fp);
        peek = fgetc(fp);
    }
    if (peek != EOF) ungetc(peek, fp);
    c = peek;

    if (c == '@' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
        // hex 格式：@addr value 或 addr value 或 value（按序）
        char line[256];
        int seq = 0;   // 顺序地址
        while (fgets(line, sizeof line, fp)) {
            uint32_t addr;
            uint32_t val;
            if (line[0] == '#' || line[0] == ';' || line[0] == '\n') continue;
            if (sscanf(line, "@%x %x", &addr, &val) == 2) {
                prog_rom[addr & 0xFFFF] = val & 0xFFFF;
            } else if (sscanf(line, "%x %x", &addr, &val) == 2) {
                prog_rom[addr & 0xFFFF] = val & 0xFFFF;
            } else if (sscanf(line, "%x", &val) == 1) {
                prog_rom[seq & 0xFFFF] = val & 0xFFFF;
                seq++;
            }
        }
    } else {
        // 二进制格式（大端：高字节在前）
        fclose(fp);
        fp = fopen(fname, "rb");
        int idx = 0;
        int hi, lo;
        while ((hi = fgetc(fp)) != EOF && (lo = fgetc(fp)) != EOF) {
            prog_rom[idx & 0xFFFF] = ((hi & 0xFF) << 8) | (lo & 0xFF);
            idx++;
        }
    }
    fclose(fp);
    return 0;
}

//---------- 主 ----------
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "miniglow CPU simulator\n"
            "用法: %s prog.hex [max_cycles] [-v] [-trace start end] [-check a io_out]\n"
            "  prog.hex: 程序文件（hex 格式：每行 '地址 值' 或 '@地址 值' 或顺序值）\n"
            "  max_cycles: 最大周期数（默认 10000）\n"
            "  -v: 每条指令打印\n"
            "  -trace start end: 周期 [start,end] 内逐条 trace\n"
            "  -check a audio: 跑完后检查 A 和 AUDIO_OUT 是否匹配，匹配返回 0，否则返回 1\n",
            argv[0]);
        return 2;
    }

    const char *fname = argv[1];
    uint64_t max_cycles = 10000;

    // 初始化 ROM 为 NOP
    for (int i = 0; i < PROG_ROM_SIZE; i++) prog_rom[i] = 0xFFFF;

    if (load_prog(fname) < 0) return 1;

    // 解析参数
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-v") == 0) {
            verbose = 1; trace_on = 1; trace_start = 0; trace_end = ~0ULL;
        } else if (strcmp(argv[i], "-trace") == 0 && i+2 < argc) {
            trace_on = 1;
            sscanf(argv[i+1], "%llu", (unsigned long long*)&trace_start);
            sscanf(argv[i+2], "%llu", (unsigned long long*)&trace_end);
            i += 2;
        } else if (strcmp(argv[i], "-check") == 0 && i+2 < argc) {
            check_enable = 1;
            sscanf(argv[i+1], "%hhx", &check_a);
            sscanf(argv[i+2], "%hhx", &check_audio);   // 第二个值现在是 AUDIO_OUT
            i += 2;
        } else {
            // 数字 = max_cycles
            sscanf(argv[i], "%llu", (unsigned long long*)&max_cycles);
        }
    }

    // 复位状态
    pc = 0; A = 0; B = 0; RA_L = 0; RA_H = 0; SEG = 0; IO_OUT = 0; IO_IN = 0; AUDIO_OUT = 0;

    // 跑
    while (cycle_count < max_cycles) {
        step();
    }

    // 汇总
    printf("===== miniglow_sim summary =====\n");
    printf("cycles=%lu insns=%lu\n", (unsigned long)cycle_count, (unsigned long)insn_count);
    printf("final: PC=%04X A=%02X B=%02X RA=%02X%02X SEG=%X AUDIO_OUT=%02X IO_OUT=%02X\n",
           pc, A, B, RA_H, RA_L, SEG, AUDIO_OUT, IO_OUT);

    if (check_enable) {
        int ok = 1;
        if (A == check_a)
            printf("[PASS] A = 0x%02X\n", A);
        else {
            printf("[FAIL] A = 0x%02X (expect 0x%02X)\n", A, check_a);
            ok = 0;
        }
        if (AUDIO_OUT == check_audio)
            printf("[PASS] AUDIO_OUT = 0x%02X\n", AUDIO_OUT);
        else {
            printf("[FAIL] AUDIO_OUT = 0x%02X (expect 0x%02X)\n", AUDIO_OUT, check_audio);
            ok = 0;
        }
        return ok ? 0 : 1;
    }

    return 0;
}
