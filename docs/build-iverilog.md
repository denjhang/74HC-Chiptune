# Icarus Verilog (iverilog) 编译记录

## 编译目标

- **软件**: Icarus Verilog 14.0 (devel)
- **源码路径**: `iverilog-master/`
- **安装路径**: `C:\Users\denjhang\iverilog`
- **日期**: 2026-06-12

## 环境

- **OS**: Windows 11 Pro (26200)
- **工具链**: MSYS2 (mingw64)
  - gcc 15.2.0 (MSYS2)
  - GNU Make 4.4.1
  - bison 3.8.2
  - flex 2.6.4
  - autoconf 2.72

## 编译步骤

### 1. 安装依赖

```bash
# gperf 需要在 msys 子环境中安装（mingw64 的 gperf 不够）
pacman -S --noconfirm msys/gperf
```

### 2. 生成 configure 脚本

```bash
# 必须通过 MSYS2 的 msys shell 运行，不能用 mingw64 shell 或 Git Bash
/d/msys64/msys2_shell.cmd -msys -defterm -no-start -c "sh autoconf.sh"
```

### 3. 运行 configure

```bash
/d/msys64/msys2_shell.cmd -msys -defterm -no-start -c "./configure --prefix=$HOME/iverilog"
```

### 4. 编译

```bash
/d/msys64/msys2_shell.cmd -msys -defterm -no-start -c "make -j$(nproc)"
```

### 5. 安装

```bash
/d/msys64/msys2_shell.cmd -msys -defterm -no-start -c "make install"
```

### 6. 添加到 PATH

```powershell
[Environment]::SetEnvironmentVariable('Path',
    [Environment]::GetEnvironmentVariable('Path', 'User') + ';C:\Users\denjhang\iverilog\bin',
    'User')
```

## 遇到的问题

### 问题 1: gperf 未安装

**现象**: `autoconf.sh` 报 `gperf: command not found`

**原因**: mingw64 子环境有 gperf，但 msys 子环境没有

**解决**: `pacman -S --noconfirm msys/gperf`

### 问题 2: Perl 找不到 Autom4te::ChannelDefs

**现象**: 在 Git Bash / mingw64 shell 中运行 autoconf 报错：
```
Can't locate Autom4te/ChannelDefs.pm in @INC
```

**原因**: MSYS2 的 Perl `@INC` 不包含 autoconf 的数据目录，路径映射 `/usr/share/autoconf-2.72` 在非 msys shell 中无法解析

**解决**: 改用 MSYS2 的 msys shell 运行整个编译流程：
```bash
/d/msys64/msys2_shell.cmd -msys -defterm -no-start -c "sh autoconf.sh"
```

### 问题 3: autom4te 找不到 m4

**现象**: `autom4te-2.72: error: need GNU m4 1.4 or later: /usr/bin/m4`

**原因**: 同上，mingw64 的 Perl 和 msys 的 autoconf 之间路径不兼容

**解决**: 同上，统一使用 msys shell

### 问题 4: readline / zlib / bz2 未找到

**现象**: configure 输出中 readline、zlib、bz2 均为 `no`

**影响**: 非关键依赖，不影响核心编译和仿真功能。缺少 readline 会影响交互式 vvp shell 的行编辑体验

**解决**: 如果需要，可以额外安装：
```bash
pacman -S msys/libreadline-devel msys/zlib msys/bz2
```

## 验证

```bash
iverilog -V
# Icarus Verilog version 14.0 (devel)
```

## 关键经验

1. **必须用 msys shell**，不能用 mingw64 shell 或 Git Bash — MSYS2 的 Perl 路径映射在不同子环境间不兼容
2. **gperf 要装在 msys 环境**里（`msys/gperf`），不是 `mingw-w64-x86_64-gperf`
3. 调用方式统一为 `/d/msys64/msys2_shell.cmd -msys -defterm -no-start -c "命令"`
