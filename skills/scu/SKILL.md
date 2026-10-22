---
name: scu
description: 用 SCU（SuperComputerUse）读取和操作本机 macOS 应用的界面。当任务需要点击原生应用的按钮、填写表单、切换设置、按快捷键，且没有可用的 API/CLI 时使用；也用于读取某个应用当前界面结构、截图对照与坐标点击（最后手段）。不适用于网页 DOM/标签页自动化（用 Playwright MCP 或 Codex Browser）或非 macOS 平台。
---

# SCU 使用指导（v1）

SCU 是一个 MCP 服务：读取 macOS 应用的无障碍树，并用 `AXPress` / 键盘事件 / 无障碍设值操作界面。
它是**兜底手段**：能用应用自己的 API、CLI 或插件完成的任务，不要用 SCU。

## 能力边界（先看这个）

| 能做 | 不能做 |
| --- | --- |
| 读取**已在运行**的应用的无障碍树（文本元素表） | 切换前台应用（启动、输入、按键与坐标动作会激活目标） |
| 启动/激活应用（`launch_app`） | 右键、长按 |
| 截图、看画面、按截图坐标点击/滚动/拖拽（`get_screenshot` / `click_at` / `scroll_at` / `drag`）；动作前会在屏幕上显示约 120ms 的指示环 | 页面 DOM/标签页语义（改用浏览器操作面） |
| 点击元素（`AXPress`） | 输入法（中文等）未验证；粘贴、剪贴板 |
| 逐字输入文本（`type_text`）、发送按键/组合键（`press_key`） | 审批/确认层：危险动作只能靠你与用户确认 |
| 直接写元素的值（`set_value`，要求元素可写） | 跨应用编排、自动重试 |
| 知道动作是否改变了界面、是否疑似空操作 | 浏览器页面标签页、DOM、登录态继承（没有浏览器适配器） |

**SCU 操作浏览器时，只把浏览器当普通 macOS 应用**：可以点地址栏、标签页、菜单和原生对话框，
也可以截图后点坐标；但 `get_ax_state` 不是 DOM，`list_windows` 也不是标签页列表。
网页内容优先用 Playwright MCP / Codex Browser，见下面的操作面选择。

只读档提供 `check_permissions` / `list_apps` / `list_windows` / `get_ax_state` / `get_screenshot`；
其中 `get_screenshot` 不改内容，但会激活并 raise 目标窗口（`readOnlyHint: false`），
`launch_app` / `click` / `click_at` / `scroll_at` / `drag` / `type_text` / `press_key` / `set_value` 需要服务以 `--actions` 启动。
如果调用这些工具返回"未知工具"（JSON-RPC `-32602`），说明动作档没开，请用户改启动参数。

## 先选操作面

| 任务 | 用哪个 |
| --- | --- |
| 打开 URL、网页表单、页面按钮、读网页内容、登录态标签页 | **Playwright MCP** 或宿主提供的 Browser 插件 |
| 浏览器地址栏、菜单、扩展、原生对话框；原生应用；跨应用流程 | **SCU** |

不要用 `get_ax_state` 猜网页结构，也不要把浏览器窗口的元素表当 DOM。
SCU 当前**没有**浏览器 adapter/扩展，也没有 `list_tabs` / `get_tab`；
不要声称 SCU 能找到“Edge 里那个 baidu 标签页”。需要时改用浏览器操作面。

## 第一次使用

还没装好时先读 [INSTALL.md](INSTALL.md)：环境检查、构建、宿主配置、授权与自检。
授权必须由人在系统设置里完成，agent 不能代做。

1. 调用 `check_permissions`。**权限属于启动 MCP 服务的宿主应用**，不是整台机器。
   未授予时让用户给宿主（Cursor、终端等）授权，然后重启该宿主。
2. `list_apps` 取 `pid`。它只列出已在运行、激活策略为 regular 的应用。
   目标没在运行就先 `launch_app`；解析不到会返回 `app_not_found`。
3. `get_ax_state(pid)` 读界面。多窗口应用先用 `list_windows(pid)` 看标题，再决定是否 `window=`。

## 核心循环

```
list_apps → get_ax_state(pid) → 多窗口时 list_windows(pid) → get_ax_state(pid, window=标题) → 需要时 get_screenshot(token) → 用令牌与标签/句柄执行一个动作 → 重新 get_ax_state
```

