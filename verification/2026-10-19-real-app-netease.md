# 真实第三方应用端到端：网易云音乐（2026-10-19）

第一次在**真实第三方应用**上跑通「读取 → 找到元素 → 输入 → 按键 → 点击 → 确认效果」。
此前的动作验证只有自制夹具；访达只做过不点击的 `verify`。

## 采集环境

| 项 | 值 |
| --- | --- |
| 系统 | macOS 26.6.2，arm64 |
| 宿主 | pi agent 会话（launchd 下的 `node`）；辅助功能已授予（`scu permissions` 退出码 0） |
| 应用 | 网易云音乐 `3.1.12`（build `3444`），`/Applications/NeteaseMusic.app` |
| 二进制 | `Contents/MacOS/NeteaseMusic`，SHA-256 前缀 `e9c6b546…` |
| 框架 | Chromium Embedded Framework `1162.0.2`（`otool -L`） |
| SCU | 提交 `4ea05aa`，线协议 5 |
| 屏幕录制 | 未授予（`screencapture` 失败），本记录不依赖截图 |

## 方法

1. **正常启动**：`open -a NeteaseMusic`，用 `get_ax_state` 读取。
2. **尝试运行时开关**：对应用元素设置 `AXManualAccessibility` 与 `AXEnhancedUserInterface`。
3. **带参数重启**：退出应用后
   ```bash
   open -a NeteaseMusic --args --force-renderer-accessibility
   ```
4. 重新读取；再用 MCP 动作完成搜索与播放：
   - `type_text` 写入搜索框（一次调用）；
   - `press_key(Return)` 提交搜索；
   - `click`「单曲」区的「播放」按钮；
   - 每次动作后重新读取，检查令牌与播放器状态。

## 结果

| 步骤 | 结果 |
| --- | --- |
| 正常启动下的 AX 树 | **窗口零子元素**：只有 `AXApplication`、`AXWindow`、`AXMenuBar` |
| `AXManualAccessibility` | `attributeUnsupported`（-25205） |
| `AXEnhancedUserInterface` | `notImplemented`（-25208） |
| 带参数重启后的 AX 树 | **出现 `AXWebArea`**，整树 1511 个元素；找到 `AXTextField#132`（搜索框）与 `AXButton#129 "search"` |
| 输入「梁静茹 暖暖」 | `type_text` 一次调用；`treeChanged=true`、`targetChanged=true`、令牌失效；字段值正好是 `梁静茹 暖暖`，**没有重复** |
| 按 Return | 搜索结果出现（824 个元素，多条「暖暖 / 梁静茹」） |
| 点击「单曲」区「播放」 | `treeChanged=true`；播放器出现 `pause` 图标与「暖暖 / 梁静茹」，菜单「暂停」可用 |
| 确认播放状态 | 通过 AX 的 `pause` 与歌曲标题确认；**没有**验证实际音频输出 |

## 观察

1. **CEF 的运行时开关不生效，启动参数生效。** 该应用的窗口在正常启动下完全不暴露网页内容；
   `--force-renderer-accessibility` 是唯一让它进入 AX 的已知方式。
2. **中文输入成立且不需要输入法。** `type_text` 用 Unicode 键盘事件写入中文，一次调用只写一次。
3. **动作后的令牌与效果摘要在真实网页 UI 上成立。** 输入与点击都返回 `treeChanged=true` 并使旧令牌失效；
   重新读取后能继续下一步。
4. **播放状态可以被 AX 核实。** 播放器从 `play` 变成 `pause`，并显示歌曲与歌手。
5. **代价是重启应用。** 带参数启动会中断用户当前状态（本次中断了正在播放的歌）；
   这是有副作用的操作，不能静默执行。

## 一次操作事故（记录教训）

在发现 AX 为空、还没加启动参数时，我用 `press_key(cmd+f)` + `type_text` 盲操作了一次；
因为 AX 读不到搜索框，效果摘要只显示 `noOpSuspected=true`，我误判为"没生效"，又执行了一次，
导致搜索框出现 `梁静茹 暖暖梁静茹 暖暖`。

**这不在 SCU 的重复投递**：每次 `type_text` 只发一遍，是调用方（我）重复调用了两次。
教训：对不暴露 AX 的应用，`noOpSuspected` 不能作为"没生效"的判断，更不能盲目重试。
这条已写入 [skills/scu/SKILL.md](../skills/scu/SKILL.md)。

## 追加：快照内标签（同日）

应用以同样参数重启（pid `7554`）后，验证 [ADR-0018](../docs/decisions/adr_0018_label_addressing.md) 的标签寻址：

