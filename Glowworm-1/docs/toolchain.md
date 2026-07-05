# Glowworm-1 工具链部署

> 部署时间：2026-07-05
> 与 PSG 项目对齐：统一走 oss-cad-suite

## 工具链

| 工具 | 位置 | 版本 |
|------|------|------|
| **iverilog / vvp** | `D:\Program Files\oss-cad-suite\bin\` | Icarus Verilog 14.0 (devel, s20260301-180) |
| **gtkwave** | `D:\Program Files\oss-cad-suite\bin\gtkwave.exe` | 随包 |
| **yosys** | （本机未装）| 需要时再补 |
| **Python 3.13** | `py -3.13` | 用于读 BOM/xls 等 |
| **xlrd 1.2.0** | Python 3.13 | 读老 .xls（xlrd 2.0+ 不支持 xls，必须 1.2.0）|
| **openpyxl 3.1.5** | Python 3.13 | 读新 .xlsx（BOM 等）|

> 备用：根目录 `iverilog-install/` 也是 iverilog 14.0（离线备用），本项目统一用 oss-cad-suite 那份。
> 注：`python`（3.12）和 `py -3.13` 是两个版本，装包时注意装到哪个。xlrd/openpyxl 都在 3.13。

## PATH 设置（每次新开终端要做）

oss-cad-suite 的 exe 是 mingw64 编译，依赖 `lib/` 下的 DLL（libgcc_s_seh-1.dll 等），**bin 和 lib 都要加 PATH**，否则 vvp 崩溃（exit code 0xC0000135）。

**临时（一次性测试）**：
```bash
PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
```

**永久（PowerShell，写用户环境变量）**：
```powershell
[Environment]::SetEnvironmentVariable('Path',
    'D:\Program Files\oss-cad-suite\bin;D:\Program Files\oss-cad-suite\lib;' +
    [Environment]::GetEnvironmentVariable('Path','User'),
    'User')
```

## 验证（已通过）

```bash
PATH="/d/Program Files/oss-cad-suite/bin:/d/Program Files/oss-cad-suite/lib:$PATH"
iverilog -V          # Icarus Verilog 14.0
vvp -V

# 端到端
echo 'module t; initial begin $display("oss-cad OK"); $finish; end endmodule' > /tmp/t.v
iverilog -o /tmp/t.vvp /tmp/t.v
vvp /tmp/t.vvp
# 输出: oss-cad OK
```

## 读老 .xls（萤火虫资料里 .xls 不是 zip）

老 .xls 是 OLE2 二进制（不是 zip），不能用 unzip。用 xlrd 1.2.0：
```bash
py -3.13 -c "import xlrd; b=xlrd.open_workbook(r'路径.xls'); ..."
```

## 读新 .xlsx（BOM 等）

xlsx 是 zip（XML），可用 openpyxl 或直接 unzip。本项目用 openpyxl：
```bash
py -3.13 -c "import openpyxl; wb=openpyxl.load_workbook(r'路径.xlsx', data_only=True); ..."
```
