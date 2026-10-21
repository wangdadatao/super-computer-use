# ADR-0021 滚动与拖拽：坐标手势

- **状态**：已接受（实验性；0.3.0 补真实拖拽验证）
- **日期**：2026-10-20

## 背景

滚动与拖拽是桌面操作里最常见的两个手势。无障碍树有时提供滚动动作，但网页/CEF 的列表、
画布和自绘控件不一定响应；拖拽几乎没有通用的无障碍动作。ADR-0019/0020 已经提供了
窗口截图、`screenshot_id`、坐标换算与真实鼠标投递，本 ADR 把同一套基础设施用于手势。

## 决策

### 1. `scroll_at(token, screenshot_id, x, y, dx, dy)`

- 坐标以截图左上角为原点，单位图像像素；
- `dy > 0` 表示向下滚，`dx > 0` 表示向右；增量为 0 拒绝；
- 在坐标处投递滚轮事件；滚轮事件带位置，不需要先点击聚焦；
- 滚动后重读 AX 树并比较全图像素比例。

### 2. `drag(token, screenshot_id, from_x, from_y, to_x, to_y, duration_ms)`

- 起点/终点都是截图坐标；越界或起终点相同拒绝；
- 采用 mouseMoved → leftMouseDown → 12 段 leftMouseDragged → leftMouseUp；
- `duration_ms` 默认 400，范围 100...2000；
- 拖拽后同样重读树 + 截图 diff。

### 3. 与 `click_at` 共享前置条件

- 目标窗口先激活并 raise；不能成为 frontmost 就取消；
- 使用真实鼠标事件（会移动光标）；
- 截图必须属于当前令牌，窗口几何变化 → `stale_geometry`；
- 策略拒绝在动作前生效；
- 结果统一为 `treeChanged` / `screenshotChanged` / `diffRatio` / `geometryChanged` /
  `noOpSuspected`。

### 4. 拖拽是高风险动作

拖拽可能移动文件、调整列表顺序、改变画布内容，且没有审批层。调用方必须：

- 在拖拽前确认起点/终点与目标；
- 不要在不确定的界面拖拽；
- 失败/空操作时不要重复拖拽，先截图核实。

## 取舍

**接受了手势没有元素身份。** 无法像 `click(label)` 那样核对目标；验证只到树与像素比例。
拖拽尤其依赖调用方对画面的判断。

**接受了滚轮方向/步长的平台差异。** macOS 的滚轮单位与自然滚动设置会影响手感；
当前用像素单位与固定符号约定，真实应用按网易云验证，其他应用可能需要调整。

**接受了拖拽的副作用。** 会移动真实光标，可能改变文件/列表；没有审批层之前，
它只适合低风险、可逆的场景。

**接受了验证只到像素级。** TextEdit 拖拽选区实测到 `screenshotChanged=true`、
`diffRatio=0.0036`，但 AX 树没有选区状态，无法读回“选中了哪些字”；拖拽后的语义结果
仍需截图或后续动作确认。

## 后果

- 线协议升到 v9：新增 `scrollAt` 与 `dragAt`；
- MCP 新增动作工具 `scroll_at` 与 `drag`；
- 测试覆盖坐标换算、零增量/同点拒绝、线协议形状；
- 网易云实测滚动（推荐页上下滚动，diff 约 0.387）；
- 拖拽有单元/MCP 测试；TextEdit 拖拽选区实测到像素变化（`screenshotChanged=true`，
  `diffRatio=0.0036`），但未读回选区语义。

## 相关文档

- [原生层线协议](../interfaces/native_wire_protocol.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- [ADR-0020](adr_0020_coordinate_click.md)
- [真实应用验证](../../verification/2026-10-19-real-app-netease.md)
