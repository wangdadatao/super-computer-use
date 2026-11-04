# ADR-0032 跨机操作面：v1 走 SSH stdio，不开放 HTTP 动作端点

- **状态**：已接受（2026-11-04；外部规范核对完成，结论见「规范核对结论」）。v1 **尚未部署**：没有客户端接入，key 与 wrapper 都没落，见「落地时点」
- **日期**：2026-11-04

<a id="remote_surface"></a>

## 背景

**目标**：控制端（笔记本，跑 MCP 宿主与模型）操作被控端（macmini，有界面、有辅助功能与屏幕录制授权）。
下文的「两机」都指这一对，不引入第三台机器。

### 今天的连接模型

- 传输是 stdio，一行一条 JSON-RPC（[MCP 接入面](../interfaces/mcp_surface.md)，传输一节）。
- 一个 `scu mcp` 进程 = 一条连接 = 一个授权作用域（`Sources/SCUCore/AppAuthorization.swift:5-7`）。
- 动作档是进程级开关：`scu mcp --actions` 才暴露 8 个动作工具；默认只读（`Sources/scu/main.swift:6-9`、
  `Sources/SCUMCP/MCPServer.swift:131`）。
- 快照令牌由进程内的随机 nonce 加计数器生成（`Sources/SCUCore/DesktopSession.swift:217`、
  `Sources/SCUCore/DesktopSession+Read.swift:70`），只在进程内有效。
- 策略层按目标应用判定，拒绝类目不可覆盖；SCU 自身与启动它的祖先进程也被拒绝
  （`Sources/SCUCore/PolicyGate.swift`）。
- **协议层没有对端身份**：`MCPServer.handle` 只按方法名分发；`tools/call` 直接执行，不要求先
  `initialize`（`Sources/SCUMCP/MCPServer.swift:37-74、127-134`）。
  今天的信任边界是「谁能写这个进程的 stdin」。

### 实测事实（2026-11-04）

- 本机直接向 `scu mcp` 写一行 `tools/call`（不发 `initialize`）能读到应用列表；加 `--actions` 后
  `tools/list` 返回 13 个工具，其中 8 个是动作工具。
- macmini 上 `scu permissions` 返回「辅助功能：已授予」；通过 SSH 执行 `screencapture` 退出码 0，
  输出 1920×1080。两项系统授权挂在 `/usr/libexec/sshd-keygen-wrapper` 上，因此**任意 SSH 会话**都带着
  这两项能力（`docs/operations/local_setup.md:22、67`、[macOS 权限](../operations/permissions.md)「SSH 启动的进程」）。
- SSH stdio 可用：`initialize` 正常返回，远程 stderr 0 字节，stdin 关闭后远程没有
  `scu mcp` / `scu-native` 残留。
- macmini 的应用防火墙关闭（`socketfilterfw --getglobalstate` → `State = 0`）。

这些事实决定了下面的选择：**问题不是「怎么把 JSON 搬到 TCP 上」，而是「谁有资格写这个 stdin」**。

## 决策

### 1. v1 只做（a）：客户端用 ssh 启动远端 `scu mcp`

控制端的 MCP 宿主直接 spawn：

```text
command = /usr/bin/ssh
args    = -T -o BatchMode=yes -o StrictHostKeyChecking=yes
          -o ControlMaster=no -o ControlPath=none -o ClearAllForwardings=yes
          -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
          -i /Users/dager/.ssh/scu_remote_ed25519
          dagermac-mini /Users/dager/aiwork/bin/scu-mcp-actions
```

- 不新增监听端口，不新增令牌，不改线协议（仍是 v12）。
- 身份、加密、主机认证全部由 SSH 承担；SCU 只做它今天已经在做的事。
- 连接作用域仍是「一个进程一条连接」：每个客户端一条 SSH，各自一个 `DesktopSession`，令牌天然不共享。
- 断开 = 进程退出 = 能力消失；没有跨连接的租约。

### 2. v1 的最小安全切片

不是「配一条 ssh 就行」，要落四件东西：

1. **两把独立的 ed25519 key**，不复用现有的 git push key：
   - `scu_remote_ro` → 只读档（5 个工具）；
   - `scu_remote_actions` → 动作档（13 个工具）。

   私钥在控制端 `0600`，只放在需要它的机器上；撤销 = 删除被控端对应 `authorized_keys` 行并杀掉会话。