**每次会改变界面的动作之后都要重读。** 令牌、标签与句柄只对一次读取有效；
结构或取值一变，旧令牌作废（`stale_snapshot`），标签与句柄编号也可能变。
不要在一轮里连续点多个目标——除非你确定界面没变（看效果摘要）。

## 读状态：元素表怎么用

`get_ax_state` 返回标题行加元素表：

```text
# pid=1234 令牌 s1abc.7 元素 42。可交互元素前的 [a] 是本次快照的标签…
[AXApplication#1] "Safari"
  [AXWindow#2] "起始页" subrole=AXStandardWindow
    [a] [AXButton#3] "返回" id="go-back" frame=(10,50,24,24)
    [b] [AXTextField#4] "地址与搜索" value="example.com" frame=(50,50,300,28)
```

**同一 pid、同一窗口的后续读取默认只返回差异：**

```text
~ [AXTextField#5] value="new"
+ [AXButton#8] "保存"
Removed element IDs: 12-15, 20（旧快照句柄，不可用于动作）
```

- `~` 是内容变化，或父级插入/删除后句柄换了；`+` 是新增；
- 删除项只给旧句柄范围，不能拿来动作；
- 没有变化时只输出“界面与上次读取相同”，令牌仍可复用；
- 首次读取、切换目标、树被截断、`max_depth`/`budget_ms` 变化时返回完整表；
- 差异超过 200 行会回退完整表，并在标题行说明；
- 差异太长、上下文丢失或不确定句柄时，传 `full=true` 要完整表。

- `[a]`：**优先用它**。标签只对**本次令牌**有效，动作工具都接受 `label`；
  标签大小写不敏感，`a` 与 `A` 等价。标签可能落在 `AXGroup`/`AXRow` 上（网页侧栏、表格行），
  不一定是 `AXButton`。
- `[角色#句柄]`：句柄是权威部分，也只在本次令牌内有效；`label` 与 `handle` 二选一。
- `frame=(x,y,w,h)`：屏幕点坐标，只用于对照截图/位置，不参与点击。
- 缩进表示层级；行尾 `(折叠 N)` 表示还有 N 个后代没显示。
- 属性：`subrole=`、`desc=`、`value=`、`id=`、`state=disabled`、`frame=`；空值省略。
- 没有标签的元素（静态文本、没在角色白名单里的行）仍然可以用句柄。
- **标签可点不等于应用会响应**：有的网页控件声明了 `AXPress` 但按下没有效果（网易云左侧栏），
  Edge 里的 `AXLink` 也可能如此。报告 `noOpSuspected=true` 时不要反复点；
  用 `get_screenshot` + `click_at` 走坐标点击。
- 元素太多时默认只显示 300 个（层级优先），用 `max_elements` 或 `focus` 展开：
  - `focus`：按标题/描述/值/标识符的子串匹配，只展开命中的子树；
  - `focus_role`：按角色过滤，如 `AXButton` 或 `Button`。
- 标题行有 `⚠️ 已截断` / `⚠️ 已达深度上限` / `⚠️ 策略：…` 时，先读警告再决定下一步。
- 推荐流程：先看概览 → 用 `focus` 展开目标区域 → 再有针对性地动作。

## 多窗口

先调用 `list_windows(pid)`，每行是 `"标题"<TAB>(x,y,w,h)`；没有标题显示 `-`。
把标题传给 `get_ax_state(pid, window="…")` 后，**元素表从该窗口开始读取**（根是 `AXWindow`），
句柄与标签都只在这个窗口的树里；`get_screenshot`、`click_at`、`scroll_at`、`drag` 也用这个窗口，
`click` / `type_text` / `press_key` / `set_value` 同样用令牌上的窗口标题定位。

窗口标题不存在、已改名或已关闭时返回 `window_not_found`：重新 `list_windows` 并选仍存在的窗口，
不要退回不带 `window` 的读取去猜。标题要精确匹配；多个同名窗口当前只选第一个，这是已知限制。
默认不传 `window` 时读取应用根，截图/坐标动作使用面积最大的非最小化窗口。

## 应用允许列表

服务可以用 `--allow-app` / `--allow-app-file` 启动，只允许操作列出的应用。
列表外的应用在读取和动作之前返回 `app_not_authorized`；不要重试或换相近应用，
告诉用户把应用加入允许列表并重启服务。允许列表是连接级的，不是逐动作审批。

## 启动应用：launch_app

`launch_app(app)` 接受 bundle id、显示名或 `.app` 路径。它先解析、再检查拒绝类目、
最后启动；已在运行的应用只激活，不重复启动。终端、脚本运行器、密码管理器、系统设置等会被拒绝。

