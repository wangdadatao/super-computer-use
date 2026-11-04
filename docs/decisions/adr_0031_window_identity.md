# ADR-0031 窗口身份：CGWindowID 进入 Target 与截图绑定

- **状态**：已接受（0.5.0；2026-10-22 提出，2026-11-04 随 0.5.0 收口）；同名窗口真实回归已于 2026-11-04 通过，无标题窗口回归仍待做
- **日期**：2026-10-22

<a id="window_identity"></a>

## 背景

多窗口操作一直有残余风险：

- 无标题窗口只能退回“面积最大窗口”；
- 同名窗口同标题，`windowTitle` 无法区分；
- 截图绑定只保存实际截到的**标题**，坐标动作再按标题选一次，可能落到另一个窗口；
- 窗口改名会让旧令牌失效，但窗口本身没变。

[ADR-0021](adr_0021_scroll_and_drag.md) 与 [ADR-0027](adr_0027_window_root_locator.md)
都把“完整修复需要窗口 ID”列为已知限制。此前的理由是 AX 没有稳定的公开窗口号；
但 CoreGraphics 的 `CGWindowID` 是窗口生命周期内稳定的公开标识，ScreenCaptureKit 的
`SCWindow.windowID` 也直接给出同一个值。

## 决策

### 1. `Target` 统一承载 pid 与窗口身份

```text
Target = { pid: int, windowID?: uint32, windowTitle?: string }
```

- `windowID` 是 `CGWindowID`，窗口生命周期内稳定；
- `windowTitle` 只作可读线索与回退，不承诺唯一；
- 两者都缺省表示“应用默认窗口”。

线协议中所有窗口相关请求从 `pid + windowTitle` 收敛为 `target: Target`；
`list_windows` 与 `WindowCapture` 返回 `windowID`。协议升到 **v12**。

### 2. ID 优先，标题回退，失败关闭

- `windowID` 存在时必须精确匹配；找不到返回 `window_not_found`，不退回标题或最大窗口；
- 没有 ID 时才按标题匹配；没有标题才使用“最大非最小化窗口”；
- 截图绑定保存实际截到的 `windowID`（取不到时退回标题/frame），坐标动作与动作后观察都用它。

### 3. AX 窗口与 CGWindowID 的匹配

AX 没有公开窗口号。原生层枚举 AX 窗口，同时读取 CoreGraphics 窗口列表，
按 owner pid、`windowLayer == 0`、frame（2 点容差）与标题匹配：

- 匹配唯一才赋 ID；
- 不唯一时返回 nil，宁可回退到标题，也不猜；
- 不使用私有 `_AXUIElementGetWindow` 等符号。

### 4. 只加窗口身份，不改变授权粒度

应用允许列表与拒绝类目仍按应用判定；窗口 ID 不引入“窗口级授权”。
窗口 ID 只解决“选哪个窗口”，不解决“能不能操作这个应用”。

## 取舍

**接受了 CGWindowID 的获取成本。** 每次窗口选择都要枚举 CoreGraphics 窗口列表并匹配 AX 窗口；
这比只读标题多一次系统调用，但换来同名窗口可区分、无标题窗口不再退化为“最大窗口”。

**接受了匹配失败时的回退。** 某些窗口（最小化、跨 Space、AX 与 CG 标题/几何不一致）可能匹配不到 ID。
此时行为退回标题/frame；这是明确回退，不是假装 ID 一定存在。

**没有引入私有 AX API。** 私有符号可能随系统版本消失，也会给分发带来审核风险；
CoreGraphics 的窗口号是公开契约。

**没有解决“窗口级会话恢复”。** 窗口重建后 CGWindowID 会变；旧令牌按 `window_not_found`
拒绝，调用方重新读取。这比错误地复用新窗口安全。

## 后果

- 线协议 v12：所有窗口相关请求带 `target`；`list_windows`、`WindowCapture` 带 `windowID`；
- MCP `get_ax_state` 增加 `window_id`，优先于 `window` 标题；
- `get_screenshot` 输出 `window_id`，坐标动作绑定实际截图窗口；
- 新增 `Target`、`WindowInfo.windowID`、`WindowCapture.windowID` 与匹配测试；
- 已知限制：AX/CG 匹配不唯一时无 ID；同名窗口仍可能回退到标题；窗口重建后 ID 改变；
- 真实验证：Edge 窗口列表返回 `#550918`，`get_ax_state(window_id=550918)` 与
  `get_screenshot` 均返回同一个 ID；两条同标题 TextEdit 窗口（`#3134009`/`#3134010`）上
  `scu windows`、`dump --window-id`、`get_screenshot.window_id`、标记不串窗四项全部通过，
  见 [同名窗口回归](../../verification/2026-11-05-window-identity-same-title.md)；
  无标题窗口的真实回归仍未做。

## 相关文档

- [原生层线协议](../interfaces/native_wire_protocol.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- [目标发现与绑定](../interfaces/target_discovery.md)
- [ADR-0021 滚动与拖拽](adr_0021_scroll_and_drag.md)
- [ADR-0025 多窗口目标](adr_0025_window_target.md)
- [ADR-0026 窗口选择](adr_0026_window_selection.md)
- [ADR-0027 窗口根定位](adr_0027_window_root_locator.md)
- [验证记录](../../verification/2026-10-22-window-identity.md)
- [同名窗口回归](../../verification/2026-11-05-window-identity-same-title.md)
