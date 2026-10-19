# 原生层线协议

协议层（`scu` 进程）与原生层（`scu-native` 进程）之间的帧格式、消息目录与握手规则。
agent 侧的会话 API 见[协议总览](protocol_overview.md)，两者是不同的边界：
本文是**内部契约**，agent 不直接接触。进程划分的理由见[系统总览](../architecture/system_overview.md#process_boundary)，
版本策略见 [ADR-0012](../decisions/adr_0012_protocol_versioning.md)。

## 导航

- [传输与帧](#传输与帧)、[消息目录](#消息目录)：线上长什么样
- [握手与版本](#握手与版本)、[连接生命周期](#连接生命周期)：建立与结束
- [错误](#错误)、[格式约束](#格式约束)、[当前实现范围](#当前实现范围)

<a id="frame_format"></a>
## 传输与帧

- **传输**：Unix domain socket。socket 文件放在协议层创建的 `0700` 私有目录里。
- **帧**：4 字节大端无符号长度 + UTF-8 JSON 主体。长度只计主体。
- **单帧上限**：64 MiB。收到超长的长度头时不读取主体，应答错误后关闭连接
  （主体未被消费，已无法再对齐帧边界）。
- **请求/应答**：每个请求帧带整数 `id`，应答帧回显同一个 `id`。当前同一连接上同时只有一个未决请求
  （动作在会话内串行，见[会话与控制租约](../architecture/session_and_lease.md)），
  `id` 用于发现错位，而不是用于多路复用。**例外**：超长帧与无法解码的帧没有可回显的 `id`，原生层用 `id: 0` 回 `internal_error` 后关闭连接；能解码的请求（握手前、越界、畸形定位器）正常回显。
- **写失败**：对端已关闭时写入必须失败为可处理的错误，**不得让进程死于 SIGPIPE**。
  实现上在每个 socket 上设置 `SO_NOSIGPIPE`。协议层把传输失败统一映射为
  `platform_unavailable`，不向调用方泄漏底层错误类型。

请求帧与应答帧：

```json
{"id": 1, "request":  {"type": "hello", "protocolVersion": 1}}
{"id": 1, "response": {"type": "hello", "protocolVersion": 1}}
```

<a id="message_catalog"></a>
## 消息目录

消息是**扁平对象**，以 `type` 字段区分种类，其余字段与种类相关。
这个格式是**显式定义的契约**，不是语言运行时的合成编码——
实现与测试都固定了它的字节级形状，重构不得静默改变。

### 请求

| `type` | 字段 | 含义 |
| --- | --- | --- |
| `hello` | `protocolVersion: int` | 握手，必须是连接上的第一个请求 |
| `checkPermissions` | — | 查询辅助功能权限 |
| `listApps` | — | 列出可绑定的应用（常规激活策略） |
| `dumpTree` | `pid: int`、`maxDepth: int`、`budgetMs: int` | 读取某进程的无障碍树。`maxDepth` 范围 `0...64`；`budgetMs` 是整棵树的总时间预算，范围 `100...120000`。越界一律拒绝而不是截断 |
| `performAction` | `pid: int`、`locator: ElementLocator`、`action: "press" \| "verify"` | 沿定位器的路径定位目标并核对，通过后执行动作；`verify` 只定位核对、不执行。路径长度上限同 `maxDepth`，每步须满足 `siblings ≥ 1` 且 `0 ≤ index < siblings`，否则 `internal_error`（连接保持）。见 [ADR-0015](../decisions/adr_0015_handle_resolution_by_path.md) |
| `typeText` | `pid: int`、`locator: ElementLocator`、`text: string` | 定位并核对目标，聚焦它，再把文本逐字投递到目标进程。`text` 上限 10000 字符，空串被拒绝。见 [ADR-0016](../decisions/adr_0016_input_and_keys.md) |
| `pressKey` | `pid: int`、`locator: ElementLocator`、`key: string` | 定位并核对目标，聚焦它，再发送按键或组合键（`cmd+shift+t`）。不认识的键名被拒绝。见 [ADR-0016](../decisions/adr_0016_input_and_keys.md) |

### 应答

| `type` | 字段 | 对应请求 |
| --- | --- | --- |
| `hello` | `protocolVersion: int` | `hello` |
| `permissions` | `accessibility: bool` | `checkPermissions` |
| `apps` | `apps: [{pid, name, bundleId?}]` | `listApps` |
| `tree` | `tree: AXNode`、`truncated: bool` | `dumpTree`。`truncated` 为真表示时间预算耗尽、树不完整；深度上限造成的未展开不算截断（那是调用方的选择）。**遍历按层级（广度优先）进行**，预算耗尽时丢弃的是尚未读取的最深节点，已读部分是树的完整上层；`truncated` 只在确实丢弃了待读节点时为真 |
| `acted` | — | `performAction(press)`、`typeText`、`pressKey`：动作已投递给平台且平台未报错。**不代表界面已经变化** |
| `located` | — | `performAction(verify)`：定位器与界面现状一致 |
| `stale` | `stale: StaleDetail` | `performAction`：定位器与界面现状不符，**没有执行任何动作** |
| `failure` | `error: WireError` | 任意请求 |

`frame` 是 `{x, y, width, height}`（均为浮点数）。

`AXNode` 是原生层如实返回的平台事实：`role`、`subrole?`、`title?`、`identifier?`、`value?`、
`roleDescription?`、`description?`、`enabled?`、`frame?`、`childCount?`、`children`。可选字段缺失时**省略**，不填空串。
原生层不判断元素"是不是同一个"，那是协议层的职责。

`childCount` 是平台报告的**真实**子节点数，只在读取过该节点的子节点时有值（深度上限处的节点没有）。
预算耗尽时 `children` 可能短于它；已读取的子节点是真实子列表的**前缀**，所以列表下标等于真实下标。

**动作定位相关类型**（均为扁平对象，可选字段省略）：

- `ElementLocator`：`path: [PathStep]`、`target: TargetKey`。空路径表示应用根节点本身
- `PathStep`：`index`（在父节点子列表中的下标）、`siblings`（读取时父节点的**真实**子节点数）、`role`
- `TargetKey`：`role`、`subrole?`、`title?`、`identifier?`、`description?`
- `StaleDetail`：`reason`（`childCount` 路径某层子节点数不同／`role` 路径某层角色不同或下标越界／`target` 到达目标但核对键不一致）、
  `step?`（不符发生在路径第几步，从 0 起）、`actualCount?`、`actual?: TargetKey`

原生层沿路径逐层读取子节点：子节点总数不等于 `siblings`、下标越界或角色不同，则返回 `stale`；
到达目标后核对 `TargetKey`，不等则返回 `stale`。`AXPress` 失败时返回 `failure`：
目标不支持该动作为 `unsupported_operation`，其他平台错误为 `action_failed`。

## 握手与版本

1. 连接建立后，协议层先发 `hello`。
2. 原生层在握手完成前**只接受 `hello`**；其他请求得到 `internal_error` 并关闭连接。
3. 版本必须**完全相等**。不等时原生层回 `protocol_version_mismatch`，
   消息中同时给出双方版本，然后关闭连接。不降级运行。
4. 版本号是编译期常量，来源见实现中的 `scuNativeProtocolVersion`。

当前版本 **3**。版本 1 → 2：`dumpTree` 增加 `budgetMs`，`tree` 应答增加 `truncated`，
`AXNode` 增加 `description`。版本 2 → 3：`AXNode` 增加 `childCount`；新增请求 `performAction`，
新增应答 `acted`、`located`、`stale`（[ADR-0015](../decisions/adr_0015_handle_resolution_by_path.md)）。

线格式本身的任何不兼容变更（字段改名、`type` 增删、语义变化）都要提升版本号。

## 连接生命周期

- 原生进程**只接受一条连接**，对端关闭即退出，不常驻。
  生命周期策略是否改为常驻，是[系统总览](../architecture/system_overview.md#尚未确定的部分)中的未定项。
- 协议层启动原生进程后，原生进程等待连接有上限（默认 10 秒）。超时则自行退出，
  避免协议层在连接前死亡时留下孤儿进程。协议层这一侧最多重试连接约 3 秒（60 次、间隔 50 毫秒），
  连不上就以连接超时失败，由会话层收成 `platform_unavailable`；两侧的等待时间并不对齐。
- 对端在半帧之后关闭：视为正常关闭，原生进程退出。
- 协议层等待应答有**超时**：读树的上限为 `budgetMs` + 10 秒（其中单次 AX 调用另有 2 秒的消息超时，在原生层内部），其他请求 30 秒。
  超时意味着原生进程无响应，连接无法再对齐帧边界，协议层关闭连接、终止子进程，
  以 `platform_unavailable` 失败。
- 协议层的关闭路径必须终止子进程并清理 socket 目录，**包括失败退出的路径**。
- 协议层启动原生进程时把它的 stdout 重定向到协议层的 stderr、stdin 断开：接入层（如 MCP stdio）独占 stdout 与 stdin，
  原生进程的输出不能混入协议流，也不能读走它。
- 原生进程退出时回收协议层为它创建的 socket 目录（名字以 `scu-` 开头的空目录），
  使协议层被 SIGKILL、自己的清理没有机会运行时目录也不残留。

## 错误

`failure.error` 是 [`ScuError`](error_taxonomy.md#error_structure) 的子集：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `code` | string | 错误码，取自错误码表 |
| `layer` | string | `policy` / `protocol` / `platform` / `boundary` |
| `retry` | string | 可重试性 |
| `message` | string | 人类可读，不用于分支 |

`ScuError` 定义的 `details` 与 `candidates` **当前未实现**：P0 的消息没有需要它们的错误。
补齐时需同步本文与实现。

原生层在本边界上产生的错误码：`system_permission_missing`、`target_missing`、
`protocol_version_mismatch`、`internal_error`，以及 `AXPress` 失败时的 `unsupported_operation`
（平台报动作不支持、属性不支持或未实现）与 `action_failed`（其余平台错误，含 `apiDisabled`）。`platform_unavailable` 由协议层在
**连接失败或对端消失**时本地生成，不经线路传输。

越界参数、无法解析的帧、握手前的请求目前都归入 `internal_error`。
是否为它们引入专门的错误码待定。

## 格式约束

- **未知消息类型**：解码失败，原生层应答 `internal_error` 并关闭连接。
- **缺少必需字段**：同上。
- **未知字段**：当前实现的 JSON 解码**会忽略**未知字段。
  [ADR-0012](../decisions/adr_0012_protocol_versioning.md) 要求"不做未知字段的静默忽略"，
  但两侧版本必须相等，因此未知字段只可能来自错配的实现而不是正常演进，
  实际风险有限。是否改为严格拒绝，待定。

## 当前实现范围

已实现并有测试：帧编解码、超长头、半帧、畸形 JSON、未知类型、缺字段、握手前请求、
版本错配、越界深度与预算、对端关闭后写入、无人连接超时、读取应答的等待可读超时、遍历预算耗尽、
`childCount` 的真实性（预算耗尽时记真实数量）、定位器每一类失效（子节点数、角色、核对键、下标越界、
子节点读不到）、畸形定位器被拒绝且连接保持、`performAction` 对真实访达的 `verify` 与篡改检测。

`typeText` / `pressKey` 由按键解析单元测试、会话层测试与夹具上的真实输入/提交测试覆盖（见 [ADR-0016](../decisions/adr_0016_input_and_keys.md)）。

`press` 对真实应用的投递由 `FixtureTests` 覆盖（真实 `scu-native`、真实夹具进程 `scu-fixture`、真实 `AXPress`；见 [夹具验证](../../verification/2026-10-18-fixture-validation.md)）。第三方应用（如 Electron）上未覆盖。

读取应答超时的**映射**（关闭连接、终止子进程、`platform_unavailable`）在 `NativeClient.call` 中实现；测试只覆盖到等待可读时抛出超时，没有覆盖后面的清理路径。

当前协议版本为 **4**（P0 时为 3）：本次新增 `typeText` 与 `pressKey`。
消息目录只覆盖到 v1 目前需要的七种请求。屏幕捕获、变更通知等随 P0 推进增加，
每增加一种都要在此登记并视情况提升版本号。
