# 本地环境

开发环境依赖、构建与首次运行步骤。阶段划分与技术栈的理由见
[ADR-0013](../decisions/adr_0013_p0_vertical_slice.md)。

## 环境

已验证可用的本机环境：

```
Swift       6.4（Apple Swift 6.4）
Xcode       27.1
macOS       arm64, macOS 26.x
```

仓库是一个 Swift package（`Package.swift`），不需要额外的包管理器或虚拟环境。

## 构建与测试

```bash
swift build          # 构建 scu 与 scu-native
swift test           # 线协议、原生否定路径与定位器、会话与策略、元素表与身份、MCP 管道，以及夹具上的真实点击验证（需要辅助功能权限）
scripts/check.sh     # 提交前统一检查：文档 + 构建 + 测试 + 命令行与 MCP 冒烟
scripts/measure_token_reject.py  # 令牌误拒与重读成本的测量（需辅助功能权限；会短暂出现一个夹具窗口）
                                    # 结果与口径见 ADR-0013 的 2026-10-19 追加记录；参数：--rounds N
```

启用 pre-commit，让每次提交自动运行统一检查：

```bash
git config core.hooksPath scripts/hooks
```

构建产物目录用 `swift build --show-bin-path` 查询。`scu` 默认在自己的同目录下
找 `scu-native`。

**`SCU_NATIVE` 环境变量仅用于开发**：它可以把原生进程指向任意可执行文件，
唯一的兜底是版本握手。设置时 `scu` 会在 stderr 打印提示。不要在生产环境设置。

平台下限 macOS 14.4，与 `Package.swift` 和 README 一致。
该数值在文档中没有记录依据，P0 实际只用到 AX 与 NSWorkspace，
是否可降低待屏幕捕获相关能力实现时确定。

## 当前已实现（v1）

