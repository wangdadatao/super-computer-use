# ADR-0022 应用启动走 LaunchServices

- **状态**：已接受（实验性）
- **日期**：2026-10-20

## 背景

SCU 之前只能操作已在运行的应用：`list_apps` 依赖运行列表，`get_ax_state` 需要 pid。
用户说“打开 XX 并操作”时，agent 只能让用户自己打开，任务被中断。

应用启动是低风险的桌面动作（不像点击/拖拽会改内容），适合先补。它也让后续的
“启动 → 等窗口 → 操作”流程可以一次完成。

## 决策

### 1. MCP 动作工具 `launch_app(app)`

`app` 支持：

- bundle id：`com.apple.Safari`
- 显示名：`Safari`
- `.app` 路径：`/Applications/NeteaseMusic.app`

启动或激活已运行的应用，返回 `name / pid / bundle id`；之后用 `list_apps` 或
`get_ax_state` 继续。工具只在 `--actions` 下暴露。

### 2. 先解析、再做策略检查、最后启动

顺序不能反：

1. `AppLauncher.resolve` 解析出 URL / 名称 / bundle id；
2. 用 `PolicyGate.evaluate(bundleId:)` 检查拒绝类目；
3. 通过后才调用 `launch`。

终端、脚本运行器、密码管理器、系统设置等即使“只是启动”也会被拒绝。
解析不到应用返回 `app_not_found`，不猜相近的名字。

### 3. 已在运行就激活，不重复启动

`NSRunningApplication.runningApplications` 找到已有进程时直接激活并返回，
避免同一应用开出第二个实例（也避免副作用）。

### 4. 用 `/usr/bin/open` 启动，再轮询运行列表

- 解析到路径：`open <path>`；
- 只有 bundle id：`open -b <bundleId>`；
- 只有显示名：`open -a <name>`；
- 最多等 10 秒确认进程出现；超时返回 `action_failed`。

没有用 `NSWorkspace.openApplication` 的异步 completion，避免在 CLI sidecar 里
阻塞主线程或依赖 run loop。

### 5. 平台实现放在 Core 的 `AppLauncher` 协议后面

`WorkspaceAppLauncher` 依赖 AppKit/LaunchServices；`DesktopSession` 只依赖协议。
测试注入 `FakeLauncher`，不真的打开应用。

## 取舍

**接受了“启动会切前台”的副作用。** 启动后应用会被激活；如果用户正在用电脑，会被打断。
`activate` 目前固定为 true，不提供静默启动参数。

**接受了按名称解析的范围限制。** 只查运行列表、标准 Applications 目录与 bundle id；
不在这些位置的 `.app` 需要给完整路径。解析不到就报 `app_not_found`，不模糊匹配。

**接受了“启动成功 ≠ 界面可读”的现实。** 进程出现不代表 AX 树已就绪；
调用方应随后 `get_ax_state`，不要假设窗口已经加载完。

**没有做启动后的自动等待/绑定。** 这是有意的：等待窗口是调用方的选择，
SCU 只报告进程已经出现。

## 后果

- MCP 新增动作工具 `launch_app`；不改线协议；
- `PolicyGate` 增加只按 bundle id 的检查入口；
- `DesktopSession` 增加可注入的 `AppLauncher`；
- 冷启动与显示名解析已用计算器验证；非标准路径与更多真实应用待验证；
- 后续可以做“启动 → 等窗口 → 读取”的组合，但不把等待藏在 launch 里。

## 相关文档

- [MCP 接入面](../interfaces/mcp_surface.md)
- [策略层](../architecture/policy_layer.md)
- [错误码表](../interfaces/error_taxonomy.md)
- [真实应用验证](../../verification/2026-10-19-real-app-netease.md)
