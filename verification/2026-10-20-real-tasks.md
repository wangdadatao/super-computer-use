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
| 5 | Edge：打开本地页面，点击链接进入详情页 | 通过 | `AXPress` 为空操作；改用截图坐标 `click_at` 后窗口标题变为 `Details OK - Microsoft Edge`，读到 `AXHeading "Details OK"` |
| 6 | TextEdit：全选、替换、撤销、重做 | **失败** | `cmd+a` 前后出现中文“个护”插入；撤销回到 `changed` 而不是 `original`；输入法/键事件语义未达标 |

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

### Edge：本地页面链接

用独立 profile 启动 Edge，打开 `file:///tmp/scu-edge-page/index.html`：

- AX 树里有 `AXWebArea`、`AXHeading`、`AXLink`；`get_ax_state` 能读到链接文本。
- 对 `AXLink` 执行 `click`（`AXPress`）返回 `noOpSuspected=true`，页面没有导航。
- 改走 `get_screenshot` + `click_at`：截图 1600×1821、`scale=1.333`；
  按链接 frame 换算成图像坐标 (79,238) 点击后，窗口标题变为 `Details OK - Microsoft Edge`，
  读取到 `AXHeading "Details OK"` 与 `"link worked"`。
- `click_at` 的 effect 报告 `observed=false`，因为导航后旧窗口标题不再可读；它没有假装知道结果，
  需要下一步重新 `list_windows` / `get_ax_state` 核实。

### TextEdit：全选、撤销、重做

窗口 `/tmp/scu-task-c.txt`，原内容 `original\n`。执行 `cmd+a` 后，AX 值变成 `个护original\n`；
`type_text("changed\n")` 后变成 `Changed\n`；`cmd+z` 后是 `changed\n`，`cmd+shift+z` 后回到 `Changed\n`。
没有回到 `original`。

观察到两件事：

- 宿主当前的中文输入法/键盘状态参与了 `press_key`，`cmd+a` 没有被干净地当作“全选”；
- 撤销栈记录的是逐字输入的编辑，不是“用 AX 值替换”的原子操作，所以撤销结果与用户直觉不一致。

这不是本次改动引入的；它落在此前标记为未验证的输入法范围。未继续修，先作为真实缺口记录。

## 失败点与处理

1. **多窗口输入写错窗口（已修）**：`postToPid` + `AXFocused` 不足以指定 key window。
   输入/按键现在先 raise 元素所在窗口并激活应用。副作用是输入会切换前台；`set_value` 不受影响。
2. **Finder 内联重命名没有 AX 入口（未修）**：当前定位器只能沿树路径找元素；树里没有重命名输入框时，
   无法在不使用“当前焦点”的情况下输入。暂记为真实缺口，不引入隐式焦点写入。
3. **单次动作后必须重读**：`cmd+a` 这类看似无副作用的按键也可能改变树并作废令牌；任务脚本若沿用旧令牌，
   会得到 `stale_snapshot`。这不是产品失败，是令牌契约生效。
4. **Edge 的 AXLink 不能按**（未修）：`AXPress` 返回空操作，坐标点击可用。工具已经如实报
   `noOpSuspected`，模型应按 SKILL 改用截图坐标；这条路径成立。
5. **输入法/撤销语义不合格**（未修）：`cmd+a` 出现中文插入，撤销没有回到原值。需要单独的最小用例，
   不应把它混进多窗口修复。

## 限定

- 只跑了 6 个任务、4 个应用；达到 5–10 的下限，但样本仍小。
- TextEdit 打开了自动大写，实际文本与输入字符串大小写不同；未关闭该功能重复验证。
- 计算器只测了基础模式的一个乘法，没有测键盘输入或连续运算。
- Finder 只测了列表视图；图标视图、侧边栏和菜单驱动的重命名未测。
- 浏览器只测了本地静态页面的一个链接；没有测地址栏输入、登录态、复杂 SPA 或下载。
- 没有测网易云搜索或跨应用拖拽。
- 输入法只暴露了问题，没有形成可复现的最小用例；TextEdit 自动大写也影响了文本比较。

## 影响

- [ADR-0016](../docs/decisions/adr_0016_input_and_keys.md)：输入从“不激活应用”改为“先 raise 目标窗口、必要时激活应用”。
- [ADR-0027](../docs/decisions/adr_0027_window_root_locator.md)：窗口根在元素动作上得到真实多窗口验证。
- [MCP 接入面](../docs/interfaces/mcp_surface.md)：输入/按键的前台语义更新。
- 下一步优先级：为输入法/撤销建立最小复现，再决定是否需要输入前重置输入法或改用 `set_value`；
  Finder 类应用的内联编辑定位、再评估是否需要焦点目标原语。
