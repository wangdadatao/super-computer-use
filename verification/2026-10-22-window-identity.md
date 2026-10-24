# 2026-10-22 窗口身份

## 范围

给窗口增加稳定身份，闭合 ADR-0021/0026/0027 的“只能按标题选窗口”限制。覆盖：

- `Target`（`pid + windowID? + windowTitle?`）贯通协议层与原生层；
- `list_windows` / `WindowCapture` 返回 `CGWindowID`；
- MCP `get_ax_state(window_id=)`，优先于 `window` 标题；
- 截图绑定实际窗口 ID，坐标动作与动作后观察都用它；
- 线协议升到 **v12**。

不覆盖：浏览器窗口、同名窗口的真实多窗口回归、窗口重建后的会话恢复。

## 改变了什么

- `SCUWire.Target` 新增；所有窗口相关请求从 `pid + windowTitle` 改为 `target: Target`；
- `WindowInfo.windowID`、`WindowCapture.windowID` 新增；
- `AXBackend.nativeWindows` 枚举 AX 窗口，并用 CoreGraphics 窗口列表按 owner pid、layer、frame、标题匹配 `CGWindowID`；
- `WindowActivation.activate(target:)` 优先按 ID 选窗口，找不到失败关闭；
- `ScreenCapture` 用 `SCWindow.windowID` 精确匹配；
- `DesktopSession` 的令牌记录、差异基线、截图绑定保存窗口 ID；
- MCP `list_windows` 输出 ID，`get_ax_state` 增加 `window_id`，`get_screenshot` 输出 `window_id`。

没有使用私有 `_AXUIElementGetWindow`；匹配不唯一时返回 nil，回退标题/frame。

## 证据

环境：macOS 26.6.2 / arm64，Edge pid 1974，窗口标题前后发生变化（`pi-web-shell - Microsoft Edge` → `主页 / X - Microsoft Edge`），ID 保持 `550918`。

`scu windows`：

```text
#550918	"主页 / X - Microsoft Edge"	(58,33,1670,1084)
```

CLI `dump --window-id`（原生层按 ID 定位窗口根）：

```text
元素 5；有 AXIdentifier 0（0.0%）；有 title 2（40.0%）；有 description 0（0.0%）
[AXWindow] subrole=AXStandardWindow title="主页 / X - Microsoft Edge"
```

MCP `get_ax_state(window_id=550918, max_depth=2)`：

```text
# pid=1974 令牌 s425giz.1 元素 5 window_id=550918...
[AXWindow#1] "主页 / X - Microsoft Edge" subrole=AXStandardWindow frame=(58,33,1670,1084)
```

MCP `get_screenshot`（同一令牌）：

```text
screenshot_id=gswroe.1 图像 1600x1039 scale=0.958 window=(58,33,1670,1084) window_id=550918 title="主页 / X"
```

同一 ID 在标题变化后仍被 `get_ax_state` 接受，说明标题不是唯一身份。

测试：

```text
swift test --disable-sandbox
155 tests in 12 suites passed after 67.1 seconds with 1 known issue
```

新增测试覆盖：`Target`/`windowID` 线格式、窗口匹配按 frame/标题消歧、歧义返回 nil、
`readState` 与元素动作携带 ID、截图绑定用实际窗口 ID 做坐标动作、MCP `list_windows`/`get_ax_state`/`get_screenshot` 的 ID 输出。

## 边界与后续

- 同名窗口的真实回归仍未做；CoreGraphics/AX 匹配依赖 frame/标题，匹配不到时回退。
- 窗口重建后 `CGWindowID` 改变，旧令牌按 `window_not_found` 拒绝，需要重新读取。
- 坐标动作的真实鼠标验证沿用既有网易云/TextEdit 结论；本次没有为了验证 ID 再移动真实光标。
- `SCUCore` 的 macOS 依赖（AppLauncher、宿主祖先链、ScreenshotDiff）仍未移动；`Target` 目前是协议类型，不是完整平台抽象。