以下行为已实现并由测试或手动运行覆盖。**v1 已完成（0.1.0，2026-10-19）；源码构建交付，暂不提供分发包。**
收敛有已知缺口（不列为门槛）；身份 K4 不成立（已按规则处置）；
除网易云（CEF，带无障碍启动参数）外的真实第三方应用与经宿主调用动作仍未验证。见[测试策略](testing.md#当前状态)。

| 内容 | 位置 | 状态 |
| --- | --- | --- |
| 两进程架构：`scu` 启动 `scu-native`，Unix socket 上通信 | `SCUWire`、`NativeClient`、`NativeServer` | 已实现，有测试 |
| 帧与消息格式（显式定义，见[原生层线协议](../interfaces/native_wire_protocol.md)） | `SCUWire` | 已实现，有测试 |
| 对端关闭后写入不杀进程（`SO_NOSIGPIPE`），传输失败映射为 `platform_unavailable` | `Transport.swift`、`NativeClient.call` | 已实现，有测试 |
| 连接时的版本协商，错配时明确失败并报双方版本 | `NativeServer.run`、`NativeClient.init` | 已实现，有测试 |
| 否定路径：握手前请求、超长帧、半帧、畸形 JSON、未知类型、越界深度、无人连接超时 | `NativeServer` | 已实现，有测试 |
| 命令行失败路径不泄漏临时目录与子进程 | `scu` 的 `main` | 已实现，由 `scripts/check.sh` 冒烟覆盖 |
| 权限检测（辅助功能） | `AXBackend.isAccessibilityTrusted` | 已实现 |
| 应用列表 | `AXBackend.listApps` | 已实现 |
| 无障碍树读取：广度优先遍历、每节点一次批量属性读取，单次 AX 调用超时 + 整棵树总时间预算（截断时明确标注，丢弃的是最深的节点）+ 客户端读取超时 | `AXBackend.dumpTree`、`NativeClient.call` | 已实现，有测试 |
| 树的文本输出与字段覆盖率统计 | `TreeFormatter`、`FieldCoverage` | 已实现，覆盖率有测试 |
| 文本化元素表（本次读取内的句柄、转义、层级优先的元素数上限、`focus` 展开） | `ElementTable` | 已实现，有测试 |
| 快照内短标签与 `frame`：可交互元素带 `[a]`，四个动作工具接受 `label`（[ADR-0018](../decisions/adr_0018_label_addressing.md)） | `ElementTable`、`DesktopSession`、`Tools` | 已实现，有单元与 MCP 测试；已在网易云 3.1.12（CEF）上按标签输入与设值 |
| MCP stdio 服务：只读的 `check_permissions`、`list_apps`、`get_ax_state`；加 `--actions` 额外提供 `click`、`type_text`、`press_key`、`set_value`（见 [MCP 接入面](../interfaces/mcp_surface.md)） | `SCUMCP`、`scu mcp`、`NativeSession` | 已实现，有单元测试与真实管道的端到端测试；只读工具已在 Cursor 一个宿主里跑通。**`click` 已在自制夹具应用 `scu-fixture` 上用真实 `AXPress` 验证过（`swift test --filter FixtureTests`，见 [夹具验证](../../verification/2026-10-18-fixture-validation.md)），尚未在 Electron 等真实第三方应用上验证**（见 [MCP 接入面的未验证项](../interfaces/mcp_surface.md#未验证项)） |
| 会话：快照令牌签发与复用、按路径加核对键定位句柄、`click`（`AXPress`）、轮询式收敛与效果摘要（[ADR-0015](../decisions/adr_0015_handle_resolution_by_path.md)） | `DesktopSession` | 已实现，有假读取器的单元测试、真实访达的 `verify` 测试与夹具上的真实点击测试 |
| 定位器：沿路径逐层核对子节点数与角色，再核对目标核对键，通过后 `press` / `verify` | `AXLocator`、`NativeServer` | 已实现，有测试（线协议 v4 的 `performAction`） |
| 输入与按键：先聚焦目标元素，再把 Unicode 键盘事件与组合键投递到目标进程（不激活应用）；设值走无障碍 `AXValue` | `Input.swift`、`DesktopSession` | 已实现，有按键解析单元测试、会话层测试与夹具上的真实输入/提交/设值测试 |
| 拒绝类目与宿主祖先链（只拒绝动作，读取不受限） | `PolicyGate` | 已实现，有测试；真实终端用例仅在终端运行时才执行 |
| 夹具应用（按钮、延迟变化、动画、被遮挡等场景），验证用，不是产品的一部分 | `scu-fixture`、`FixtureTests` | 已实现；见 [夹具验证](../../verification/2026-10-18-fixture-validation.md) |
| 进程被信号终止或 SIGKILL 时回收原生进程与 socket 目录 | `NativeClient.terminateAllForShutdown`、`scu-native` 退出清理 | 已实现，由 `scripts/check.sh` 冒烟覆盖 |
| K1~K4 候选键与匹配键计算（纯函数，无状态） | `IdentityAnalyzer` | 已实现，有测试（含唯一性的伪随机性质测试） |
| 各档位分布统计（整树 / 窗口内可交互 / 菜单栏 / 按 role），K1 与标签的多种口径 | `IdentityReport`、`scu identity` | 已实现。**只呈现分布，不给成败结论**（ADR-0013「基线先行」） |

**尚未实现**：坐标动作与坐标令牌、滚动与拖拽、应用启动、审批与租约、屏幕捕获、指示层；
句柄注册表（跨快照延续，K4 验证不成立，**不实现**，见 [ADR-0013](../decisions/adr_0013_p0_vertical_slice.md#暂缓句柄注册表)）。

**`verify`（只定位核对、不执行）在原生层与会话层已实现，没有向 MCP 暴露。**

命令行：

```bash
scu mcp [--actions]                 # MCP stdio 服务；默认只读，--actions 额外暴露 click / type_text / press_key / set_value；stdout 只有协议消息，诊断写 stderr
scu permissions                     # 检查辅助功能权限
scu apps                            # 列出可绑定的应用与 pid
scu dump --pid <pid> [--depth N] [--budget-ms M]
                                    # 输出无障碍树，并在 stderr 给出字段覆盖率
                                    # N 范围 0...64，默认 12；M 范围 100...120000，默认 15000；预算耗尽时明确提示已截断
scu dump --pid <pid> --json         # 输出 JSON，供后续比对
scu identity --pid <pid> [--depth N] [--budget-ms M] [--by-role] [--show-k4]
                                    # 匹配键档位分布（基线，不给成败结论）；默认深度 24
                                    # --by-role 按 role 拆分，--show-k4 列出落入 K4 的窗口内可交互元素
```

`dump` 输出的是原始树，**不是**最终的元素表格式（见[元素寻址](../interfaces/element_addressing.md)），没有句柄；
句柄在 MCP `get_ax_state` 的元素表里。

### 接入 MCP 宿主

`scu mcp` 由宿主按 MCP stdio 方式启动。以 Cursor 的 `mcp.json` 为例（路径换成本机的构建产物目录，
用 `swift build --show-bin-path` 查询；`scu` 会在同目录找 `scu-native`）：

```json
{
  "mcpServers": {
    "scu": { "command": "/绝对路径/.build/out/Products/Debug/scu", "args": ["mcp"] }
  }
}
```

要让 AI 能点击，把 `args` 改成 `["mcp", "--actions"]` 并重载（`click` 会真实作用于应用；第三方应用上的点击尚未验证，见 [MCP 接入面的未验证项](../interfaces/mcp_surface.md#unverified)）。

**辅助功能权限归属于启动 `scu mcp` 的宿主**，不是整台机器。接入后第一件事是让模型调用
`check_permissions`；未授权时按[macOS 权限](permissions.md)给宿主授权。
接入后让 agent 读 [skills/scu/INSTALL.md](../../skills/scu/INSTALL.md)（安装与自检）与
[skills/scu/SKILL.md](../../skills/scu/SKILL.md)（核心循环、动作选择、效果摘要与错误处理）。
该流程只在 Cursor 里验证过一次，见 [MCP 接入面的未验证项](../interfaces/mcp_surface.md#未验证项)。

用管道手动驱动（不需要宿主）：

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$(swift build --show-bin-path)/scu" mcp
```

### 已知缺口（P0 内待处理）

- **CEF/Chromium 应用可能完全不暴露 AX。** 网易云音乐 `3.1.12` 正常启动时窗口零子元素；
  以 `--force-renderer-accessibility` 重启后才出现 `AXWebArea`。这是需用户同意的应用级适配，
  见 [ADR-0017](../decisions/adr_0017_cef_accessibility_launch.md)。
- **Electron 应用的树大小随读取时机变化。** 同一个 Cursor 进程，较早一次读取 251 个元素，
  随后读取 706 个且含 `AXWebArea`。原因未查明（Chromium 可能在检测到辅助技术后才逐步暴露网页树，
  也可能只是窗口状态不同）。正式验证前需要确定预热方式。若最终需要主动设置
  `AXManualAccessibility` / `AXEnhancedUserInterface`，那会改变目标应用的状态，属有副作用的操作，需先设计。
- **`description` 是否纳入 K2 待定。** 后端已读取 `AXDescription`，分布统计并列两种口径；
  基线显示它对 K4 比例的改善有限（见 [基线记录](../../verification/2026-10-16-baseline-identity.md)）；2026-10-18 的正式验证里，计入后访达 54.2%→12.5%、活动监视器 48.4%→25.8%、Cursor 57.9%→39.5%（[K4 验证](../../verification/2026-10-18-identity-k4.md)），是否采用待定。
- **客户端被终止时，原生进程若正在读树，会继续工作到时间预算耗尽**（最长 `budgetMs`），之后退出并回收 socket 目录。`scu mcp` 收到 SIGTERM / SIGINT / SIGHUP 时会立即终止原生进程；SIGKILL 则只能靠原生进程自行发现连接断开。

## 首次运行的顺序

1. **授予权限。** 按 [macOS 权限](permissions.md)给宿主可执行文件授予辅助功能权限。
   跳过这一步后面全部无法进行。
2. **`swift build`，然后 `scu permissions`** 确认原生进程能看到权限。
3. **导出第一份无障碍树样本**，选一个原生应用（建议访达或系统设置），人工确认结构合理。
4. **导出一个 Electron 应用**，对比两种技术栈暴露的字段差异。
5. 运行 `swift test`（含夹具验证，需要辅助功能权限），门槛与当前结果见
   [ADR-0013](../decisions/adr_0013_p0_vertical_slice.md#出口门槛)与[测试策略](testing.md#当前状态)。

第 3、4 步的产出是身份键设计的依据；K4 正式验证已执行（不成立），
见 [verification/2026-10-18-identity-k4.md](../../verification/2026-10-18-identity-k4.md)。

## 仍待定

- **服务进程与 JS 运行时的关系**：协议层是 Swift，code mode 运行时用哪种引擎待定，
  见[运行时契约](../interfaces/runtime_contract.md)。
- **分发方式**：签名与公证的要求取决于是否对外发布二进制。