启动成功只代表进程出现，不代表窗口/AX 树已就绪；随后用 `get_ax_state` 读取，
不要假设界面已经加载完。解析不到返回 `app_not_found`，不要猜相近的名字。

## 看界面：get_screenshot

`get_screenshot(token)` 截取当前令牌对应的**目标窗口**，把元素表里的 `[a]` 标签画在图上。
它只用来补布局信息；**文本元素表仍是权威**：

- 徽标太小、重叠或被裁掉时，按 `get_ax_state` 的标签选，不靠图猜；
- 需要屏幕录制权限（与辅助功能是两项独立授权，按宿主归属）；没有时返回
  `system_permission_missing`，让用户去“系统设置 > 隐私与安全性 > 屏幕录制”授权并重启宿主；
- 返回的 `screenshot_id` 绑定窗口位置与缩放。**窗口移动/缩放后必须重新截图**：
  服务不在动作前校验几何，旧截图的坐标会按旧位置换算，从而点到别处（只会在事后报 `geometryChanged=true` 或 `screenshotChanged`）；
- 截图不落盘、不写日志；不要把它当长期证据或上传到外部。

### 坐标点击 `click_at`

只有 `click(label)` 不生效、或目标根本没有 AX 元素时才用：

```text
click_at(token, screenshot_id, x, y)
```

- `x/y` 是截图内的像素坐标，左上角原点；
- 点击前会激活并 raise 目标窗口，确认它在前台；失败就不点，避免点到别的应用；
- 会移动真实光标；动作前在目标位置显示约 120ms 的蓝色指示环，它只是提示，不拦截、不进入截图，也不等于用户确认；
- 点击后重读 AX 树并比较全图像素比例：`treeChanged=false` 但 `screenshotChanged=true`
  说明画面有变化；两者都 false 才是 `noOpSuspected`，不要重复点；
- 越界返回 `invalid_coordinates`；截图不属于令牌或已过期返回 `stale_geometry`。
  注意 `stale_geometry` **不**覆盖窗口移动：几何变化不在动作前拦截，看到窗口可能被移动过就重新截图；

### 滚动与拖拽

```text
scroll_at(token, screenshot_id, x, y, dx, dy)   # dy>0 向下，dx>0 向右
drag(token, screenshot_id, from_x, from_y, to_x, to_y, duration_ms=400)
```

- 同样需要截图与前台窗口；都会移动真实光标；
- 滚动/拖拽后重读 AX 树并比较全图像素比例；
- 拖拽可能移动文件或列表项，**没有审批层**；不确定就不要拖；
- 起终点相同或越界返回 `invalid_coordinates`。

## 选哪个动作

| 意图 | 用 |
| --- | --- |
| 按按钮、复选、单选、菜单项、列表项 | `click` |
| 填表单、设置已知的完整值 | `set_value`（**首选**） |
| 需要在输入过程中触发搜索/校验/自动完成 | `type_text` |
| 提交、Tab、Escape、快捷键 | `press_key` |
| 启动或激活应用 | `launch_app`（bundle id / 名称 / `.app` 路径） |
| AX 点不动、或没有 AX 元素的网页/画布控件 | `click_at`（先 `get_screenshot`，最后手段） |
| 列表/画布滚动 | `scroll_at` |
| 拖动列表项/画布对象 | `drag`（高风险，先确认起终点） |

**`set_value` 是默认写入路径**：快、不经过输入法、不触发按键处理。它要求元素声明 `AXValue` 可写；
不可写时会返回 `unsupported_operation`，**不要**自己改成逐字输入再试一遍——那会改变副作用，
需要向用户说明并确认。

**`type_text`** 逐字符投递键盘事件：会触发应用的按键处理，也会触发输入法与快捷键。
中文等输入法行为未验证；能设值就优先设值。
换行与制表符分别按 Return 与 Tab 投递。多窗口时它会 raise 目标元素所在的窗口并切换前台，
因为键盘事件由进程的 key window 接收；B 窗口不会被误写，但前台会变。

