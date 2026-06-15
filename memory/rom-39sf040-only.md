---
name: rom-39sf040-only
description: 74HC-Chiptune 项目 ROM 选型硬规则——只能用 39SF040
metadata:
  type: feedback
---

## 规则

本项目所有 ROM（微码 ROM、波形 ROM、任何查找表 ROM）**只能用 39SF040**，不讨论任何替代方案。

**Why**: 用户明确指出 82S126 买不到全新，项目已确定统一用 39SF040 (512KB Flash)。无需再问选型。

**How to apply**:
- 任何 ROM 实例都用 `hc39sf040`
- 不要问 "要不要用 GAL/EEPROM/27C256 替代"
- 原版 82S126 的 256×4 数据要适配到 39SF040 的 8-bit 总线（每个 nibble 占一字节，或低 4 位有效，看具体接线）
- 不要建议买其他型号
