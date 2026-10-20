# 真实任务第一轮（TextEdit / Calculator / Finder）

- 日期：2026-10-20
- 环境：macOS 14.4，Apple Silicon；`scu`/`scu-native` 由当前工作区构建（协议 v11）
- 方法：`scu mcp --actions`，通过 MCP stdio 调用；每次界面动作后重新 `get_ax_state`
- 目的：用接近日常使用的任务找失败点，不以工具调用成功作为任务成功

## 任务与结果

| # | 任务 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | TextEdit：把 A 文件内容从 `alpha` 改为 `beta task` 并保存 | 通过 | A 的 AXTextArea 变为 `Beta task\n`（TextEdit 自动大写）；磁盘文件为 `Beta task\n` |
| 2 | TextEdit：在 B 窗口做同样修改，确认 A 不被误写 | 通过 | B 变为 `Bravo edited\n`，A 仍为 `Beta task\n`；磁盘文件一致 |
| 3 | 计算器：计算 7×8 | 通过 | `get_ax_state` 的输入字段为 `56`，上个表达式为 `7×8` |
| 4 | 访达：在 `/tmp/scu-task-dir` 新建文件夹 | **部分通过** | `cmd+shift+n` 创建了“未命名文件夹”，但无法在 AX 树中定位重命名输入框，名称未改 |

## 详细过程

### TextEdit：编辑、保存与多窗口隔离

两个临时文件，各开一个窗口。对目标窗口执行：

```text
get_ax_state(window="scu-task-a.txt") → 令牌、AXTextArea#3
press_key(cmd+a) → 动作后令牌失效，重新读取
type_text("beta task\n") → A 的值变为 "Beta task\n"
press_key(cmd+s) → 保存
```

- A 保存后磁盘内容为 `Beta task\n`；B 的值为 `bravo\n`，未被输入影响。
- 反过来编辑 B 时，A 保持 `Beta task\n`。
- 两个窗口的局部句柄都是 `AXTextArea#3`，隔离完全依赖令牌上的 `windowTitle` 与输入前的窗口 raise。

**修复前的失败**：同一序列调用 `type_text` 返回 `delivered=true`，A 的值不变，B 被写成了
`Beta from task\n...`。原因是 `postToPid` 只决定事件进入哪个进程，文字由该进程的 key window
的 first responder 接收；只设目标元素 `AXFocused` 没有改变 key window。
修复为输入前 `AXRaise` 目标窗口并激活应用，见
[ADR-0016 追加记录](../docs/decisions/adr_0016_input_and_keys.md#追加记录2026-10-20多窗口输入修正)。

### 计算器：7×8

```text
launch_app("Calculator") → pid 6403
get_ax_state → 标签 [e] 7、[h] 乘、[f] 8、[t] 等于
每次 click 后重新读取
最终输入字段 value="‎56"，结果字段 value="‎7‎×‎8"
```

计算器是原生 AppKit，按钮以 `desc` 暴露，标签寻址有效；数值变化会让令牌失效，必须逐次重读。

### 访达：新建文件夹

在 `scu-task-dir` 窗口的 `AXOutline`（列表视图）上执行 `cmd+shift+n`，文件系统出现
`/tmp/scu-task-dir/未命名文件夹`。但重命名没有完成：

- 新文件夹行只暴露 `AXOutlineRow` / `AXCell` / 图片与披露三角，没有 `AXTextField` 或名称文本；
- 对 `AXOutline` 执行 `type_text` 返回 `noOpSuspected=true`，没有输入到内联编辑器；
- 用窗口根执行 `cmd+shift+n` 时没有创建文件夹，只在 `AXOutline` 上成功——说明键盘快捷键要求
  目标元素可成为 first responder，窗口根不够。

## 失败点与处理

1. **多窗口输入写错窗口（已修）**：`postToPid` + `AXFocused` 不足以指定 key window。
   输入/按键现在先 raise 元素所在窗口并激活应用。副作用是输入会切换前台；`set_value` 不受影响。
2. **Finder 内联重命名没有 AX 入口（未修）**：当前定位器只能沿树路径找元素；树里没有重命名输入框时，
   无法在不使用“当前焦点”的情况下输入。暂记为真实缺口，不引入隐式焦点写入。
3. **单次动作后必须重读**：`cmd+a` 这类看似无副作用的按键也可能改变树并作废令牌；任务脚本若沿用旧令牌，
   会得到 `stale_snapshot`。这不是产品失败，是令牌契约生效。

## 限定

- 只跑了 4 个任务、3 个应用；不是 5–10 个任务的完整集合。
- TextEdit 打开了自动大写，实际文本与输入字符串大小写不同；未关闭该功能重复验证。
- 计算器只测了基础模式的一个乘法，没有测键盘输入或连续运算。
- Finder 只测了列表视图；图标视图、侧边栏和菜单驱动的重命名未测。
- 没有测中文输入法、浏览器、网易云搜索或跨应用拖拽。

## 影响

- [ADR-0016](../docs/decisions/adr_0016_input_and_keys.md)：输入从“不激活应用”改为“先 raise 目标窗口、必要时激活应用”。
- [ADR-0027](../docs/decisions/adr_0027_window_root_locator.md)：窗口根在元素动作上得到真实多窗口验证。
- [MCP 接入面](../docs/interfaces/mcp_surface.md)：输入/按键的前台语义更新。
- 下一步优先级：Finder 类应用的内联编辑定位、真实任务集扩到 5–10 个、再评估是否需要焦点目标原语。
