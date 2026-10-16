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
  `id` 用于发现错位，而不是用于多路复用。
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
| `dumpTree` | `pid: int`、`maxDepth: int` | 读取某进程的无障碍树。`maxDepth` 范围 `0...64`，越界被拒绝而不是截断 |

### 应答

| `type` | 字段 | 对应请求 |
| --- | --- | --- |
| `hello` | `protocolVersion: int` | `hello` |
| `permissions` | `accessibility: bool` | `checkPermissions` |
| `apps` | `apps: [{pid, name, bundleId?}]` | `listApps` |
| `tree` | `tree: AXNode` | `dumpTree` |
| `failure` | `error: WireError` | 任意请求 |

`AXNode` 是原生层如实返回的平台事实：`role`、`subrole?`、`title?`、`identifier?`、`value?`、
`roleDescription?`、`enabled?`、`frame?`、`children`。可选字段缺失时**省略**，不填空串。
原生层不判断元素"是不是同一个"，那是协议层的职责。

## 握手与版本

1. 连接建立后，协议层先发 `hello`。
2. 原生层在握手完成前**只接受 `hello`**；其他请求得到 `internal_error` 并关闭连接。
3. 版本必须**完全相等**。不等时原生层回 `protocol_version_mismatch`，
   消息中同时给出双方版本，然后关闭连接。不降级运行。
4. 版本号是编译期常量，来源见实现中的 `scuNativeProtocolVersion`。

线格式本身的任何不兼容变更（字段改名、`type` 增删、语义变化）都要提升版本号。

## 连接生命周期

- 原生进程**只接受一条连接**，对端关闭即退出，不常驻。
  生命周期策略是否改为常驻，是[系统总览](../architecture/system_overview.md#尚未确定的部分)中的未定项。
- 协议层启动原生进程后，原生进程等待连接有上限（默认 10 秒）。超时则自行退出，
  避免协议层在连接前死亡时留下孤儿进程。
- 对端在半帧之后关闭：视为正常关闭，原生进程退出。
- 协议层的关闭路径必须终止子进程并清理 socket 目录，**包括失败退出的路径**。

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
`protocol_version_mismatch`、`internal_error`。`platform_unavailable` 由协议层在
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
版本错配、越界深度、对端关闭后写入、无人连接超时。

消息目录只覆盖 P0 需要的四种请求。动作注入、屏幕捕获、变更通知等随 P0 推进增加，
每增加一种都要在此登记并视情况提升版本号。
