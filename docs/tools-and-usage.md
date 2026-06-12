# 工具链与环境变量

## 已安装工具

| 工具 | 版本 | 安装路径 |
|------|------|----------|
| iverilog | 14.0 (devel) | `C:\Users\denjhang\iverilog` |
| vvp | 14.0 (devel) | 同上（bin/vvp.exe） |
| yosys | 0.66+70 | `D:\Program Files\oss-cad-suite` |
| nextpnr | (oss-cad-suite 内含) | 同上 |
| GHDL | (oss-cad-suite 内含) | 同上 |

## PATH 设置

用户 PATH 中已添加以下目录（新开终端生效）：

```
C:\Users\denjhang\iverilog\bin
D:\Program Files\oss-cad-suite\bin
D:\Program Files\oss-cad-suite\lib
```

oss-cad-suite 的 lib 目录必须加到 PATH，否则 yosys 等工具找不到 DLL（libgcc_s_seh-1.dll、libstdc++-6.dll、libreadline8.dll 等）。

## yosys 运行方式

oss-cad-suite 的 exe 是原生 Windows PE，依赖 mingw64 的 DLL。在 Git Bash 中可能因空格路径问题导致 127 错误，推荐用以下方式运行：

```bash
# PowerShell（推荐）
$env:PATH = 'D:\Program Files\oss-cad-suite\bin;D:\Program Files\oss-cad-suite\lib;' + $env:PATH
yosys --version
# Yosys 0.66+70

# 或直接用 oss-cad-suite 提供的环境脚本
cmd.exe /c "call \"D:\Program Files\oss-cad-suite\environment.bat\" && yosys --version"

# 或 start.bat 打开一个配置好的命令行环境
cmd.exe /c "D:\Program Files\oss-cad-suite\start.bat"
```

## iverilog 运行方式

iverilog 编译自 MSYS2 msys 子环境，在 Git Bash 和 PowerShell 中均可直接使用：

```bash
iverilog -V
# Icarus Verilog version 14.0 (devel)
```

## ice-chips-verilog 库

74HC 系列 TTL 芯片的 Verilog 实现，位于 `ice-chips-verilog-main/`。

### 目录结构

```
ice-chips-verilog-main/
├── source-7400/       # 所有 74xx 芯片的 .v 和 -tb.v 测试文件
├── includes/          # helper.v, tbhelper.v（测试辅助）
├── scripts/validate/  # Node.js 验证脚本（exec-verilog.js）
└── package.json
```

### 编译单个芯片测试

```bash
cd ice-chips-verilog-main/source-7400

# 编译 test bench（以 7400 四路 NAND 为例）
iverilog -g2012 -o7400-tb.vvp ../includes/helper.v ../includes/tbhelper.v 7400-tb.v 7400.v

# 运行仿真
vvp 7400-tb.vvp
```

### 运行全部芯片验证

```bash
cd ice-chips-verilog-main

# 先装依赖（package.json 未声明 walk-sync，需手动装）
npm install
npm install walk-sync

# 运行验证（使用 iverilog）
node scripts/validate/exec-verilog.js

# 静默模式（只显示通过/失败）
node scripts/validate/exec-verilog.js -s
```

### 已知问题：74139 编译失败

iverilog 14.0 (devel) 与 ice-chips-verilog 的 74139 芯片不兼容。

**原因**: `helper.v` 中的 `PACK_ARRAY` 宏在 `assign` 语句内展开后，`PK_OUT_BUS` 先声明再在同一赋值右侧使用，iverilog 14.0 对此解析更严格：
```
74139.v:33: error: Unable to bind wire/reg/memory `PK_OUT_BUS' in `test.dut'
74139.v:33:      : A symbol with that name was declared here. Check for declaration after use.
```

**影响**: 仅影响 74139（双 2-4 译码器），其余所有芯片验证正常。后续如需使用 74139，可考虑拆分宏或调整写法规避。

### 可用芯片列表

7400, 7402, 7404, 7407, 7408, 7410, 7411, 74112, 74138, 74139, 74147, 74148,
74150, 74151, 74153, 74154, 74155, 74157, 74158, 74160, 74161, 74162, 74163,
74181, 7420, 7421, 74238, 74260, 74266, 7427, 74273, 74283, 7430, 7432,
74352, 74377, 7442, 7473, 7474, 7485, 7486

每个芯片都有对应的 `-tb.v` 测试文件。

### 查看波形（需要 GTKWave）

```bash
# 仿真会生成 .vcd 文件，用 GTKWave 打开
gtkwave 7400-tb.vcd
```
