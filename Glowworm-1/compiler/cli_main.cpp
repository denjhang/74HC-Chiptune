//==============================================================================
// cli_main.cpp —— 萤火虫编译器命令行版入口
//------------------------------------------------------------------------------
// 替代 MFC GUI 的 GlowCompiler.cpp / GlowCompilerDlg.cpp
// 复刻 OnBnClickedButton1() 的编译流程：
//   1. 扫描当前目录 *.c
//   2. 对每个 .c：cpp_main（预处理）→ rcc_main -target=glow（编译）→ one_c_file_redirect_addr
//   3. all_c_file_redirect_addr → entry_redirect_to_main → sp_redirect_addr
//   4. 输出 rom.bin / asm.txt / error.txt
//
// 用法：
//   glowcc                  # 编译当前目录所有 .c
//   glowcc a.c b.c          # 编译指定的 .c 文件
//==============================================================================
#include "pch.h"
#include "c.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>
#include <io.h>      // _finddata_t / _findfirst / _findnext（mingw）

// ---------- 来自 glow.cpp / GlowCompilerDlg.cpp 的 extern ----------
extern void  glow_global_init(void);
extern int   rcc_main(int argc, char* argv[]);
extern int   cpp_main(int argc, char** argv);
extern void  one_c_file_redirect_addr(CString* redirect_addr_err);
extern void  all_c_file_redirect_addr(CString* redirect_addr_err);
extern void  entry_redirect_to_main(CString* error_out_buf);
extern void  sp_redirect_addr(void);

extern unsigned char romdata[];    // ROM 数据（glow.cpp 里定义为数组，必须用数组声明匹配）
extern unsigned long  rom_cp;      // ROM 使用计数
extern unsigned long  rom_cp_max;  // ROM 最大使用值
extern unsigned long  ramallocaddr;
extern short          maxlocreg;

#define ROM_SIZE 1048576

// 反汇编单条指令（移植自 GlowCompilerDlg.cpp 的 RomData_To_CString）
// 只为写 asm.txt 用，简化版
static const char* alu_str[25] = {
    "ADD","SUB","ADD_C","SUB_C","EQUAL_C","AND","OR","A_NOT","XOR",
    "A_BH_LSH","B_AL_RSH","A_AH_RSH","A_0_RSH","A_0_LSH","B_0_LSH",
    "MUL_L","MUL_H","DIV","MOD","A_ADD_1","A_SUB_1","A_ADD_1_C","A_SUB_1_C",
    "OUTA","OUTB"
};

static void disasm_one(unsigned long i, unsigned char op, unsigned char xx, FILE* fp) {
    const char* dst_name;
    switch (op & 0x0F) {
        case 0x0: dst_name = "RF";  break;
        case 0x1: dst_name = "A";   break;
        case 0x2: dst_name = "A0";  break;
        case 0x3: dst_name = "A1";  break;
        case 0x4: dst_name = "A2";  break;
        case 0x5: dst_name = "RA";  break;
        case 0x6: dst_name = "B";   break;
        case 0x8: dst_name = "RAM"; break;
        case 0x9: dst_name = "ALU"; break;
        case 0xA: dst_name = "IO0"; break;
        case 0xB: dst_name = "IO1"; break;
        default:  dst_name = "?";   break;
    }
    if (op == 0x07) {
        fprintf(fp, "%lXH: 0x%02x%02x  PC = A2A1A0\n", i >> 1, op, xx);
    } else if (op == 0x17) {
        const char* alu = (xx < 25) ? alu_str[xx] : "?";
        fprintf(fp, "%lXH: 0x%02x%02x  if(!ALU[%s]&1) PC=A2A1A0\n", i >> 1, op, xx, alu);
    } else if (op == 0xFF && xx == 0xFF) {
        fprintf(fp, "%lXH: 0x%02x%02x  NOP\n", i >> 1, op, xx);
    } else {
        const char* src_name;
        switch (op >> 4) {
            case 0x0: src_name = "imm";  break;
            case 0x1: src_name = (xx < 25) ? alu_str[xx] : "ALU"; break;
            case 0x2: src_name = "RF";   break;
            case 0x3: src_name = "RAM";  break;
            case 0x4: src_name = "IO0";  break;
            case 0x5: src_name = "IO1";  break;
            default:  src_name = "?";    break;
        }
        if ((op >> 4) == 0x1 || (op & 0x0F) == 0x9) {
            fprintf(fp, "%lXH: 0x%02x%02x  %s = ALU[%s]\n", i >> 1, op, xx, dst_name, src_name);
        } else if ((op >> 4) == 0x0) {
            fprintf(fp, "%lXH: 0x%02x%02x  %s = 0x%02x\n", i >> 1, op, xx, dst_name, xx);
        } else {
            fprintf(fp, "%lXH: 0x%02x%02x  %s = %s\n", i >> 1, op, xx, dst_name, src_name);
        }
    }
}