**`press_key`** 的键名用 `+` 分隔，修饰键顺序无关：`Return`、`Tab`、`esc`、`cmd+c`、`shift+left`。
同样会先 raise 目标窗口、聚焦目标元素，再发键。输入与按键都会切换前台，`set_value` 不会。
如果元素已经是 first responder，不会重复设焦点，所以 `cmd+a` 后紧跟 `type_text` 会保留全选并替换选区。
快捷键要发给能成为 first responder 的内容元素（列表、文本框、画布），不要发给 `AXWindow` 根：
对窗口发快捷键可能只改变焦点，不触发应用命令（访达新建文件夹就是这样失败的）。

## 效果摘要怎么读

动作返回两行：一句人话，一行可解析：

```text
effect: delivered=true observed=true converged=true treeChanged=false targetChanged=false noOpSuspected=true polls=2 elapsed=0.4s
```

| 字段 | 含义 | 你该做什么 |
| --- | --- | --- |
| `delivered=true` | 平台没有报错。**不代表生效** | 继续看下面的字段 |
| `observed=false` | 事后读不到界面 | 不要重复点击；先 `get_ax_state` 确认 |
| `converged=false` | 3 秒内界面还在变 | 稍后重读，可能读到中间状态 |
| `treeChanged=true` | 界面结构或取值变了 | 旧令牌已作废，**必须重读** |
| `treeChanged=false` | 没变 | 令牌仍有效，但见下一行 |
| `noOpSuspected=true` | 已稳定且完全没变 | 核实动作是否真的生效（可能只改了树外状态） |
| `targetChanged=true` | 目标已不在原位置 | 重新读取后重新定位 |
| `unknown` | 树被截断，无法比较 | 当作"不知道"，重读确认 |

**"投递成功"不等于"用户看得见"。** `AXPress` 不看遮挡，被盖住的按钮也会被按下。
**"疑似空操作"不是失败**，是提示你去核实。

## 错误码与下一步

按 `code` 分支，不要解析 `message`：

| 错误码 | 含义 | 下一步 |
| --- | --- | --- |
| `stale_snapshot` | 令牌失效（界面变了或超时） | 重新 `get_ax_state`，用新令牌与新句柄 |
| `stale_geometry` | 截图不存在、已过期或不属于当前令牌 | 重新 `get_screenshot`，用新 `screenshot_id`；窗口移动不在动作前拦截 |
| `invalid_coordinates` | 坐标不在截图内 | 重新截图，使用截图内的坐标 |
| `element_gone` | 句柄不在该令牌的快照里 | 同上；先用 `focus` 按文本定位 |
| `target_switched` | 令牌属于另一个已切换走的目标 | 对当前目标重新读取 |
| `unsupported_operation` | 元素不支持该动作 / 键名不认识 | 换元素（父/子）或换动作，不要猜 |
| `app_not_found` | 启动/解析时找不到应用 | 用 bundle id、显示名或完整 `.app` 路径；不要猜相近名字 |
| `app_not_authorized` | 应用不在本次连接的允许列表里 | 让用户调整 `--allow-app` / `--allow-app-file` 并重启服务；不要重试 |
| `window_not_found` | 绑定的窗口标题不存在或已变化 | 重新 `get_ax_state` 查看窗口标题，绑定仍存在的窗口 |
| `policy_denied` | 命中拒绝类目 | **不可协商，不要绕过**；告知用户由他自己完成 |
| `system_permission_missing` | 宿主没有辅助功能权限 | 让用户给宿主授权并重启宿主 |
| `platform_unavailable` | 原生进程不可达 | 稍后重试一次；持续失败就报告 |
| `internal_error` | 参数或边界问题 | 检查参数，不要盲目重试 |

多个动作都成功、但界面始终没变时，停下来重读并核实，而不是继续点。

## 安全与禁止

- **拒绝类目不可绕过**：终端、脚本编辑器、密码管理器、系统设置、Cursor 及其宿主进程。
  读取这些应用是允许的；动作会被拒绝。不要改用 `osascript` / System Events 去完成被拒绝的动作。
- **不要在密码框、支付、删除、发送等不可逆步骤上自作主张。** v1 没有审批层；
  这类动作前先向用户确认，并说明你点的是哪个元素、在哪个应用。
- **不要把用户剪贴板、文件内容当作输入来源**，除非用户明确要求。
- 只操作任务需要的应用；不要浏览无关窗口。
- 输入内容会经过应用：可能触发自动完成、快捷键或提交。确认目标元素再输入。

## 效率建议

- 先概览再 `focus`，不要一上来就用很大的 `max_elements` 读全树。
- 读树有 15 秒预算；访达大目录、Electron 大树可能被截断。截断时用 `focus` 定点读，而不是重试。
- **每步动作后重读**是设计使然（令牌会被值变化作废）。不要为了省调用而复用旧句柄。
- 只读档不会拉起原生进程；`initialize` / `tools/list` 不需要权限。

