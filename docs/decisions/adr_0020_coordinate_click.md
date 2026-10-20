# ADR-0020 坐标点击：真实鼠标事件 + 先激活窗口

- **状态**：已接受（实验性）
- **日期**：2026-10-20

## 背景

网易云左侧栏暴露了 `AXGroup` + `AXPress`，标签能选，但 `click(label)` 返回
`noOpSuspected=true`：`AXPress` 被投递，应用不响应。这类 CEF/React 控件监听真实鼠标事件，
无障碍动作不是等价通道。

ADR-0019 已经能截取目标窗口并给出 `windowFrame + scale`；本 ADR 决定怎么用这组坐标真正点到。

采集过程中的两个事实：

1. `CGEvent.postToPid` 的鼠标事件对网易云侧栏不生效；
2. 窗口不在当前 Space/显示器时，`SCWindow.frame` 可能与 AX/CGWindowList 的屏幕坐标不一致
   （实测窗口真实位置 `(353,199)`，截图元数据却是 `(-1769,36)`）。如果直接按截图原点换算，
   点击会落到屏幕外。

## 决策

### 1. `click_at(token, screenshot_id, x, y)`

- 坐标以**截图左上角**为原点，单位是图像像素；
- 必须同时给 `token` 与 `screenshot_id`；截图绑定令牌与窗口几何；
- 截图尺寸越界 → `invalid_coordinates`，不 clamp、不猜；
- 策略检查与元素动作相同：拒绝类目在点击前拒绝。

### 2. 先激活并 raise 目标窗口

截图前与点击前都执行：

1. `NSRunningApplication.activate`；
2. 对目标应用第一个 `AXWindow` 执行 `AXRaise`；
3. 等待目标成为 frontmost；超时则**取消**，不点击。

这样截图元数据与真实屏幕坐标一致，也避免点到前台的其他应用。
代价是切换前台应用；这是坐标点击的可见副作用。

### 3. 用全局鼠标事件，不用 `postToPid`

`CGEvent` 的 mouseMoved / leftMouseDown / leftMouseUp 投到 `.cghidEventTap`，
会移动真实光标。实测这是网易云侧栏唯一有效的通道；`postToPid` 不生效。
不提供“先 postToPid 再自动重试全局”的隐式回退——两次点击会带来双重副作用。

### 4. 观察 AX 树 + 全图像素比例

点击后重读 AX 树：结构变化 → 令牌作废。随后再截一张窗口图，与点击前的截图比较
**全图像素变化比例**（阈值 0.1%），报告 `screenshotChanged` 与 `diffRatio`。

- 树变了或图变了：`noOpSuspected=false`；
- 树没变但图变了：报告“像素有变化”，可能是画布/悬停/局部刷新；
- 树和图都没变：`noOpSuspected=true`，不要重复点；
- 窗口位置/缩放变了：`geometryChanged=true`，截图 diff 不可比。

全图比例不定位变化区域，也不证明“点中了目标”；它是比只看树更强的信号，不是成功保证。

### 5. 坐标点击是最后手段

优先 `click(label)` / `click(handle)`；只有 AX 动作无效或没有 AX 元素时才用 `click_at`。
坐标点击没有元素身份，不能做目标核对，验证弱于元素动作。

## 取舍

**接受了抢焦点与移动光标。** 这是真实鼠标点击的代价；如果用户正在用电脑，会被打断。
调用方应先确认目标窗口可见、当前没有正在进行的输入。

**接受了“窗口必须在前台”的限制。** 不能点后台/其他 Space 的窗口；多显示器下先激活再截图。
这比“点错应用”安全。

**接受了验证仍不精确。** 全图像素比例能区分“完全没反应”和“有像素变化”，
但不能区分“点中了目标”与“点了别处导致动画/悬停”。不重复点，必要时让用户核实。

**没有做虚拟光标/指示层。** 真实光标会移动；虚拟光标是后续能力。

## 后果

- 线协议升到 v8：新增 `clickAt(pid, x, y)`；
- MCP 新增动作工具 `click_at`；
- `get_screenshot` 在截图前激活目标窗口（否则坐标不可用）；
- 坐标点击的验证做 AX 树 + 全图像素比例；区域级 diff 后置；
- 多显示器/窗口移动/抢焦点写入已知限制。

## 相关文档

- [原生层线协议](../interfaces/native_wire_protocol.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- [ADR-0019](adr_0019_window_screenshot.md)
- [ADR-0025](adr_0025_window_target.md)
- [真实应用验证](../../verification/2026-10-19-real-app-netease.md)