2. **`authorized_keys` 用 forced command 钉死**，不允许拿这把 key 开 shell、转发端口或跑别的命令：

```text
restrict,from="192.168.20.169",command="/Users/dager/aiwork/bin/scu-mcp-ro" ssh-ed25519 AAAA... scu-remote-ro
restrict,from="192.168.20.169",command="/Users/dager/aiwork/bin/scu-mcp-actions" ssh-ed25519 AAAA... scu-remote-actions
```

`from=` 写控制端的实际地址（本次实测是 `192.168.20.169`；DHCP 变了要同步改）。`restrict` 关掉 pty、
端口转发、agent 转发与 X11。

3. **两个 wrapper**，只做一件事，绝对路径，`0755`，属主 `dager`，group/other 不可写：

```sh
#!/bin/sh
# ~/aiwork/bin/scu-mcp-actions
exec /Users/dager/aiwork/SuperComputerUse/.build/release/scu mcp --actions
```

只读版去掉 `--actions`。不要指向 `.build/debug`：被控端的工作树可能停在别的分支，二进制路径应固定到
release；启动后客户端校验 `initialize` 的 `serverInfo.version` 必须是约定版本（当前 0.5.0），不符就断开。
wrapper 不读取 `$SSH_ORIGINAL_COMMAND`，也不把客户端参数拼进命令行；`authorized_keys` 保持 `0600`。

4. **客户端固定 SSH 选项**（上面的 args）：禁用连接复用，避免同机其他进程复用这条已认证的连接发帧；
   禁用本地命令与转发；开启 keepalive，避免被控端睡眠后无限挂起。

**分两天发**：第一天只发只读 key，确认读取、截图、令牌都正常；动作 key 在只读验收通过后再发。
两把 key 独立撤销，出问题先撤动作 key。

### 4. 落地时点：现在不建 key，等有真实调用方再落

**决定：暂不落两把 key 和两个 wrapper。** 不是「以后再说」，是现在落没有可验收的对象：

- 被控端 `~/aiwork/bin` 不存在（2026-11-04 核对），`.build/release/scu` 会被下一次构建覆盖。wrapper
  指向它时，没有客户端就只能验证「手工能跑通」，验证不了真正要用的那条路径：宿主 spawn ssh、
  版本校验、断线回收，都要有客户端才能测。
- 一把进 `authorized_keys` 的 key 就是一份长期有效的 GUI 控制凭据（见「取舍」第一条）。没有调用方时
  它只有风险没有收益：控制端上任何能读私钥的进程都能用它。
- `from=` 写的是 DHCP 地址，网络一变就是「连不上」。这算安全失败，但会留下一份看起来配好、实际不通的
  部署，下一次排查要从零开始。

**触发条件**（满足任一条再落）：出现需要从 A 用 MCP 宿主操作 B 的日常任务；或要把 B 固定成 CI、演示的
被控端。

**落地顺序**（缺一条不落）：

1. wrapper 进仓库（`scripts/remote/`），随 `scu-mini sync` 部署，不再手工往 `~/aiwork/bin` 放裸脚本；
   wrapper 指向固定路径的 release 二进制，启动即用 `--version` 自检。
2. 先用一次性临时 key 打通端到端：宿主 spawn ssh → `initialize` → `tools/list` = 5 → 断线后 `pgrep`
   为空；验完删掉临时 key。
3. 再发只读 key，按「验证门禁」跑一遍并留输出；只读验收通过后才发动作 key。
4. 撤销路径写进 `docs/operations/`；动作 key 出事优先撤。

**既存事实**：macmini 上现在唯一的 SSH key `codex-macbook-to-macmini` 没有 `restrict` / `from=` /
`command=`（2026-11-04 核对）。它需要 shell，不能用 forced command；落 v1 时应当同时评估给它加
`from=`。本次不改 `authorized_keys`。

### 3. 被否方案与否决理由

#### （b）MCP Streamable HTTP + 令牌鉴权：现在不做

不是「HTTP 不好」，是它会把今天的进程边界换成一个**新的、需要自己实现的身份与租约系统**，
而 SCU 现在一行都没有：

- 需要新增：HTTP 监听、令牌签发/存储/轮换/撤销、会话 ID、每会话一个 `DesktopSession`
  （否则令牌跨客户端通用）、Origin/Host 校验、TLS、审计、限流、错误码。
