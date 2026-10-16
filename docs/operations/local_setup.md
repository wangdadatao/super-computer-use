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
swift test           # 线协议、服务端否定路径、握手集成测试
scripts/check.sh     # 提交前统一检查：文档 + 构建 + 测试 + 命令行冒烟
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

## 当前已实现（P0 脚手架）

以下行为已实现并由测试或手动运行覆盖。**这不等于 P0 完成**，
元素身份、令牌、点击与效果摘要尚未开始。

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
| 无障碍树读取：单次 AX 调用超时 + 整棵树总时间预算（截断时明确标注）+ 客户端读取超时 | `AXBackend.dumpTree`、`NativeClient.call` | 已实现，有测试 |
| 树的文本输出与字段覆盖率统计 | `TreeFormatter`、`FieldCoverage` | 已实现，覆盖率有测试 |
| K1~K4 候选键与匹配键计算（纯函数，无状态） | `IdentityAnalyzer` | 已实现，有测试（含唯一性的伪随机性质测试） |
| 各档位分布统计（整树 / 窗口内可交互 / 菜单栏 / 按 role），K1 与标签的多种口径 | `IdentityReport`、`scu identity` | 已实现。**只呈现分布，不给成败结论**（ADR-0013「基线先行」） |

**尚未实现**：句柄注册表（跨快照延续，**暂缓**，见 [ADR-0013](../decisions/adr_0013_p0_vertical_slice.md#暂缓句柄注册表)）、
快照令牌、动作注入、效果摘要。

命令行：

```bash
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

`dump` 输出的是原始树，**不是**最终的元素表格式（见[元素寻址](../interfaces/element_addressing.md)）。
此时还没有句柄。

### 已知缺口（P0 内待处理）

- **Electron 应用的树大小随读取时机变化。** 同一个 Cursor 进程，较早一次读取 251 个元素，
  随后读取 706 个且含 `AXWebArea`。原因未查明（Chromium 可能在检测到辅助技术后才逐步暴露网页树，
  也可能只是窗口状态不同）。正式验证前需要确定预热方式。若最终需要主动设置
  `AXManualAccessibility` / `AXEnhancedUserInterface`，那会改变目标应用的状态，属有副作用的操作，需先设计。
- **`description` 是否纳入 K2 待定。** 后端已读取 `AXDescription`，分布统计并列两种口径；
  基线显示它对 K4 比例的改善有限，见 [基线记录](../../verification/2026-10-16-baseline-identity.md)。
- **客户端被 SIGTERM 终止时，原生进程会继续工作到时间预算耗尽**（最长 `budgetMs`），之后退出。

## 首次运行的顺序

1. **授予权限。** 按 [macOS 权限](permissions.md)给宿主可执行文件授予辅助功能权限。
   跳过这一步后面全部无法进行。
2. **`swift build`，然后 `scu permissions`** 确认原生进程能看到权限。
3. **导出第一份无障碍树样本**，选一个原生应用（建议访达或系统设置），人工确认结构合理。
4. **导出一个 Electron 应用**，对比两种技术栈暴露的字段差异。
5. 进入 P0 的元素身份工作，门槛见 [ADR-0013](../decisions/adr_0013_p0_vertical_slice.md#出口门槛)
   与[测试策略](testing.md)。

第 3、4 步的产出是身份键设计的依据。在拿到真实样本前，
[元素身份](../architecture/element_identity.md)的字段选择属于假设。

## 仍待定

- **服务进程与 JS 运行时的关系**：协议层是 Swift，code mode 运行时用哪种引擎待定，
  见[运行时契约](../interfaces/runtime_contract.md)。
- **分发方式**：签名与公证的要求取决于是否对外发布二进制。
