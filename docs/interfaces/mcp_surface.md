# MCP 接入面（只读档与动作档）

`scu mcp` 以 MCP stdio 服务运行，是接入层的第一个实现。**默认只读**：
能读取应用与无障碍树，不能改变任何东西。**`scu mcp --actions` 额外暴露 `launch_app`、`click`、`click_at`、`scroll_at`、`drag`、`type_text`、`press_key`、`set_value`**（动作档）。
完整的会话 API 与 `js` 工具面是拟实施设计，见[协议总览](protocol_overview.md)。

## 导航

- [范围与定位](#范围与定位)：与 ADR-0002、ADR-0013 的关系
- [工具目录](#工具目录)、[元素表输出](#元素表输出)：对外的工具与返回形态
- [错误的两个通道](#错误的两个通道)、[JSON-RPC 处理](#json-rpc-处理)：协议行为
- [进程与清理](#进程与清理)：stdout 纪律、懒启动、被杀时的回收
- [未验证项](#未验证项)

## 范围与定位

[ADR-0002](../decisions/adr_0002_code_mode_surface.md) 决定对 agent 暴露 `js` / `js_reset` 的 code mode 工具面。
[ADR-0013](../decisions/adr_0013_p0_vertical_slice.md) 把"v1 是否带 code mode 运行时"列为待定。
接入后的使用指导（何时用、核心循环、动作选择、错误处理）见 [skills/scu/SKILL.md](../../skills/scu/SKILL.md)。

只读档因此先用**少量普通 MCP 工具**：协议层不依赖尚未选定的 JS 运行时，工具描述也更容易写清。
这是**实施顺序**的调整，不改变 ADR-0002 的方向；code mode 在运行时选定后再加，届时本文的工具目录需要重新评估。

只读档不需要拒绝清单：读取不改变桌面状态。动作档引入了**最小策略层**（拒绝类目，见
[策略层的 P0 实现](../architecture/policy_layer.md#p0_denylist)）、令牌会话与动作后的效果摘要；
另外可选**连接级应用允许列表**（[ADR-0024](../decisions/adr_0024_app_authorization.md)）。
仍然**没有**逐次审批、交互式授权提示、租约与审计。

**动作档默认关闭，由启动参数显式开启。** 未开启时 `click` 不出现在 `tools/list`，直接调用按未知工具处理
（JSON-RPC `-32602`）。这样默认接入的宿主即使被诱导也没有可调用的动作。

### 连接级应用允许列表

默认不限制应用（只受拒绝类目约束）。启动时传 `--allow-app <bundle|名称|路径>`（可重复）
或 `--allow-app-file <path>` 即进入允许列表模式：列表外的应用在**读取和动作之前**返回
`app_not_authorized`。`list_apps` 仍列出所有运行应用（只发现目标，不读内容）。

```bash
scu mcp --actions --allow-app com.netease.163music
scu mcp --actions --allow-app-file ~/.config/scu/pi-apps.json
```

- 一个 `scu mcp` 进程就是一个授权作用域；进程退出即失效，不需要宿主传 session id；
- 允许列表在启动时解析为 bundle id，解析不到就拒绝启动；
- 文件是只读输入，支持 JSON 数组或一行一个标识；`#` 开头的行忽略；
- 修改列表需要重启服务；不提供模型可自调的 `authorize_app` 工具（那会是假审批）；
- 与拒绝类目的顺序：先 `policy_denied`，再 `app_not_authorized`；
- 设计见 [ADR-0024](../decisions/adr_0024_app_authorization.md)。

<a id="tool_catalog"></a>

## 工具目录

每个工具都带 `title` 与 `annotations`（含 `title`、`readOnlyHint`、`destructiveHint`、`idempotentHint`、`openWorldHint`）。
只读工具四个：`check_permissions`、`list_apps`、`get_ax_state`、`get_screenshot`，均为 `readOnlyHint: true`、`destructiveHint: false`、`idempotentHint: true`、`openWorldHint: false`；
动作工具（仅 `--actions`）如实声明 `readOnlyHint: false`、`destructiveHint: true`、`idempotentHint: false`、`openWorldHint: true`。

| 工具 | 参数 | 作用 |
| --- | --- | --- |
| `check_permissions` | 无 | 报告启动本服务的宿主是否有辅助功能权限。权限未授予不算工具错误，是对状态的如实报告 |
| `list_apps` | 无 | 每行 `pid<TAB>名称<TAB>bundle id`（无 bundle id 时为 `-`） |
| `get_ax_state` | `pid`（必填）、`max_depth`、`budget_ms`、`max_elements`、`focus`、`focus_role` | 读取应用的无障碍树，返回带标签与 `frame` 的文本化元素表；`focus` 系列只展开一部分 |
| `get_screenshot` | `token` | 截取令牌对应的目标窗口，叠加标签，返回 PNG 与 `screenshot_id`；需要屏幕录制权限 |
| `launch_app`（仅 `--actions`） | `app` | 启动/激活应用（bundle id、名称或 `.app` 路径）；见下 |
| `click`（仅 `--actions`） | `token`、`handle` 或 `label`（二选一） | 对目标执行 `AXPress`；见下 |
| `click_at`（仅 `--actions`） | `token`、`screenshot_id`、`x`、`y` | 在截图坐标投递真实鼠标点击；见下 |
| `scroll_at`（仅 `--actions`） | `token`、`screenshot_id`、`x`、`y`、`dx`、`dy` | 在截图坐标投递滚轮事件；见下 |
| `drag`（仅 `--actions`） | `token`、`screenshot_id`、`from_x`、`from_y`、`to_x`、`to_y`、`duration_ms` | 在截图坐标拖拽；见下 |
| `type_text`（仅 `--actions`） | `token`、`handle` 或 `label`（二选一）、`text` | 先聚焦元素，再把文本逐字输入；见下 |
| `press_key`（仅 `--actions`） | `token`、`handle` 或 `label`（二选一）、`key` | 先聚焦元素，再发送按键或组合键；见下 |
| `set_value`（仅 `--actions`） | `token`、`handle` 或 `label`（二选一）、`value` | 通过无障碍接口直接写值，要求元素可写；见下 |

<a id="click_tool"></a>

### `launch_app`

启动或激活应用。`app` 可以是 bundle id、显示名或 `.app` 路径。顺序固定为
**解析 → 策略检查 → 启动**：终端、脚本运行器、密码管理器、系统设置等会被拒绝。
已在运行的应用只激活，不重复启动；启动后最多等 10 秒确认进程出现。
启动成功只代表进程存在，不代表 AX 树/窗口已就绪；随后用 `get_ax_state`。
解析不到返回 `app_not_found`。设计见 [ADR-0022](../decisions/adr_0022_app_launch.md)。

### `click`

动作的完整顺序：**策略 → 令牌 → 原生层核对 → 投递 → 事后观察**。前一步拒绝，后面都不执行。
`click`、`type_text`、`press_key` 走同一条路径，只有第 4 步的投递方式不同。

1. 策略：目标应用命中拒绝类目 → `policy_denied`（`retry=no`，不可协商）。先于令牌检查，所以失效令牌的受限应用仍报策略拒绝。
2. 令牌：未知或已失效 → `stale_snapshot`；属于已切换走的目标 → `target_switched`；
   标签或句柄不在快照里 → `element_gone`。给了 `label` 时先在同一快照里解析成句柄，再走后面的步骤。
3. 原生层沿路径核对（[ADR-0015](../decisions/adr_0015_handle_resolution_by_path.md)），不符 → `stale_snapshot`，**不执行**。
4. 投递 `AXPress`。目标不支持 → `unsupported_operation`；平台报错 → `action_failed`。
5. 事后观察：每 200 毫秒重读一次界面，**连续两次结构一致且这次读取未被截断**才算收敛；与动作前比较。
   总上限 3 秒是**时钟上限，在每次重读完成之后才检查**：单次重读仍受该次的 `budget_ms`（默认 15 秒）约束，
   所以大树上一次点击的耗时可以远超 3 秒（访达列表视图约 1.5 万个元素时，一次重读约 5 秒，已超过上限，只做一次重读就停止）。
   这些参数是启发式初值，见 [ADR-0011 追加记录](../decisions/adr_0011_convergence_over_fixed_delay.md)。

**返回的是观察到的效果，不是"成功"。** 第一行人话；第二行固定格式、可解析：

```text
effect: delivered=true observed=true converged=true treeChanged=false targetChanged=false noOpSuspected=true polls=2 elapsed=0.4s
```

| 字段 | 含义 | `unknown` 的情形 |
| --- | --- | --- |
| `delivered` | 平台没有报错。**不代表界面已经变化** | 恒为 true（失败时抛错，不返回摘要） |
| `observed` | 事后成功重读过界面 | 重读失败时为 false（动作已投递，不报失败，免得调用方重复点击） |
| `converged` | 连续两次重读结构一致，且这次读取未被截断 | 上限内一直在变化、或树被截断，则为 false；此时读到的是中间状态或不完整的树 |
| `treeChanged` | 与动作前相比结构是否变化 | 动作前或动作后的读取被截断，无法比较 |
| `targetChanged` | 最后一次重读的树里，目标已不在原路径上或核对键不符（**不要求已收敛**） | 最后一次重读被截断 |
| `noOpSuspected` | 已收敛且结构完全没变：**疑似**空操作 | 同 `treeChanged` |

结构变化时**调用所用的令牌作废**，但不签发新令牌，需要重新 `get_ax_state`；
结构没变（含疑似空操作）时令牌仍有效。无法判断时（截断）不作废，下一次动作由原生层再核对一遍目标。

"疑似空操作"的含义有限：动作只改变了无障碍树之外的东西（剪贴板、文件、窗口外状态）时同样会触发，
所以它是"请核实"的提示，不是失败判定。

<a id="input_tools"></a>

### `click_at`

坐标点击是**最后手段**：优先 `click`；只有 AX 动作无效或没有 AX 元素时再用。

1. 坐标以 `get_screenshot` 的图像左上角为原点，单位是图像像素；越界返回 `invalid_coordinates`。
2. `screenshot_id` 必须属于当前令牌且窗口几何未变；否则 `stale_geometry`。
3. 点击前会激活并 raise 目标窗口，确认它成为 frontmost；失败则**不点击**，避免点到别的应用。
   随后在目标位置显示约 120ms 的蓝色指示环（不在截图里），再投递事件。
4. 用真实鼠标事件（会移动光标），不是 `CGEvent.postToPid`。
5. 点击后重读 AX 树，并再截一张图比较全图像素比例：
   结构变化 → 令牌作废；树没变但图变了 → `screenshotChanged=true`；
   树和图都没变 → `noOpSuspected=true`；窗口几何变了 → `geometryChanged=true`。
   全图比例不定位变化区域，也不证明点中了目标；不要重复点。

设计见 [ADR-0020](../decisions/adr_0020_coordinate_click.md)。

### `scroll_at`

在截图坐标 `(x,y)` 投递滚轮事件。`dy > 0` 向下，`dx > 0` 向右；增量为 0 返回
`invalid_coordinates`。与 `click_at` 相同：截图绑定令牌、先激活目标窗口、显示指示环、真实事件；
滚动后重读 AX 树并比较全图像素比例。设计见 [ADR-0021](../decisions/adr_0021_scroll_and_drag.md)。

### `drag`

在截图坐标内从 `(from_x, from_y)` 拖到 `(to_x, to_y)`，`duration_ms` 默认 400。起终点相同或越界
返回 `invalid_coordinates`；起点与终点会各显示一个指示环。拖拽可能移动文件/列表项，属于高风险动作；没有审批层之前只用于
低风险、可逆的场景。验证同样是 AX 树 + 全图像素比例。

### `type_text`、`press_key` 与 `set_value`

两者都要求**显式的目标元素**（`token`，加 `handle` 或 `label`），顺序与 `click` 相同：
策略 → 令牌 → 原生层沿路径核对 → 聚焦该元素 → 投递键盘事件 → 事后观察。

- **聚焦**：设置元素的 `AXFocused`，最多等约 300 毫秒被读回为 true。不接受"当前的焦点元素"这种隐式目标，
  因为写错位置可能触发搜索、发送或提交，代价不可逆。
- **投递**：`CGEvent` 键盘事件直接投递到目标进程（`postToPid`），
  **不激活应用、不移动鼠标、不抢前台**。
- `type_text` 逐字符投递 Unicode；换行与制表符分别按 Return 与 Tab 投递；文本上限 10000 字符。
- `press_key` 的键名用 `+` 分隔，修饰键顺序无关：`Return`、`Tab`、`esc`、`cmd+c`、`shift+left`。
  修饰键用事件 `flags` 表达；每次都是 down + up，**不跨动作保持按住状态**。
- 不认识的键名、空键名、多个主键、空文本都会被拒绝，不猜测；元素不接受焦点时返回 `unsupported_operation`。
- `set_value` 走无障碍设值：**要求元素声明 `AXValue` 可写**，否则 `unsupported_operation`，
  不回退到逐字输入；不需要聚焦，不经过键盘与输入法；空串表示清空字段。
- 效果摘要与令牌规则与 `click` 相同：输入与设值都会改值，所以**通常每次动作后都要重读**。

两者的设计取舍见 [ADR-0016](../decisions/adr_0016_input_and_keys.md)。

`get_ax_state` 的参数范围：

| 参数 | 范围 | 默认 | 超出时 |
| --- | --- | --- | --- |
| `pid` | 1 到 Int32 上限 | 无 | 拒绝 |
| `max_depth` | 0 到 64 | 12 | 拒绝，不静默截断 |
| `budget_ms` | 100 到 120000 | 15000 | 拒绝 |
| `max_elements` | 1 到 20000 | 300 | 拒绝 |
| `focus` | 字符串 | 无 | 类型错误时拒绝；空串等价于未给出 |
| `focus_role` | 字符串 | 无 | 同上 |

- **拒绝未声明的参数。** 拼错的参数名被静默忽略，调用方会以为生效了。
- 整数参数接受小数部分为 0 的浮点数（部分客户端把 `12` 序列化成 `12.0`）。
- 范围与默认值的来源：`budget_ms`、`max_elements` 来自 `SCUWire` 的常量与 `ElementTable`；`max_depth` 默认值来自 `SCUWire` 的 `scuDefaultTreeDepth`（`scu dump` 共用）。工具描述里的数字由它们生成，不手写。

<a id="element_table_output"></a>

### `get_screenshot`

只读，截取 `get_ax_state` 令牌对应的**目标窗口**（不是整屏），返回一张带标签徽标的 PNG：

```text
screenshot_id=g1abc.1 图像 1600x1138 scale=1.514 window=(353,199,1057,752)
图上 [a] 是 get_ax_state 的标签；标签只对本次令牌有效。
```

- **权限**：需要屏幕录制，与辅助功能是两项独立授权，按宿主进程归属；未授予时为
  `system_permission_missing`，文案指向“屏幕录制”。
- **坐标**：图像像素 = `(element.frame - windowFrame) * scale`；`windowFrame` 可为负（副屏）。
- **绑定**：`screenshot_id` 绑定 `token + windowFrame + scale`；窗口移动/缩放后旧截图不能用于坐标动作。
- **权威**：文本元素表仍为准。徽标太小、重叠或被裁掉时，按 `get_ax_state` 的标签选，不靠图猜。\n  图上可能标出文本表因 `max_elements`/`focus` 未显示的元素；这些标签仍然可用，但优先使用文本表里的。
- **隐私**：截图只返回给调用方，不写日志、不落盘；可能包含敏感内容，不要把它当作可长期保存的证据。

## 元素表输出

`get_ax_state` 返回的文本由标题行与元素表组成。元素表格式见[元素寻址](element_addressing.md#readonly_subset)。

可交互元素带一个快照内短标签，行尾带 `frame`：

```
[a] [AXButton#129] "search" frame=(120,40,24,24)
[b] [AXTextField#132] value="" frame=(150,40,300,28)
```

标签只对本次令牌有效，`click` / `type_text` / `press_key` / `set_value` 可以用 `label` 代替 `handle`；
两者必须二选一。标签可能落在 `AXGroup`/`AXRow` 上（网页侧栏、表格行），不一定是按钮。
`frame` 只用于阅读与后续截图叠加，不参与动作定位。
**标签可点不等于应用会响应**：网易云左侧栏声明了 `AXPress`，但 `click(label)` 返回
`noOpSuspected=true`；这类控件需要坐标点击（尚未实现）。设计见
[ADR-0018](../decisions/adr_0018_label_addressing.md)。

### 概览与展开

元素多于 `max_elements` 时**按层级优先取舍**，不是取先序的前 N 个。先序截断会让第一棵大子树
（如访达的侧边栏）占满配额，窗口主体与工具栏一个都看不到——这是首次接入 Cursor 时实际遇到的问题。
层级优先的规则：从根开始整层放入，放不下的那一层按先序放满剩余配额。
被折叠的元素行尾标 `(折叠 N)`，N 是其下**未显示的后代数**；每个显示的元素加上其折叠数，总和等于树的元素总数。

要看某一部分，用 `focus`（与标题、描述、值、标识符做不区分大小写的子串匹配）和/或 `focus_role`
（角色，`Button` 与 `AXButton` 等价；两个同时给出时需同时满足）：

- 只展开**最外层**命中的子树（命中元素的后代即使也匹配，也不另起一段），最多 20 处，超出的只计数。
- 每段子树前有一行祖先链，说明它在树的哪里：`@ ` 加各级祖先的 `角色` 或 `角色 "标签"`（标签取 title，否则 description），用 ` > ` 连接；命中的是树根时写 `@ （树根）`。缩进相对该子树根从 0 起。
- 配额在各段之间按层级优先共享。
- 句柄仍是**完整树**里的先序编号，所以同一次读取内，带 `focus` 与不带 `focus` 的输出里同一元素的句柄相同。
  每次调用都重新读取。句柄与**令牌**配对：同一目标应用、结构摘要不变且截断标志相同时，再次读取沿用同一个令牌，句柄编号也相同；
  否则签发新令牌，**旧令牌的句柄不能带到新令牌**。结构摘要覆盖 role、subrole、title、identifier、value、roleDescription、description、enabled、
  子节点数、深度与节点数，**不含 frame**：所以取值或启用状态变化也会换令牌，窗口移动不会。
  会话只保留最近 16 个令牌，更早的与从未签发过的一样按 `stale_snapshot` 拒绝。
  引用句柄时必须同时给令牌；不确定时用 `focus` 的文本条件重新定位。
- 没有命中不是错误；标题行写明"没有元素匹配 focus。"，树被截断时追加"树不完整（见下），匹配的元素可能没读到。"。

`focus` 不缓存：每次调用都重新读取整棵树，所以展开一块的耗时与概览相同。

### 令牌

标题行携带**快照令牌**：不透明字符串，由会话签发（[ADR-0015](../decisions/adr_0015_handle_resolution_by_path.md)）。
令牌的失效类别、复用规则与"重复使用失效令牌"的语义见[快照生命周期](../architecture/snapshot_lifecycle.md#p0_implementation)。
令牌出现在 `get_ax_state` 的输出里；接受它的动作工具是 `click` / `type_text` / `press_key` / `set_value`（仅动作档），
只读工具 `get_screenshot` 也接受同一个令牌。

### 完整性标注

标题行 `# pid=<pid> 令牌 <令牌> 元素 <总数>` 之后是标签、句柄与令牌的配对说明（动作档写"可交互元素前的 [a] 是本次快照的标签，动作工具可用 label 代替 handle"与"用 click(token, handle) 点击"；默认档写"目前没有工具接受句柄（动作档未开启）。"），
再之后可能跟这些**警告行**，调用方据此判断输出是否完整：

| 情形 | 标注 |
| --- | --- |
| 读取预算耗尽 | `⚠️ 已截断：… 毫秒的读取预算耗尽，树不完整` |
| 树达到深度上限 | `⚠️ 已达深度上限 N：更深的节点未读取` |
| 目标应用属于拒绝类目 | `⚠️ 策略：<应用> 属于拒绝类目 <id>，对它的动作会被拒绝（读取不受限）。`（不是完整性问题，但同样在标题区） |
| 元素数超过 `max_elements` | 标题行写明"显示 N"与"按层级优先显示"，被折叠的元素行尾标 `(折叠 N)` |

截断**不是错误**：返回的是真实读到的部分，并明确标注不完整。静默返回残缺的树会让模型把"没读到"当成"不存在"。

<a id="error_channels"></a>

## 错误的两个通道

| 情形 | 通道 | 形态 |
| --- | --- | --- |
| 未知工具、缺少 `name`、未知方法、JSON 不合法 | JSON-RPC 错误 | `error.code` 为 -32602 / -32601 / -32700 / -32600 |
| 参数无效、权限缺失、目标不存在、原生进程不可用 | 工具结果 | `isError: true`，文本以 `[code]` 开头 |

工具层面的失败走结果而不是 JSON-RPC 错误，是因为模型能读到结果文本并自行纠正（改参数、重读），
而协议错误通常只被宿主当作故障处理。

工具错误文本形如 `[system_permission_missing] 未授予系统权限：辅助功能（retry=after_user_action）`，
`code` 取自[错误码表](error_taxonomy.md)，参数错误用 `invalid_argument`。协议层与原生层的错误文本带 `（retry=…）`；
`invalid_argument`（接入层自己的码）与兜底的 `internal_error` 没有。
按 `code` 追加一段处置提示（按 `code` 分支，不解析 `message`）：

| `code` | 追加的提示 |
| --- | --- |
| `stale_snapshot`、`element_gone` | 重新 `get_ax_state` 取得新令牌与句柄；用 `focus` 按文本重新定位 |
| `stale_geometry`、`invalid_coordinates` | 重新 `get_screenshot`，使用截图内的坐标 |
| `app_not_found` | 用 bundle id、显示名或完整 `.app` 路径重试 |
| `app_not_authorized` | 让用户把应用加入 `--allow-app` / `--allow-app-file` 并重启服务；不要换相近应用重试 |
| `click_at` 的 `noOpSuspected` | 树与图都没变；不要重复点，必要时让用户核实 |
| `target_switched` | 令牌属于之前读取的另一个应用，对要操作的应用重新读取 |
| `unsupported_operation` | 该元素不支持这个动作（不能点击、不接受焦点、或不认识键名）；可尝试父元素、子元素或改换方式 |
| `policy_denied` | 不可协商，不要重试或绕过，告知用户由他自己完成 |
| `system_permission_missing` | 权限按宿主应用归属，给启动本服务的应用授予辅助功能权限 |

`invalid_argument` 是接入层自己的码，已登记进[错误码表](error_taxonomy.md)的接入层一节（见该文）。
另有一个到不了的 `tool_unavailable`：动作档未开启时 `click` 在 `MCPServer` 就按未知工具走 JSON-RPC `-32602`，不会进到工具层。

<a id="jsonrpc_handling"></a>

## JSON-RPC 处理

传输是 MCP 的 stdio 形态：**每行一条 JSON 消息，换行分隔**。消息内不含换行
（元素文本里的换行被转义为 `\n`，所以不会破坏消息边界）。

| 输入 | 行为 |
| --- | --- |
| `initialize` | 客户端请求的协议版本在支持列表内则原样回显，否则回复列表第一项。列表：`2025-06-18`、`2025-03-26`、`2024-11-05`。缺少 `protocolVersion` 参数时 -32602。应答还带 `capabilities.tools.listChanged=false` 与 `serverInfo`（`name: scu`，`version: 0.1.0`） |
| `ping` | 回复空结果 |
| `tools/list`、`tools/call` | 见上文 |
| 不带 `id` 的消息（通知） | 不回复，包括未知通知 |
| 带 `id` 的未知方法 | -32601 |
| 客户端发来的应答（有 `result` / `error`、无 `method`） | 忽略。本服务从不向客户端发请求 |
| JSON 数组（批处理）与非对象 | -32600。2025-06-18 规范已移除批处理 |
| `id` 为 null 或非字符串/整数 | -32600 |
| 空行 | 忽略 |

`id` 的类型原样回传（字符串回字符串，整数回整数）。
`initialize` 的应答带 `instructions`：整体使用说明（只读档或动作档、典型流程、句柄与令牌配对）；两档各有一份，动作档的说明提到拒绝类目与"疑似空操作"。
工具的细节在各自的 `description` 里。

不检查"是否已 `initialize`"：宽松处理，先收到 `tools/list` 也会回复。

<a id="process_lifecycle"></a>

## 进程与清理

- **stdout 只有协议消息。** 任何诊断都写 stderr。原生进程的 stdout 被重定向到 stderr、stdin 断开，
  所以它既不会混入协议流，也不会读走协议流。这一点由端到端测试与 `scripts/check.sh` 冒烟检查。
- **懒启动。** `initialize` 与 `tools/list` 不拉起原生进程；首次工具调用才启动。
  宿主只是列出工具时不应产生子进程。
- **自动重建。** 原生进程崩溃或读树超时被终止后（`platform_unavailable`），丢弃旧连接，
  下一次调用重新拉起。长驻服务不能因一次失败永久不可用。
- **EOF 正常退出。** stdin 关闭后结束循环，终止原生进程，删除 socket 目录。
- **被 SIGTERM / SIGINT / SIGHUP 终止。** 信号处理器终止原生进程并删除其 socket 目录，退出码 128 + 信号。
- **被 SIGKILL 终止。** `scu` 无法清理；原生进程发现连接断开后退出，并回收
  `scu-` 开头的 socket 目录（空目录才会被删）。读树进行中被杀时，原生进程会工作到时间预算耗尽才退出。
- **宿主关闭输出管道。** 忽略 SIGPIPE，写失败时结束循环并正常清理。

socket 目录建在 `TMPDIR`（若设置且存在）或系统临时目录下。

<a id="unverified"></a>

## 未验证项

- **真实应用上的动作只验证了一个**：网易云音乐 `3.1.12`（CEF），以 `--force-renderer-accessibility` 启动后，
  `type_text`（中文）、`press_key(Return)`、`click` 与播放器状态核实均成立，见
  [真实应用验证](../../verification/2026-10-19-real-app-netease.md)。
  该应用**正常启动时不暴露 AX**；启动参数与用户同意见 [ADR-0017](../decisions/adr_0017_cef_accessibility_launch.md)。
  其他第三方应用、Electron、输入法（IME）与坐标类场景仍未验证。

- **`click` 除网易云（带 CEF 启动参数）外，只在自制夹具 `scu-fixture` 上真实点击过**；访达上只做过 `verify`（不点击）。
  没有经 Cursor 宿主调用过动作工具。
- **标签寻址只在网易云上真实验证过**：`type_text(label="b")`、`set_value(label="b")` 与 `click(label="a")` 成立（2026-10-19），
  其他应用未验证。见 [真实应用验证](../../verification/2026-10-19-real-app-netease.md#追加快照内标签同日)。夹具验证的结论与缺口见
  [verification/2026-10-18-fixture-validation.md](../../verification/2026-10-18-fixture-validation.md)：
  `AXPress` 不看遮挡；两秒后才出现的变化会被判为已收敛；同一容器里加一个兄弟就会令路径上的句柄被保守地拒绝。

- **只在 Cursor 一个宿主里运行过**（2026-10-16，用户级 `~/.cursor/mcp.json`，macOS 26.6.2，Cursor 版本未记录）。
  观察到：握手成功；三个工具都被识别；`initialize` 的 `instructions` 被作为服务描述呈现给模型；
  `check_permissions`、`list_apps`、`get_ax_state` 的调用都成功。Cursor 还在工具列表里额外注入了一个 `mcp_auth`，不是本服务提供的。
- **`get_screenshot` / `click_at` 只在网易云 3.1.12 上验证过**：截图 1600×1138、`scale=1.514`；
  左侧栏坐标点击从「推荐」切到「精选」并成功返回（2026-10-20）。
  滚动已在网易云验证（推荐页上下滚动，diff 约 0.387）；拖拽只有单元/MCP 测试，真实应用未验证。
  其他应用、多窗口选择、窗口移动后的过期判断、区域级 diff 未验证。
- **应用允许列表**：已做单元与 MCP 测试；已在网易云/访达上验证“列表外应用读取前被拒”。
  动作门禁与 `--allow-app-file` 的文本格式还有单元测试覆盖；允许列表不是逐动作审批，也不包含交互式授权 UI。
- **`launch_app` 已验证冷启动（计算器）与已运行（网易云）**：返回 pid、终端拒绝、未知应用错误均成立。
  非标准路径与“启动后等待 AX 就绪”未验证。
  `isError` 的呈现、其他宿主（Claude Desktop 等）都未观察。
- **宿主的权限归属只有一个数据点。** 在上述 Cursor 环境里，`check_permissions` 返回已授予。
  这只说明该环境下成立，不能推到其他宿主或其他机器；归属的是哪个进程（Cursor 本体还是辅助进程）没有核对。
  见 [macOS 权限](../operations/permissions.md)。
- **读取大树时仍会触发 15 秒预算截断**（访达打开两个窗口时 3000 多个元素）。遍历已改为广度优先，
  截断时丢弃的是最深的节点，工具栏、窗口控件、菜单栏等上层结构仍然完整（用访达实测，见上文"概览与展开"）。
  同一应用不同时刻的元素数差异很大（871、1884、3269），原因是窗口状态不同，没有逐一核对。
- **读大树的耗时。** 在 Cursor 里读访达（3000 多个元素，窗口里有大列表）曾读满 15 秒预算才返回。
  之后原生层改为每个节点一次批量属性读取，命令行下实测快 1.8 到 2.6 倍（见
  [读树耗时记录](../../verification/2026-10-17-read-latency.md)）。
  在访达打开 1500 个文件的目录（列表视图，约 1.5 万个元素）复现：旧版命令行 31 秒，新版 5 秒，
  经 Cursor 宿主读取新版**不再触发默认的 15 秒截断**。
  但当初 3000 多个元素读满 15 秒的原因仍没有解释（元素数与旧版推算耗时都对不上），见记录里的"没有回答的问题"。
- **同一应用相邻两次读取的句柄编号不同**（概览里工具栏是 #2662，随后的 `focus` 里是 #2574）。
  这符合"句柄只在一次读取（同一令牌）内有效"，但也说明被预算截断的树，截断位置每次不同，先序编号随之漂移。
- **`state=disabled` 可能有噪声**：访达的 `AXApplication` 元素被标为 disabled，是否真实反映 `AXEnabled` 还是该属性对应用元素无意义，未核实。
- **Electron 应用的树大小随读取时机变化**，原因未查明，见[本地环境](../operations/local_setup.md#已知缺口p0-内待处理)。
- **元素表对模型是否好用**未经评估：默认上限 300 是估计值（约 7 千 token 量级，未实测），不是依据数据定的；
  层级优先与 `focus` 已在 Cursor 里对访达用过一次（2026-10-16）：概览 60 个元素能看到两个窗口的工具栏、窗口按钮与菜单栏，
  `focus_role: Toolbar` 能单独展开两个窗口的工具栏，类型错误的参数被 `[invalid_argument]` 拒绝。
  模型是否会自己按"先概览、再 focus"的流程用，没有观察（这次调用是我按流程手动发起的）。

## 相关文档

- [协议总览](protocol_overview.md)：完整的会话 API（拟实施）
- [元素寻址](element_addressing.md)：元素表格式与只读子集
- [错误与拒绝](error_taxonomy.md)
- [原生层线协议](native_wire_protocol.md)
- [本地环境](../operations/local_setup.md)：如何把 `scu mcp` 接入宿主
- [ADR-0002](../decisions/adr_0002_code_mode_surface.md)、[ADR-0013](../decisions/adr_0013_p0_vertical_slice.md)