- 令牌不是加个 header 就完了：今天 `s<nonce>.<counter>` 是进程内 bearer 值，没有客户端绑定
  （`DesktopSession+Read.swift:70`）。如果 HTTP 服务共用一个进程，A 客户端拿到的令牌 B 客户端可以直接用；
  要修就得把 `DesktopSession` 变成每会话一份，这会改动「一个进程一条连接」的核心不变量（ADR-0024）。
- 浏览器面：`MCPServer.handle` 不要求 `initialize`，一个 POST 就能执行 `tools/call`。
  没有 Origin/Host 校验时，网页可以向本机或局域网地址发 simple request；没有 CORS 时读不到响应，
  但 `launch_app` 这类不需要令牌的动作可以盲打；一旦 CORS 配成 `*` 或 DNS rebinding 成功，
  就能读令牌、点鼠标、输入。
- 失败语义、审计、限流都没有现成测试；现在做等于把 0.5.0 的收口拖进一个没有验收标准的新面。

**重新考虑的条件**（满足任一条再立项）：需要多个客户端共享一台被控端；宿主不能 spawn ssh
（例如纯网页客户端）；需要按调用审计或按用户计费；需要跨公网。立项时必须先过本文「验证门禁」里的
HTTP 清单。

#### 规范核对结论（2026-11-04）

依据：探路的《SCU 跨机桌面要不要上 MCP HTTP》
（`/Users/dager/aiwork/team/research/2026-11-04-scu-remote-transport.md`，团队目录，不在本仓库；
只看官方文档，未实测延迟）。以下四条直接改变本文的判断：

- **局域网裸奔不违反 MCP 规范，但也不构成合规。** 传输页里只有 `Origin` 校验是 MUST，「给所有连接
  做鉴权」是 SHOULD，授权整体是 OPTIONAL。所以「先开端口、以后再补令牌」不会被规范拦下，能拦住它的
  只有本仓库自己的门禁。
- **一旦宣称做了授权，就必须是整套 OAuth 2.1**：401 挑战、PKCE（REQUIRED）、RFC 8414 元数据发现、
  令牌只走 `Authorization: Bearer`（禁止放进 URL query）、授权端点必须 HTTPS。静态共享 bearer 不能
  对外称为「符合 MCP 授权」。2025-06-18 起，`initialize` 之后的每个 HTTP 请求还必须带
  `MCP-Protocol-Version` 头，不认识的版本必须回 400。
- **2026-07-28 的草案传输页删掉了 GET 长连接和协议级 session（含 `Mcp-Session-Id`）。** 将来做（b）
  不能把这两样当必备能力设计；2025-03-26 / 2025-06-18 / 2025-11-25 仍是旧形状。
- **没有官方规范支持「computer-use MCP over HTTP 操作另一台 Mac」。** 同类产品要么同机 stdio
  （Claude Code computer-use、Playwright MCP 默认），要么明确要求服务只绑 localhost 再用 `ssh -L`
  （Playwright 的远程文档）；Claude Desktop 的 SSH 远程会话也是「在远端机器上跑 stdio」。这三条都把
  （a）当默认，把 HTTP 当例外。

#### （c）本机桥接/隧道：不作为 v1

- `ssh -L 18765:127.0.0.1:18765` 到本机一个 HTTP 端点，看起来「只开 loopback」，但**控制端上的每个
  本地进程、每个网页都能访问 `127.0.0.1:18765`**；没有（b）的 Origin/令牌，这就是把（b）的攻击面搬到
  本机，还多了一层隧道。
- 自写 stdio↔WebSocket 桥要多一套协议、心跳、重连与帧边界处理，收益只是「不用让宿主 spawn ssh」，
  而主流 MCP 宿主本来就能 spawn 命令（本项目只在 Cursor 上实测过，
  [MCP 接入面](../interfaces/mcp_surface.md)「已知限制」）。
- 只有在（b）已经存在、且需要给不能 spawn ssh 的宿主兜底时，才允许作为**传输适配器**：
  只连 loopback、带令牌、带 Origin 校验。它不是 v1。

### 4. 三条路对比