- `get_ax_state` 输出 457 个元素；搜索按钮带 `[a] [AXButton#118] "search" frame=(-1489,72,42,28)`，
  搜索框带 `[b] [AXTextField#132] frame=(-1447,71,216,30)`（窗口在副屏，x 为负）。
- `type_text(token, label="b", text="test")`：`delivered=true observed=true converged=true treeChanged=true
  targetChanged=true`，0.7 秒；重读搜索框出现 `value="test"`，并出现 `Test/TEST/test` 搜索建议。
- `set_value(token, label="b", value="")`：搜索框被清空，恢复为空。
- `click(token, label="a")`（搜索按钮）：`delivered=true observed=true converged=true treeChanged=true`，0.6 秒；
  重读得到新令牌，动作路径成立。

第一次动作后 0.5 秒重读时 value 还未出现，第二次动作后才出现；说明动作后的读取仍可能落在中间状态，
与收敛启发式的已知缺口一致。**标签解析与按标签动作本身成立**；标签仍只对签发它的令牌有效。

## 追加：左侧栏标签与 AXPress 空操作（2026-10-20）

用户观察到左侧栏（推荐/精选/播客/漫游/关注…）没有标签。原因是它们不是 `AXButton`，
而是 `AXGroup` 包 `AXImage` + `AXStaticText`；原角色白名单漏掉了。

读取 `AXActionNames` 后（线协议 v7），这些行现在带标签：

```text
[e] [AXGroup#19] actions=[AXPress,AXShowMenu,AXScrollToVisible] frame=(-1745,126,164,36)
[f] [AXGroup#23] actions=[AXPress,AXShowMenu,AXScrollToVisible] frame=(-1745,166,164,36)
```

但 `click(label="e")` / `click(label="f")` 都返回：

```text
delivered=true observed=true converged=true treeChanged=false targetChanged=false noOpSuspected=true
```

界面没有切换，说明 **`AXPress` 对这些网页侧栏是空操作**。标签解决了“选目标”，
没有解决“让应用响应”；这类控件需要真实鼠标坐标点击（`click_at`，尚未实现）。
不要对 `noOpSuspected` 反复重试。

同一轮截图里有 63 个标签。我们收紧了规则：按钮/输入框总是标；包含控件的容器不重复标；
非角色的 `AXPress` 分组只标最外层。仍然密集，下一步需要 `max_labels` 或按区域筛选。

## 追加：窗口截图与标签叠加（2026-10-20）

屏幕录制权限在宿主上授予后，验证 [ADR-0019](../docs/decisions/adr_0019_window_screenshot.md)：

- `get_screenshot(token)` 返回 `screenshot_id=g4eek2l.1`，图像 `1600×1138`，`scale=1.514`，
  `window=(-1769,36,1057,752)`；窗口在副屏，原点为负。
- 截图只含网易云窗口，不含整屏；搜索框附近能看到 `[a]`/`[b]` 徽标，卡片与播放器上也有标签。
- 图像与文本元素表的标签一致；文本清单仍是权威。
- 截图只写入 `/tmp` 用于本次核对，**没有入库**：画面含用户的音乐库与推荐内容，不适合作为长期证据。

观察：ScreenCaptureKit 在纯命令行 sidecar 里需要显式建立 `NSApplication.shared`，否则会触发
`CGS_REQUIRE_INIT` 断言并崩溃；叠加用 CoreGraphics + CoreText，因为 NSImage 的 TIFF 中转
在无 GUI 会话里会失败。

## 限定

- 只测了一个应用、一个版本（`3.1.12`）；其他 CEF/Electron 应用是否支持该参数未知。
- 只验证了登录态、免费曲目下的搜索与播放；未测付费/版权受限曲目。
- 没有验证实际音频输出，只用 AX 的播放器状态推断。
- 正常启动下该应用仍然不可操作；带参数重启是前提。
- 屏幕录制未授予，本次没有使用截图或坐标。

## 影响

- [ADR-0017](../docs/decisions/adr_0017_cef_accessibility_launch.md)：CEF/Chromium 应用的无障碍启动参数作为**需用户同意的应用级适配**。
- [skills/scu/SKILL.md](../skills/scu/SKILL.md)：新增 CEF 应用的识别与处理步骤。
- [MCP 接入面](../docs/interfaces/mcp_surface.md#未验证项)：真实应用上的动作验证状态更新。
- [ADR-0018](../docs/decisions/adr_0018_label_addressing.md)：快照内短标签寻址。
