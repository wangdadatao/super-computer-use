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
  搜索框带 `[b] [AXTextField#132] frame=(-1447,71,216,30)`（当时窗口不在当前 Space，x 为负）。
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
没有解决“让应用响应”；这类控件需要真实鼠标坐标点击；`click_at` 已由 [ADR-0020](../docs/decisions/adr_0020_coordinate_click.md) 实现，见下一节。
不要对 `noOpSuspected` 反复重试。

同一轮截图里有 63 个标签。我们收紧了规则：按钮/输入框总是标；包含控件的容器不重复标；
非角色的 `AXPress` 分组只标最外层。仍然密集，下一步需要 `max_labels` 或按区域筛选。

## 追加：坐标点击与窗口原点（2026-10-20）

在左侧栏 `AXPress` 空操作后，实现 `click_at` 并验证：

1. 第一次用截图坐标 (160,224) 点击「精选」，`treeChanged=true`，但页面没有切换。
   原因不是点击没投递，而是窗口当时不在当前 Space：截图元数据 `window=(-1769,36,...)`，
   AX/CGWindowList 的真实窗口位置是 `(353,199,...)`。按旧原点换算出的全局点在屏幕外。
2. 改为**截图前与点击前都激活并 raise 目标窗口**后，截图元数据变为 `window=(353,199,1057,752)`，
   同一图像坐标 (160,224) 点击成功：左侧栏切到「精选」，`treeChanged=true`。
3. 再用同一窗口截图坐标 (160,163) 点击「推荐」，切回推荐，`treeChanged=true`。
4. 两次点击的截图 diff 分别为 `diffRatio=0.4375` 与 `0.4354`，`screenshotChanged=true`，
   `geometryChanged=false`；说明“树变了 + 图变了”能互相印证。

同时确认：`CGEvent.postToPid` 的鼠标事件对网易云侧栏不生效；全局鼠标事件（会移动光标）生效。
代价是抢前台与移动光标；点击前若目标不能成为 frontmost，会取消而不是盲点。

## 追加：窗口截图与标签叠加（2026-10-20）

屏幕录制权限在宿主上授予后，验证 [ADR-0019](../docs/decisions/adr_0019_window_screenshot.md)：

- `get_screenshot(token)` 返回 `screenshot_id=g4eek2l.1`，图像 `1600×1138`，`scale=1.514`，
  `window=(-1769,36,1057,752)`；这是激活前截图的元数据，窗口当时不在当前 Space，原点为负。
- 截图只含网易云窗口，不含整屏；搜索框附近能看到 `[a]`/`[b]` 徽标，卡片与播放器上也有标签。
- 图像与文本元素表的标签一致；文本清单仍是权威。
- 截图只写入 `/tmp` 用于本次核对，**没有入库**：画面含用户的音乐库与推荐内容，不适合作为长期证据。

观察：ScreenCaptureKit 在纯命令行 sidecar 里需要显式建立 `NSApplication.shared`，否则会触发
`CGS_REQUIRE_INIT` 断言并崩溃；叠加用 CoreGraphics + CoreText，因为 NSImage 的 TIFF 中转
在无 GUI 会话里会失败。

## 追加：滚动（2026-10-20）

`scroll_at(token, screenshot_id, 900, 700, 0, 600)`（dy > 0 向下）：

- `treeChanged=true`、`screenshotChanged=true`、`diffRatio=0.3868`、`geometryChanged=false`；
- 画面从「推荐歌单」滚到「榜单精选」区域。

再用 `dy=-600` 向上滚：

- `treeChanged=false`（滚动位置不在 AX 摘要里）、`screenshotChanged=true`、`diffRatio=0.3879`；
- 画面回到上方。说明“树不变但图变”的情况确实存在，不能只看树。

拖拽只有单元/MCP 测试，未在真实应用上执行（可能移动列表项/文件）。

## 追加：应用启动（2026-10-20）

- `launch_app("Calculator")`（冷启动）：返回“计算器（pid 63285，bundle com.apple.calculator）”，
  进程确实出现；验证后退出计算器。
- `launch_app("com.netease.163music")`（已运行）：返回已有 pid 7554，没有重复启动。
- `launch_app("com.apple.Terminal")`：`policy_denied`（`runs_shell_commands`），没有启动。
- `launch_app("不存在的应用")`：`app_not_found`。

冷启动只验证了“进程出现”；没有自动等待窗口或 AX 树就绪。

## 追加：坐标动作指示环（2026-10-20）

- `click_at` 在网易云左侧栏 (160,224) 与 (160,163) 上仍成功：树与图均变化，
  diff 0.4464 / 0.5300，耗时约 1.6s（含 120ms 指示与前后截图）。
- 指示环窗口 `ignoresMouseEvents`、`sharingType = .none`，目标窗口截图里看不到它；
  因此“圆环确实显示”只能靠人工观察，不能像 AX 变化那样自动断言。
- 多显示器、不同缩放下的圆环位置未验证。

## 追加：TextEdit 窗口目标（2026-10-20）

- 打开一个临时文本窗口（`/tmp/scu-win.txt`），`get_ax_state` 读取 pid 65797 成功。
- `get_screenshot` 返回 `window=(-2251,-220,656,422) title="scu-win.txt"`，
  与 AX 顶层窗口的标题/frame 一致；验证后关闭 TextEdit 并删除临时文件。
- 没有做点击；多窗口（同时两个窗口）未验证。窗口选择规则见 [ADR-0025](../docs/decisions/adr_0025_window_target.md)。

## 追加：连接级应用允许列表（2026-10-20）


- `scu mcp --actions --allow-app com.netease.163music`：`get_ax_state` 读取网易云 pid 7554 成功。
- 同一进程读取访达 pid 697：返回 `app_not_authorized`，消息含当前允许列表；
  读取在原生层之前被拒（单元测试断言 `readTree` 未被调用）。
- `--allow-app-file /tmp/scu-allowed.json`（JSON `["com.netease.163music"]`）：读取网易云成功。
- `--allow-app com.example.not-real`：启动退出码 64，拒绝启动并提示无法解析 bundle id。
- 没有在允许列表模式下做点击/输入；动作门禁由单元测试覆盖。

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