| 维度 | （a）SSH stdio | （b）Streamable HTTP + 令牌 | （c）本机桥接/隧道 |
|---|---|---|---|
| 新增身份 | SSH 用户 + key + 主机 key | bearer 令牌 + 会话 ID | 继承 SSH，或再发一套令牌 |
| 授权 | `authorized_keys`（`restrict`/`from`/`command`）+ `--allow-app` + `--actions` | 令牌作用域 + 允许列表 + 策略层 | 取决于后端 |
| 租约 | 进程生命周期，断开即失效 | 会话 TTL/空闲超时，需要撤销 | 隧道生命周期 |
| 审计 | sshd 登录日志；**无工具级审计** | 可做每次调用的审计（需实现） | sshd 或后端日志 |
| 失败语义 | SSH 退出/EOF；动作可能已投递 | 401/403/404/429/流断开；需定义 | 隧道断开、端口半开 |
| 新增产品代码 | 0（只加部署脚本） | HTTP 服务 + 会话 + 令牌 + 测试 | 桥接程序 |
| 新增监听端口 | 0 | 1（默认应只 bind loopback） | 1（本机） |
| 被滥用的后果 | 偷到 key = 整台机器的 GUI 控制 | 偷到令牌 = 同上；另有 CSRF/rebinding | 本机任意进程/网页 = 同上 |

## 现在就把动作档 HTTP 端点开到局域网：攻击面（实测）

**结论：等于把被控端的 GUI 控制权无条件发给整个局域网。** 不是「多一个端口」，是「多一个不需要密码的
远程桌面」。

### 复现装置

为了回答「具体会发生什么」，我在 macmini 上跑了一个 **约 40 行的临时 Python 桥**
（`/tmp/scu-http-poc.py`，不属于产品代码，已删除）：绑定 `0.0.0.0:18765`，把每个 POST body 原样写进
`scu mcp --actions` 的 stdin，回一行 stdout；不校验令牌、不校验 Origin、不校验 Host、不看 Content-Type。
控制端从 `192.168.20.169` 访问 `192.168.10.104:18765`（跨网段，防火墙关闭）。第一轮跑完 7 个请求后销毁；
为取令牌又启动了一次，只发 1 个 `get_ax_state`，随后再次销毁。端口与进程均已确认清空。

### P1 局域网任意主机，零凭据

```bash
curl -sS -X POST http://192.168.10.104:18765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

返回 13 个工具：`check_permissions`、`list_apps`、`list_windows`、`get_ax_state`、`get_screenshot`、
`launch_app`、`click`、`click_at`、`scroll_at`、`drag`、`type_text`、`press_key`、`set_value`。
没有 401，没有握手。

### P2 动作工具真的执行

```bash
curl -sS -X POST http://192.168.10.104:18765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"launch_app","arguments":{"app":"Calculator"}}}'
```

返回「应用已在运行或已启动：计算器（pid 46371）」。SSH 侧 `pgrep -x Calculator` 确认进程存在。
动作档的 8 个工具走同一个 `callTool` 分支，没有额外的对端检查
（`Sources/SCUMCP/MCPServer.swift:127-134`）。

### P3 令牌也能读到，下一步就是点击/输入

```bash
curl -sS -X POST http://192.168.10.104:18765/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_ax_state","arguments":{"pid":1116}}}'
```

返回 `# pid=1116 令牌 s214m7u.1 元素 349`。拿到令牌后，`click` / `type_text` / `press_key` / `set_value`
的参数就齐了。**我没有执行点击**，避免在共享桌面上移动真实鼠标；但从令牌到动作之间没有第二道门，
代码路径与已执行的 `launch_app` 相同。

### P4 浏览器页面：不需要 CORS，也不需要先握手

一个恶意页面可以发 `no-cors` 的 simple request：

```js
fetch('http://192.168.10.104:18765/mcp', {
  method: 'POST',
  mode: 'no-cors',
  headers: {'Content-Type': 'text/plain'},
  body: '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"launch_app","arguments":{"app":"Calculator"}}}'
});
```

实测服务端接受了这组请求并执行：

```text
REQ 5 from 192.168.20.169 host=evil.example:18765 origin=http://evil.example ct=text/plain
```

因为没配 CORS，页面读不到响应，这类请求只能「盲打」不需要令牌的动作（`launch_app`）。但服务端
**不校验 Host**，所以 DNS rebinding 的服务端前置条件已经满足：攻击者域名解析到 `192.168.10.104` 后，
页面变成同源，响应可读，`get_ax_state` 的令牌就能拿到，后面就是 P3。DNS rebinding 本身我没有实跑；
浏览器侧的 Private Network Access 与 DNS pinning 也会影响可行性，这两点**未验证**。这里能确定的是：
服务端没有任何 Host/Origin 防线，不能把浏览器侧的策略当成服务端的安全边界。

### P5 没有审计

