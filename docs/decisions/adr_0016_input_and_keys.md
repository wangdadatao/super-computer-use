# ADR-0016 v1 输入用逐字按键，目标是显式元素，事件投递到进程

- **状态**：已接受（v1 第一项）
- **日期**：2026-10-19

## 背景

P0 只有读取与 `AXPress`。v1 要能"读、点、输入"，[ADR-0013](adr_0013_p0_vertical_slice.md) 把输入列入 v1 范围。
[编辑类操作语义](../interfaces/edit_semantics.md)已经定了三条写入路径与严格的目标解析规则，但还没有实现。

第一个要回答的问题是：输入走哪条路径、投递到哪里、需不需要激活目标应用。

<a id="input_decision"></a>

## 决策

### 1. 先做逐字输入与按键，设值单独一项

v1 第一项实现两个动作：

- `type_text`：把文本逐字输入到目标元素
- `press_key`：向目标元素发送一个按键或组合键

`set_value`（无障碍设值）按 [edit_semantics](../interfaces/edit_semantics.md) 是**默认写入路径**，
但它与逐字输入的副作用不同，需要单独的"元素声明可写"判定，因此作为下一项实现，
不与本次合并。本次不实现"设值失败时回退到逐字输入"——那会让调用方无法判断实际发生了什么。

### 2. 目标必须是显式元素，先核对再聚焦

两个动作都要求调用方给出**令牌 + 句柄**，与 `click` 相同：

1. 策略检查（先于令牌）
2. 令牌与句柄解析（会话层）
3. 原生层沿路径与核对键校验（ADR-0015）
4. raise 元素所在的窗口并激活应用（见 §3），设置该元素的 `AXFocused`，等它被读回为 true（最多约 300 毫秒）
5. 投递键盘事件