## CEF/Chromium 应用（网易云这类）

有些应用（网易云音乐、部分 Electron 应用）正常启动时**不把界面暴露给无障碍**：
`get_ax_state` 只能看到 `AXWindow`，没有子元素。先判断是不是这一类：

- 窗口没有子元素、菜单栏之外读不到内容；
- 应用 bundle 里有 `Chromium Embedded Framework.framework` 或 `Electron Framework.framework`。

处理步骤（**必须先征得用户同意**，因为要退出并重启应用）：

```bash
pkill -TERM -x <应用进程名>   # 或让用户正常退出
open -a "<应用名>" --args --force-renderer-accessibility
```

重启后重新 `get_ax_state`。出现 `AXWebArea` 就说明恢复成功，可以正常读、点、输入、设值。
仍没有子元素时，如实告诉用户当前版本不支持该应用，**不要盲发按键或猜测坐标**。

代价：重启会中断用户当前状态（播放、未保存内容）；参数是 Chromium 的开关，不保证所有应用透传。
设计见 [ADR-0017](../../docs/decisions/adr_0017_cef_accessibility_launch.md)。

## 已知限制与失败模式

- **应用没在运行先 `launch_app`**：bundle id、显示名或 `.app` 路径都可以；解析不到返回 `app_not_found`，不要猜相近应用。
- **纯视觉界面**：截图与坐标可用，但需要屏幕录制权限；画布、图片、游戏没有 AX 结构，只能按坐标操作。
- **输入法未验证且已见副作用**：TextEdit 真实任务里 `cmd+a` 会插入中文“个护”，撤销也没有回到原值；
  `type_text` 对中文等输入法的行为不确定，表单优先 `set_value`。
- **内联重命名可能没有 AX 入口**：访达新建文件夹后，重命名输入框不在 AX 树里，发字符会变成空操作；
  不要猜测焦点，告诉用户需要手动改名。
- **Electron 应用的树大小会变**：同一窗口不同时刻可能读到不同规模的树；读到明显偏小时可稍后重读。
- **菜单**：菜单项可能在树里但未展开。点菜单栏项 → 重读 → 点菜单项；这条路径在真实应用上未充分验证。
- **`AXPress` 不看遮挡**：看不见的按钮也可能被按下，报告"成功"不代表用户能看到。
- **空操作判定有噪声**：动作只改了剪贴板/文件/窗口外状态时也会报 `noOpSuspected=true`。
- **策略拒绝只挡动作不挡读取**：被拒绝类目的应用仍可读，读到的内容可以用于定位问题。

## 示例：填写搜索框并提交

```text
1. list_apps → 找到目标应用 pid=1234
2. get_ax_state(pid=1234) → 令牌 s1abc.7，找到 [b] [AXTextField#4] "地址与搜索"
3. set_value(token="s1abc.7", label="b", value="example.com")
   → treeChanged=true，旧令牌作废
4. get_ax_state(pid=1234) → 新令牌 s1abc.8，输入框 value 已是 example.com（标签可能仍是 b）
5. press_key(token="s1abc.8", label="b", key="Return")
   → treeChanged=true
6. get_ax_state(pid=1234) → 读取结果
```

## 示例：切换一个设置项

```text
1. get_ax_state(pid=…) → 找到 [c] [AXCheckBox#12] "启用同步" value=0
2. click(token, label="c") → noOpSuspected=false / treeChanged=true
3. get_ax_state(pid=…) → 确认 [c] [AXCheckBox#12] 的 value 变成 1
   如果 value 没变但 treeChanged=true，说明变化发生在别处，不要假定成功
```

## 相关文档

- 工具与输出格式：[docs/interfaces/mcp_surface.md](../../docs/interfaces/mcp_surface.md)
- 元素表格式：[docs/interfaces/element_addressing.md](../../docs/interfaces/element_addressing.md)
- 输入与按键的设计：[docs/decisions/adr_0016_input_and_keys.md](../../docs/decisions/adr_0016_input_and_keys.md)
- 错误码表：[docs/interfaces/error_taxonomy.md](../../docs/interfaces/error_taxonomy.md)
- 权限与宿主归属：[docs/operations/permissions.md](../../docs/operations/permissions.md)
- 当前能力与限制：[docs/index.md](../../docs/index.md)
