#!/bin/sh
# WT3 compile + simulate
# Must run from MSYS2 bash (D:\msys64\usr\bin\bash.exe)
#
# Prerequisites:
#   1. oss-cad-suite copied to D:\oss-cad (short path! avoids 8.3 bug)
#   2. iverilog driver rebuilt: configure --prefix=/d/oss-cad, then make -C driver
#   3. ivl.exe from source build (oss-cad-suite's ivl.exe has DLL incompatibility)
#   4. vvp.exe from source build at iverilog-master/vvp/vvp.exe

cd /d/working/vscode-projects/74HC-Chiptune/wsg3
export PATH="/d/msys64/mingw64/bin:$PATH"
export TMP=C:/TEMP
export TMPDIR=C:/TEMP

TB="${1:-wsg3_core_tb}"
VVP="/d/working/vscode-projects/74HC-Chiptune/iverilog-master/vvp/vvp.exe"
RTL="rtl/wt3_core.v rtl/wt3_spfm_bus.v rtl/hc39sf040.v rtl/hc62256.v rtl/hc161.v rtl/hc157.v rtl/hc377.v rtl/hc283.v rtl/hc04.v rtl/hc273.v rtl/hc174.v rtl/hc373.v"

echo "=== Compiling ${TB} ==="
# iverilog MUST run via cmd.exe — MSYS2 bash popen() breaks the ivlpp|ivl pipe
/c/Windows/System32/cmd.exe //c "set PATH=D:\oss-cad\bin;D:\msys64\mingw64\bin;%PATH%&& iverilog -o wsg3_debug.vvp -Wall ${RTL} tb/${TB}.v" 2>&1
echo "Compile RC=$?"

echo "=== Simulating ==="
"$VVP" wsg3_debug.vvp 2>&1
echo "Sim RC=$?"
