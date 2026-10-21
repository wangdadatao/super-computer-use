# ADR-0028 元素表默认输出增量差异

- **状态**：已接受（0.3.0）
- **日期**：2026-10-20

<a id="tree_diff_rendering"></a>

## 背景

大应用（Chromium、Codex Desktop、访达）的 AX 树动辄上千个元素。SCU 之前每次都把完整表
（再按 `max_elements` 截断）发给模型：动作后必须重读，读一次就重复发送一次未变化的大部分内容。
`max_elements` 还会把真正需要的底部输入框折叠掉，模型只能再 `focus` 一次。

Codex Computer Use 走的是另一条路：保存上一次树，默认只输出变化；删除项按 ID 范围概括；
差异太大时回退完整树。SCU 借鉴这个设计，但不复制实现。

## 决策

### 1. 协议层保存快照，默认输出差异

`DesktopSession` 保存当前令牌的完整 `entries`，另保留一份“上一次成功读取”的差异基线；
基线不随令牌失效而释放，否则动作后的重读拿不到动作前的树。读取同一 pid、同一窗口且参数相同的新树时，
用基线计算差异。`get_ax_state` 默认返回差异，`full=true` 强制完整表。

首次读取、切换目标、树被截断、`maxDepth`/`budgetMs` 变化时不计算差异，直接返回完整表。
`focus` 也返回完整表：差异和局部展开混在一起会让“哪些行没显示”无法解释。

### 2. 差异格式

```text
~ [AXTextField#5] value="new"
+ [AXButton#8] "保存"
Removed element IDs: 12-15, 20（旧快照句柄，不可用于动作）
```

- `~`：内容变化，或位置编号变化导致句柄换了；
- `+`：新增；
- 删除项不逐行打印，只给旧句柄范围；旧句柄不能用于动作；
- 没有变化时输出“界面与上次读取相同”。

### 3. 匹配键与句柄

匹配使用 role/subrole/identifier/title/description，不含 value/frame；value 变化是 `~`，
title/identifier 变化按保守口径显示为删除 + 新增。
`frame` 不参与差异，窗口移动不会让整棵树变成变化。

SCU 的句柄是位置编号，不是稳定 ID。父级插入/删除后，未变化元素的句柄也可能变；
这类元素会作为 `~` 输出，保证模型拿到**当前**句柄。不能只按内容省略变化，否则旧句柄会被误用。

### 4. 行数预算与回退

差异最多 200 行（`ElementTable.defaultMaxDiffLines`）。超过时**不返回半截差异**，
调用方回退到完整表，并在标题行说明原因。完整表仍有 `max_elements` 上限，需要更小范围时用
`window` 或 `focus`。

预算是启发式初值，不是协议常量；后续按真实任务调整。

### 5. 差异只影响展示，不影响寻址

完整 `entries` 仍保存在令牌快照里；句柄解析、动作前核对、截图标签、动作后重读都使用完整树。
差异文本只是一层渲染，不是新的状态存储。线协议不变，原生层仍发送完整树。

## 取舍

**接受了位置句柄带来的噪声。** 父级插入/删除会让后续句柄整体变化，差异可能比 Codex 多；
但这是 SCU 现有寻址模型的直接结果。要彻底解决需要稳定元素 ID/句柄注册表，属于更大的改动。
计算器实测：点击 `7` 后删除一个静态文本节点，28 行变成 `~`，差异只比完整表少约 12%。

**接受了首次读取仍然很大。** 差异只降低后续读取的上下文成本，不降低第一次 AX 读取与 IPC 传输。
要降低这两项，需要把差异计算下移到原生层，或默认只读 key window；当前不做。

**接受 200 行是启发式。** 太小会频繁回退完整表，太大会重新制造上下文压力。先用可观察的
`budgetExceeded` 和回退日志调整。

## 后果

- `get_ax_state` 新增 `full` 参数，默认差异；
- `SessionState` 新增 `diff`，只在同目标、同参数且未截断时计算；
- 新增差异渲染与测试；MCP 标题行显示 `+ ~ -` 计数；
- 删除项只给旧句柄范围，明确标注不可用于动作；
- 没有线协议变更；原生层仍无状态、仍发送完整树。

## 相关文档

- [ADR-0003 令牌与失效契约](adr_0003_snapshot_token_contract.md)
- [ADR-0018 标签寻址](adr_0018_label_addressing.md)
- [ADR-0015 路径解析](adr_0015_handle_resolution_by_path.md)
- [元素寻址](../interfaces/element_addressing.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- 外部参考：Codex Computer Use 的 `UIElementTreeRevision.differenceLines`、`UIElementRenderDifference`、
  `AccessibilityDifferenceLineBudgetExceeded` 符号与 diff 文案；来源登记见
  [verification/external-sources.md](../../verification/external-sources.md) 的“大应用树”一节。
