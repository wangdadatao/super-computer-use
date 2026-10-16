# MCP 接入面（只读档）

`scu mcp` 以 MCP stdio 服务运行，是接入层的第一个实现。**本档只读**：
能读取应用与无障碍树，不能点击、输入或改变任何东西。
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
只读档因此先用**少量普通 MCP 工具**：协议层不依赖尚未选定的 JS 运行时，工具描述也更容易写清。
这是**实施顺序**的调整，不改变 ADR-0002 的方向；code mode 在运行时选定后再加，届时本文的工具目录需要重新评估。

只读档**没有**策略层、会话与租约、动作与效果摘要——这些随动作档引入。
因此它不需要拒绝清单：读取不改变桌面状态。

<a id="tool_catalog"></a>

## 工具目录

三个工具，全部带 `readOnlyHint: true`、`destructiveHint: false`。

| 工具 | 参数 | 作用 |
| --- | --- | --- |
| `check_permissions` | 无 | 报告启动本服务的宿主是否有辅助功能权限。权限未授予不算工具错误，是对状态的如实报告 |
| `list_apps` | 无 | 每行 `pid<TAB>名称<TAB>bundle id`（无 bundle id 时为 `-`） |
| `get_ax_state` | `pid`（必填）、`max_depth`、`budget_ms`、`max_elements` | 读取应用的无障碍树，返回文本化元素表 |

`get_ax_state` 的参数范围：

| 参数 | 范围 | 默认 | 超出时 |
| --- | --- | --- | --- |
| `pid` | 1 到 Int32 上限 | 无 | 拒绝 |
| `max_depth` | 0 到 64 | 12 | 拒绝，不静默截断 |
| `budget_ms` | 100 到 120000 | 15000 | 拒绝 |
| `max_elements` | 1 到 20000 | 1500 | 拒绝 |

- **拒绝未声明的参数。** 拼错的参数名被静默忽略，调用方会以为生效了。
- 整数参数接受小数部分为 0 的浮点数（部分客户端把 `12` 序列化成 `12.0`）。
- 范围与默认值的来源是 `SCUWire` 的常量与 `ElementTable`，工具描述里的数字由它们生成，不手写。

<a id="element_table_output"></a>

## 元素表输出

`get_ax_state` 返回的文本由标题行与元素表组成。元素表格式见[元素寻址](element_addressing.md#readonly_subset)。

标题行 `# pid=<pid> 元素 <总数>` 之后可能跟这些**警告行**，调用方据此判断输出是否完整：

| 情形 | 标注 |
| --- | --- |
| 读取预算耗尽 | `⚠️ 已截断：… 毫秒的读取预算耗尽，树不完整` |
| 树达到深度上限 | `⚠️ 已达深度上限 N：更深的节点未读取` |
| 元素数超过 `max_elements` | 标题行写明"仅输出前 N 个"，其余已省略 |

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
`code` 取自[错误码表](error_taxonomy.md)，参数错误用 `invalid_argument`。
**权限类错误附加一句宿主归属的提示**，其他错误不附加；按 `code` 分支，不解析 `message`。

`invalid_argument` 是接入层自己的码，**尚未登记进错误码表**：只读档的错误面还很小，
等动作档引入更多接入层错误时一起整理。

<a id="jsonrpc_handling"></a>

## JSON-RPC 处理

传输是 MCP 的 stdio 形态：**每行一条 JSON 消息，换行分隔**。消息内不含换行
（元素文本里的换行被转义为 `\n`，所以不会破坏消息边界）。

| 输入 | 行为 |
| --- | --- |
| `initialize` | 客户端请求的协议版本在支持列表内则原样回显，否则回复列表第一项。列表：`2025-06-18`、`2025-03-26`、`2024-11-05` |
| `ping` | 回复空结果 |
| `tools/list`、`tools/call` | 见上文 |
| 不带 `id` 的消息（通知） | 不回复，包括未知通知 |
| 带 `id` 的未知方法 | -32601 |
| 客户端发来的应答（有 `result` / `error`、无 `method`） | 忽略。本服务从不向客户端发请求 |
| JSON 数组（批处理）与非对象 | -32600。2025-06-18 规范已移除批处理 |
| `id` 为 null 或非字符串/整数 | -32600 |
| 空行 | 忽略 |

`id` 的类型原样回传（字符串回字符串，整数回整数）。
`initialize` 的应答带 `instructions`：整体使用说明（只读档、典型流程、句柄只在单次输出内有效）。
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

- **只在 Cursor 一个宿主里运行过**（2026-10-16，用户级 `~/.cursor/mcp.json`，macOS 26.6.2，Cursor 版本未记录）。
  观察到：握手成功；三个工具都被识别；`initialize` 的 `instructions` 被作为服务描述呈现给模型；
  `check_permissions`、`list_apps`、`get_ax_state` 的调用都成功。Cursor 还在工具列表里额外注入了一个 `mcp_auth`，不是本服务提供的。
  `isError` 的呈现、其他宿主（Claude Desktop 等）都未观察。
- **宿主的权限归属只有一个数据点。** 在上述 Cursor 环境里，`check_permissions` 返回已授予。
  这只说明该环境下成立，不能推到其他宿主或其他机器；归属的是哪个进程（Cursor 本体还是辅助进程）没有核对。
  见 [macOS 权限](../operations/permissions.md)。
- **Finder 的读取在该环境下触发了 15 秒预算截断**（1884 个元素，窗口里有长列表）；同一应用较早一次读取为 871 个且未截断，
  原因未查明（窗口状态不同，或宿主下 AX 调用更慢，两者都没有区分）。
- **`state=disabled` 可能有噪声**：访达的 `AXApplication` 元素被标为 disabled，是否真实反映 `AXEnabled` 还是该属性对应用元素无意义，未核实。
- **Electron 应用的树大小随读取时机变化**，原因未查明，见[本地环境](../operations/local_setup.md#已知缺口p0-内待处理)。
- **元素表对模型是否好用**未经评估：1500 个元素的默认上限是估计值，不是依据数据定的。

## 相关文档

- [协议总览](protocol_overview.md)：完整的会话 API（拟实施）
- [元素寻址](element_addressing.md)：元素表格式与只读子集
- [错误与拒绝](error_taxonomy.md)
- [原生层线协议](native_wire_protocol.md)
- [本地环境](../operations/local_setup.md)：如何把 `scu mcp` 接入宿主
- [ADR-0002](../decisions/adr_0002_code_mode_surface.md)、[ADR-0013](../decisions/adr_0013_p0_vertical_slice.md)
