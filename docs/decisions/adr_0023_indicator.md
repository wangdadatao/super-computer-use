# ADR-0023 坐标动作前的可见指示环

- **状态**：已接受（实验性）
- **日期**：2026-10-20

## 背景

`click_at` / `scroll_at` / `drag` 会激活窗口并移动真实光标；用户只能看到光标突然跳过去，
不知道 AI 准备点哪里。ADR-0013 把“虚拟指示层”列为 v2 候选；本 ADR 先做最小可见提示，
不做审批，也不做完整虚拟光标。

<a id="indicator_decision"></a>
## 决策

### 1. 动作前在目标位置显示蓝色圆环

- 点击/滚动：一个圆环在目标点；
- 拖拽：起点与终点各一个圆环；
- 显示约 120ms 后再投递事件，动作完成后立即关闭；
- 圆环是独立窗口，不是画进截图里的图形。

### 2. 窗口属性

- `borderless` / 透明背景 / `.floating`；
- `ignoresMouseEvents = true`：不拦截点击；
- `canJoinAllSpaces` + `fullScreenAuxiliary`：切 Space 也能看到；
- `sharingType = .none`：不进入截图/录制；
- 不激活应用、不抢焦点；
- 坐标从全局点击点（左上原点）换算到 AppKit 窗口坐标（主屏左下原点）。

### 3. 只做提示，不做确认

指示环不阻塞动作，也不要求用户点击“允许”。审批层仍未实现；
危险动作仍靠调用方/用户在对话里确认。

## 取舍

**接受了 120ms 的固定延迟。** 它让用户至少能看到一眼目标；如果嫌慢，后续可以按动作类型调整。

**接受了“提示不可截图验证”。** 因为窗口排除了截图，自动化测试看不到它；
它的正确性靠窗口属性与人工观察，不能像 AX 动作那样断言。

**提供了关闭开关。** `SCU_INDICATOR=0` 时不显示圆环，也不插入 120ms 等待；
默认开启。

**接受了只在 sidecar 主线程创建窗口。** `scu-native` 是同步 CLI，不能依赖 RunLoop 定时器；
所以用 show → sleep → 动作 → hide，而不是异步动画。窗口关闭用 `close()`，不复用。

## 后果

- `Mouse.clickAt` / `scrollAt` / `dragAt` 前显示指示环；
- 截图仍只截目标窗口，不会把圆环截进去；
- 不改线协议、不改 MCP 工具参数；`SCU_INDICATOR=0` 可关闭；
- 没有虚拟光标、没有审批、没有“动作预览”文字；
- 多显示器下圆环位置需要更多真实环境验证。

## 相关文档

- [ADR-0020](adr_0020_coordinate_click.md)
- [ADR-0021](adr_0021_scroll_and_drag.md)
- [虚拟指示层](../architecture/virtual_indicator.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
