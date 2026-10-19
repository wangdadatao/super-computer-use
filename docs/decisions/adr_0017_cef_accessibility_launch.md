# ADR-0017 CEF/Chromium 应用以无障碍启动参数恢复 AX 路径

- **状态**：已接受（实验性；必须经用户同意）
- **日期**：2026-10-19

## 背景

P0 与 v1 的寻址建立在"应用暴露无障碍树"这一前提上。2026-10-19 的真实应用验证发现：
**网易云音乐 3.1.12（Chromium Embedded Framework 1162）在正常启动下窗口零子元素**，
AX 里只有应用、窗口与菜单栏；对它设置 `AXManualAccessibility` 返回 `attributeUnsupported`，
设置 `AXEnhancedUserInterface` 返回 `notImplemented`。

但以 Chromium 的启动参数重启后，同一应用暴露了完整的 `AXWebArea`（1511 个元素），
搜索、输入、点击与播放器状态都可通过 AX 完成。结果见
[verification/2026-10-19-real-app-netease.md](../../verification/2026-10-19-real-app-netease.md)。

ADR-0013 曾把"主动设置 `AXManualAccessibility` / `AXEnhancedUserInterface`"列为有副作用的操作、
需要先设计。本条把其中可行的变体（启动参数）定下来。

## 决策

### 1. 只在"AX 为空"且应用是 Chromium 系时尝试

识别条件（两个都满足）：

1. `get_ax_state` 读到的窗口没有子元素（菜单栏之外读不到内容）；
2. 应用的 bundle 内含 `Chromium Embedded Framework.framework` 或 `Electron Framework.framework`
   （`Contents/Frameworks` 或 `otool -L` 可判断）。

不满足时不做任何重启尝试。

### 2. 必须经用户同意，不静默重启

带参数启动需要先退出应用，会中断用户当前状态（播放、未保存的表单等）。
因此这是**显式的、一次性的应用级适配**：

- 向用户说明要退出并重启哪个应用、为什么；
- 得到同意后才执行；不把"重启应用"藏在读取动作里；
- 重启后重新读取；只有出现 `AXWebArea` 才继续。

### 3. 用启动参数，不改运行时属性

采用 Chromium 的 `--force-renderer-accessibility`：

```bash
open -a "<应用名>" --args --force-renderer-accessibility
```

运行时属性（`AXManualAccessibility` / `AXEnhancedUserInterface`）仍可尝试，但本应用两者都不支持；
启动参数是最后一个不需要注入代码的手段。

### 4. 失败即如实报告，不退化为猜测

重启后仍读不到内容时，返回"该应用不支持 AX 操作"，**不**尝试盲发按键、不退化为坐标猜测。
v1 没有截图与坐标；盲操作无法核实，且会重复输入（见验证记录里的事故）。

### 5. 记录应用适配

每次尝试都在 `verification/` 记录：应用版本、框架版本、参数、结果、用户是否同意。
同一应用再次遇到时可直接复用结论，不必重复重启。

## 取舍

**接受了"改变应用启动方式"的副作用。** 这不是只读操作：参数会影响应用的渲染与性能特性，
退出重启会打断用户。换来的是一条**语义完整、可核实、比截图便宜**的 AX 路径。

**接受了参数不被所有应用支持。** 该参数是 Chromium 的开关；CEF/Electron 是否透传取决于应用。
不保证成功；失败时按第 4 条处理。

**接受了应用级知识的存在。** 这条能力天然是 per-app 的（哪个应用、什么参数、什么版本）。
v1 不做应用知识库，所以当前只在技能文档与验证记录里维护，不建设通用机制。

## 后果

- `skills/scu/SKILL.md` 增加 CEF/Chromium 应用的识别与处理步骤
- 真实应用验证记录新增一份（网易云）
- 未来若做应用知识库，本条是它的第一个条目候选
- 不改线协议、不改动作语义；这是接入层/调用方的操作流程

## 相关文档

- [真实应用验证：网易云](../../verification/2026-10-19-real-app-netease.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- [本地环境](../operations/local_setup.md)
- [ADR-0013](adr_0013_p0_vertical_slice.md)