// 扫描当前目录 *.c
static std::vector<std::string> find_c_files() {
    std::vector<std::string> v;
    struct _finddata_t fd;
    intptr_t h = _findfirst("*.c", &fd);
    if (h == -1) return v;
    do {
        if (!(fd.attrib & _A_SUBDIR))
            v.push_back(fd.name);
    } while (_findnext(h, &fd) == 0);
    _findclose(h);
    return v;
}

int main(int argc, char** argv) {
    std::vector<std::string> cfiles;
    if (argc > 1) {
        for (int i = 1; i < argc; i++) cfiles.push_back(argv[i]);
    } else {
        cfiles = find_c_files();
    }

    if (cfiles.empty()) {
        fprintf(stderr, "glowcc: no .c files found in current directory\n");
        return 1;
    }

    CString ErrorOut;

    glow_global_init();

    for (auto& cf : cfiles) {
        char* cpp_arg[] = { (char*)"", (char*)cf.c_str(), (char*)"CppOut" };
        char* rcc_arg[] = { (char*)"", (char*)"-target=glow",
                            (char*)"CppOut", (char*)"RccOut",
                            (char*)"-errout=RccError" };

        cpp_main(3, cpp_arg);
        rcc_main(5, rcc_arg);
        one_c_file_redirect_addr(&ErrorOut);

        // 把 CppError / RccError 错误文件追加到 ErrorOut
        FILE* ef;
        if ((ef = fopen("CppError", "r")) != NULL) {
            char buf[1024];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), ef)) > 0)
                ErrorOut.s.append(buf, n);
            fclose(ef);
        }
        if ((ef = fopen("RccError", "r")) != NULL) {
            char buf[1024];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), ef)) > 0)
                ErrorOut.s.append(buf, n);
            fclose(ef);
        }
    }

    all_c_file_redirect_addr(&ErrorOut);
    entry_redirect_to_main(&ErrorOut);
    sp_redirect_addr();

    ErrorOut.s += "寄存器堆占用: " + std::to_string(maxlocreg) + "字节;\r\n";
    if (maxlocreg > 256)
        ErrorOut.s += "寄存器堆溢出错误,大于设定值256字节\r\n";
    ErrorOut.s += "RAM占用: " + std::to_string(ramallocaddr) + "字节;\r\n";
    ErrorOut.s += "ROM占用: " + std::to_string(rom_cp_max) + "字节;\r\n";
    if (rom_cp_max > rom_cp)
        ErrorOut.s += "ROM溢出错误,大于设定值" + std::to_string(rom_cp) + "字节\r\n";

    // 输出 rom.bin（用 rom_cp_max，与 GUI 版一致）
    FILE* fp = fopen("rom.bin", "wb");
    if (fp) {
        fwrite(romdata, 1, rom_cp_max, fp);
        fclose(fp);
    }
    // 输出 error.txt
    fp = fopen("error.txt", "wb");
    if (fp) {
        fwrite(ErrorOut.s.data(), 1, ErrorOut.s.size(), fp);
        fclose(fp);
    }
    // 输出 asm.txt（反汇编）
    fp = fopen("asm.txt", "wb");
    if (fp) {
        for (unsigned long i = 0; i + 1 < rom_cp_max; i += 2) {
            disasm_one(i, romdata[i], romdata[i + 1], fp);
        }
        fclose(fp);
    }

    fprintf(stderr, "glowcc: done. ROM=%lu bytes, RAM=%lu bytes, RF=%d bytes\n",
            rom_cp_max, ramallocaddr, maxlocreg);
    if (!ErrorOut.s.empty()) {
        fprintf(stderr, "%s", ErrorOut.s.c_str());
    }
    return 0;
}