`~/Library/Logs` 下没有 SCU 日志；SCU 进程不记录工具名、目标、调用方。事后只能看到 sshd 的登录记录
（如果走 SSH），看不到「谁点了什么」。HTTP 端点更糟：连登录记录都没有。

### P6 令牌跨客户端通用（如果共用进程）

`DesktopSession.swift:217` 的 nonce 是进程级随机数，`DesktopSession+Read.swift:70` 的令牌是
`s<nonce>.<counter>`，没有绑定连接。stdio 模式下这不是问题（一个进程只有一个客户端）；如果 HTTP 服务
为了省资源共用一个 `scu mcp` 进程，A 客户端拿到的令牌 B 客户端可以直接用。要做（b），必须每会话一个
`DesktopSession`，或者给令牌加连接绑定。

### P7 系统授权被放大

macmini 的两项授权挂在 `sshd-keygen-wrapper` 上；`scu permissions` 返回已授予，SSH 下 `screencapture`
输出 1920×1080。也就是说，局域网调用者不需要在被控端上点任何「允许」，就能用这份授权读屏、点鼠标、输入。
**这是这套安排最危险的一点：SCU 的策略层只限制「对哪个应用做动作」，不限制「谁在调用」。**

### P8 可用性

`MCPServer` 的主循环是同步的（[MCP 接入面](../interfaces/mcp_surface.md)「已知限制」）：一个慢
`get_ax_state` 会阻塞同一进程里的所有请求；没有限流、没有并发上限。局域网里任何一台机器都能把连接占住。

### P9 明文与中间人

朴素 HTTP 没有 TLS。令牌、截图、输入文本在局域网里是明文；同网段（开放 Wi-Fi、ARP 欺骗等）可以嗅探，
也可以注入一条 `tools/call`。这一条是代码层判断，没有在真实网络上做抓包。

## 验证门禁

### 本次文档变更

- 本机提交钩子固定 `SCU_SKIP_LIVE=1`（`scripts/hooks/pre-commit:8`），`AGENTS.md:34-35` 记为
  23 个 live 用例 skipped、134 个实际执行，摘要仍打印 157。**本机的 157 不是全量基线。**
  `docs/operations/local_setup.md` 已统一为 23 个 live 用例（本机 pre-commit 实跑 134、macmini 全量
  157、CI 135），与本文口径一致；本文仍不把本机数字当基线。
- 全量基线在被控端：`~/aiwork/bin/scu-mini check`，5/5，157 个全执行；报告必须带机器与工具链
  （2026-11-04 实测：macmini，Swift 6.4.0，26/40/64/157，测试段 64.4 秒，失败 0）。
- 文档改动也要过 `check_docs.sh`：ADR 字段、链接、锚点、分类路由。

### v1（SSH stdio）的两机验收

**接受这条 ADR 不等于部署完成。** 以下命令在真正落 key 时执行；现在跑会在第 2 步失败（wrapper 还不存在）。
在控制端执行，全部要留输出：

```bash
# 1. 版本与权限（被控端）
ssh dagermac-mini '~/aiwork/SuperComputerUse/.build/release/scu --version'    # 0.5.0
ssh dagermac-mini '~/aiwork/SuperComputerUse/.build/release/scu permissions'  # 辅助功能：已授予

# 2. 只读档：5 个工具
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | ssh -T dagermac-mini '~/aiwork/bin/scu-mcp-ro' | jq '.result.tools|length'   # 5

# 3. 动作档：13 个工具
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | ssh -T dagermac-mini '~/aiwork/bin/scu-mcp-actions' | jq '.result.tools|length'  # 13

# 4. 断开即回收
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  | ssh -T dagermac-mini '~/aiwork/bin/scu-mcp-actions' >/dev/null
ssh dagermac-mini 'pgrep -fl "scu mcp|scu-native" || echo clean'   # clean

# 5. 允许列表仍然生效
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"launch_app","arguments":{"app":"Calculator"}}}' \
  | ssh -T dagermac-mini '~/aiwork/SuperComputerUse/.build/release/scu mcp --actions --allow-app com.apple.finder'
# 期望：[app_not_authorized]

# 6. 没有监听端口
ssh dagermac-mini 'lsof -nP -iTCP -sTCP:LISTEN | grep -i scu || echo "no listener"'  # no listener
```

预期全部通过；任一条不符，v1 不算完成。**未验证**：动作执行到一半时 SSH 断开的后果
（远程进程会被回收，但动作可能已经投递；调用方必须重连后先 `get_ax_state` 核对，不能盲目重放）。