**不接受隐式的"当前焦点"**。写错位置可能触发搜索、发送消息或提交表单，代价不可逆；
[edit_semantics](../interfaces/edit_semantics.md#写入的目标解析)已经要求这种严格性。
句柄失效时按 `stale_snapshot` 拒绝，不联系原生层。

### 3. 事件投递到目标进程，先 raise 目标窗口

键盘事件用 `CGEvent` 构造，通过 `postToPid` 直接投递给目标进程：

- 文本按 Unicode 字符串逐字符投递；换行与制表符映射为 Return 与 Tab；
- 每个按键都是 down + up，动作之间不保持按住状态；
- 不移动鼠标。

**`postToPid` 只决定事件进入哪个进程，真正接收文字的是该进程当前 key window 的 first responder。**
因此投递前必须 raise 目标元素所在的窗口，并在应用不活跃时激活它；否则多窗口应用会把输入送进
另一个窗口（2026-10-20 在 TextEdit 两个窗口上实际发生，见追加记录）。
激活与 raise 是用户可见的前台切换，这是为了把输入送到正确元素付出的代价。

### 4. 组合键语法与长按

- 语法为 `+` 分隔的键名，修饰键顺序无关：`cmd+shift+t` 与 `shift+cmd+t` 等价。
- 修饰键（`cmd`/`shift`/`alt`/`ctrl`）用事件的 `flags` 表达，不额外投递修饰键的 down/up。
- 不支持跨动作的长按（按住 Shift 连续点击等）。每次动作自带 down 与 up。
- 不认识的键名、空键名、多个主键**一律拒绝**，不猜测。

### 5. 效果摘要与令牌语义复用点击的路径

输入与按键和点击共用同一条"投递后观察"的路径（[ADR-0011](adr_0011_convergence_over_fixed_delay.md) 的最小判定）：
返回 `delivered`、`observed`、`converged`、`treeChanged`、`noOpSuspected` 等字段。
值或结构变化时**调用所用的令牌作废**——输入会改值，所以通常每次输入后都要重读。

### 6. 错误归类

| 情形 | 错误码 |
| --- | --- |
| 元素不接受焦点 | `unsupported_operation` |
| 键名不认识、组合键里有多个主键、文本为空 | `unsupported_operation` |
| 文本超过 10000 字符、定位器结构非法 | `internal_error`（边界/协议层参数错误） |
| 平台拒绝设置焦点或投递失败 | `action_failed` |

## 取舍

**最初接受了"不激活应用"的未验证性，后来被真实多窗口推翻。** 只发 `postToPid`、不 raise 窗口时，
事件虽然进了目标进程，却由该进程的 key window 接收；TextEdit 的 A/B 两窗口实测把文字输进了 B。
现在改为先 raise 目标窗口并激活应用。代价是输入会切换前台，不再是无感的；
`set_value` 仍不聚焦、不激活，是需要无副作用写入时的首选。

**接受了逐字输入的副作用。** 它会经过应用的按键处理与输入法：能触发自动完成、实时校验与回车，
但也可能触发快捷键。P0/v1 不做输入法（IME）处理，只适合直接输入（ASCII 与可直接映射的字符）。

**接受了"组合键只发 flags"的实现。** 少数应用要求真正的修饰键事件；目前没有证据表明需要，
遇到时再改为显式修饰键 down/up。

**清理门槛的适用性变了。** 引入键盘事件后，理论上存在"按下未释放"的窗口；
本次实现保证每个事件成对投递、不跨动作保持。若进程在 down 与 up 之间被 SIGKILL，
可能残留一次按键，窗口极短，未做额外兜底。

## 后果

- 原生层线协议升到版本 4：新增 `typeText`、`pressKey` 两种请求
- MCP 动作档多两个工具：`type_text`、`press_key`，都需要 `token` 与 `handle`
- 夹具增加可编辑输入框与 Return 提交行为
- 测试：按键解析单元测试、会话层令牌/效果测试、夹具上的真实输入与提交测试
- [edit_semantics](../interfaces/edit_semantics.md) 的"三种写入路径"中，逐字输入已实现，设值待做

## 追加记录（2026-10-20，多窗口输入修正）

真实任务：TextEdit 同时打开 `/tmp/scu-task-a.txt` 与 `/tmp/scu-task-b.txt`，用 A 的令牌与句柄
`AXTextArea#3` 执行 `cmd+a`、`type_text`。修复前 `type_text` 返回 delivered，但 A 的值不变，
B 的值被改写——路径核对与 `AXFocused` 都不足以改变 key window。

修正：`typeText` / `pressKey` 在聚焦前沿 `AXParent` 找到窗口，`AXRaise` 它、设置 `kAXMain`，
必要时 `NSRunningApplication.activate`。修复后同样的令牌把文字写进 A，B 保持 `bravo`。
证据见 [窗口根实测](../../verification/2026-10-20-window-root.md#追加多窗口输入修正)。

协议不变；`set_value` 不经过这条路径，仍可在后台写入。

## 追加记录（2026-10-19，设值）

`set_value` 已实现，补完"输入"这一项。与逐字输入的差别按
[edit_semantics](../interfaces/edit_semantics.md) 的约定：

- 要求元素声明 `AXValue` 可写（`AXUIElementIsAttributeSettable`）；不可写时返回 `unsupported_operation`，
  **不回退到逐字输入**——两者的副作用不同。
- 不需要聚焦，也不经过键盘与输入法；因此不触发自动完成、实时校验与按键处理。
- 空字符串是合法值（清空字段），不会被当作"未给出"。
- 值变化同样进入结构摘要，**令牌作废**；效果摘要与点击共用。
- 错误归类：不可写 → `unsupported_operation`；平台拒绝 → `action_failed`。

至此 v1 的「点击、输入、设值」都已实现。

## 相关文档

- [编辑类操作语义](../interfaces/edit_semantics.md)
- [元素寻址](../interfaces/element_addressing.md)
- [原生层线协议](../interfaces/native_wire_protocol.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- [ADR-0013](adr_0013_p0_vertical_slice.md)
- [ADR-0015](adr_0015_handle_resolution_by_path.md)
