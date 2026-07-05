#!/bin/bash
# build.sh —— 编译萤火虫命令行版编译器 glowcc.exe
# 用法：bash build.sh
# 依赖：mingw64 g++（D:\msys64\mingw64\bin）
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

export PATH="/d/msys64/mingw64/bin:$PATH"

# 排除 MFC GUI 文件
CPPS=$(ls *.cpp | grep -v "^GlowCompiler.cpp\|^GlowCompilerDlg.cpp" | tr '\n' ' ')

echo "=== 编译 glowcc ==="
g++ -std=c++17 -O2 -fpermissive -w \
    -include cli_compat.h \
    -I. \
    $CPPS \
    -o glowcc.exe

echo "=== 完成: $(ls -la glowcc.exe | awk '{print $5, $9}') ==="
echo "用法: ./glowcc.exe [file1.c file2.c ...]   # 不带参数则编译当前目录所有 .c"
echo "输出: rom.bin / asm.txt / error.txt"