### 未来（b）的准入门禁

没有全部通过，不合并 HTTP 传输：

0. 若对外宣称「符合 MCP 授权」：401 挑战、PKCE、RFC 8414 元数据发现齐全；只用静态 bearer 时不得这样宣称。
1. 无令牌 → 401；错误令牌 → 401；正确令牌 → 200。
2. `Origin: http://evil.example` → 403；`Host: evil.example` → 403/421。
3. `Content-Type: text/plain` 的 JSON-RPC → 415（或明确拒绝），不能执行。
4. 未 `initialize` 直接 `tools/call` → 400/428，不能执行。
5. 两个会话 A/B：A 的令牌在 B 中使用 → 403/409（每会话 `DesktopSession`）。
6. 令牌轮换后旧令牌在 N 秒内失效；撤销立即生效。
7. 每次工具调用有审计：时间、对端 IP、会话 ID、工具名、目标、结果；不记录截图与输入内容。
8. 并发上限与超时；慢调用不阻塞其他会话（或明确 429）。
9. 局域网模式必须 TLS；默认只 bind `127.0.0.1`，`0.0.0.0` 需要显式开关并在启动时警告。
10. SIGTERM 关闭监听、终止 sidecar、无残留端口与进程。

## 取舍

- **接受 SSH key 等价于 GUI 控制权。** v1 不做逐次审批；策略层仍拒绝终端、脚本运行器、密码管理器、
  系统设置等类目，但挡不住「用 Safari 打开一个 web terminal」这类绕行。这是现有策略的边界，
  不是本 ADR 新增的。
- **接受没有工具级审计。** v1 只有 sshd 的登录记录；要知道「谁点了什么」必须上（b）或另加日志。
  对单人、两台机器的场景，这个缺口可以接受；对多人共享的被控端，不可以。
- **接受依赖宿主能 spawn ssh。** 本项目只在 Cursor 上实测过（[MCP 接入面](../interfaces/mcp_surface.md)
  「已知限制」）；其他宿主要各自验证。
- **接受首行被 shell rc 污染的风险。** SSH 的 stdout 必须是纯 JSON；如果被控端的 `.zshenv` 打印东西，
  客户端会收到非 JSON 首行。验收时显式检查首行；发现污染就修 rc 或换专用账户。
- **不做 HTTP，不表示永远不做。** 需求变成多客户端、纯网页或跨公网时，按上面的门禁重新立项；
  不要先开端口再补鉴权。

## 后果

- 新增一份部署契约（两把 key、两个 wrapper、一组 SSH 选项），不改产品代码、不改线协议 v12。
- 控制端的 MCP 配置多一个 `ssh` 服务器项；被控端多两个 forced-command key。
- 撤权路径明确：删 `authorized_keys` 行 + 杀会话；不需要改代码或重启服务。
- 已知限制：无工具级审计；无逐次审批；SSH 断线可能发生在动作已投递之后；宿主兼容性只验证了 Cursor；
  被控端睡眠会导致连接挂起（keepalive 只负责尽快失败，不负责唤醒）。
- 未来若做（b），必须先补「每会话一个 `DesktopSession`」与审计，否则会把今天的进程边界问题带进网络层。

## 相关文档

- [ADR-0009 策略层独立成层](adr_0009_policy_layer.md)：动作准入的三态结论与拒绝类目。
- [ADR-0010 范围限定为 UI 自动化](adr_0010_ui_automation_only.md)：能力边界。
- [ADR-0012 协议版本在会话建立时协商](adr_0012_protocol_versioning.md)：版本握手与失败关闭。
- [ADR-0024 连接级应用允许列表](adr_0024_app_authorization.md)：一个进程一条连接、一个授权作用域。
- [ADR-0031 窗口身份](adr_0031_window_identity.md)：远程操作仍以 `Target` 与令牌为单位。
- [MCP 接入面](../interfaces/mcp_surface.md)：stdio 传输、同步主循环、宿主验证状态。
- [本地环境](../operations/local_setup.md)：两台机器分工、SSH 授权归属。
- [macOS 权限](../operations/permissions.md)：权限按宿主归属；SSH 启动的进程与被控端授权范围。
- 跨机传输的规范调研（团队目录，不在本仓库）：`/Users/dager/aiwork/team/research/2026-11-04-scu-remote-transport.md`。
