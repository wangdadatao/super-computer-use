# ADR-0019 窗口截图与标签叠加

- **状态**：已接受（实验性）
- **日期**：2026-10-20

## 背景

ADR-0018 让元素有了快照内短标签和 `frame`，但模型仍然只能读文本。两个问题没有解决：

1. **看不到布局**：标签是 `[a]`，模型不知道它在窗口的哪个位置，难以判断“点这个会不会点到别处”；
2. **没有视觉兜底**：不暴露 AX 的应用连标签都没有，只能靠截图和坐标。

真实应用（网易云，CEF）已经证明 AX + 标签可用；但截图是后续坐标动作、指示层与视觉验证的基础。
本 ADR 只做**截图与叠加**，不做坐标点击。

## 决策

### 1. 只截目标窗口，不截整屏

- 按 pid 找 `windowLayer == 0`、on-screen、面积最大的窗口；
- 窗口截图不含其他应用，减少隐私暴露与模型干扰；
- 图像宽度上限 1600 像素；`scale = 图像像素 / 窗口点`，Retina 与缩放下仍能换算。

### 2. 返回 PNG、尺寸、scale 与窗口全局 frame

```text
WindowCapture {
  png, width, height, scale,
  windowFrame: {x, y, width, height},  // 全局屏幕点，可为负（副屏）
  windowTitle
}
```

元素 `frame` 是全局屏幕点；图像坐标 = `(frame - windowFrame) * scale`。
负的原点、Retina 2x、窗口移动都按同一公式处理。

### 3. `get_screenshot(token)` 绑定快照

- 只接受 `get_ax_state` 签发的令牌；令牌失效则拒绝；
- 从快照里取全部标签，按窗口裁剪后叠加；
- 返回 `screenshot_id`，绑定 `token + windowFrame + scale`，供后续坐标动作判断过期；
- 文本元素表仍是权威：徽标太小、重叠、被裁掉时，模型应按标签选择，不靠图猜。

### 4. 截图是独立权限，失败要分类

屏幕录制与辅助功能是两项独立授权，按宿主进程归属：

- 未授予时返回 `system_permission_missing`，文案明确指向“屏幕录制”，不误导为辅助功能；
- 不自动弹系统授权框；由用户决定。

### 5. 不持久化截图

截图只经 MCP 返回给调用方，不写日志、不落盘、不进入元素表。
截图可能包含密码、聊天、邮件等敏感内容；持久化需要单独的同意与保留策略。

## 取舍

**接受了“最大窗口”的启发式。** 多窗口应用可能选错窗口；v2 先不做窗口选择器，
真实遇到时再加参数（window id / title）。

**接受了 1600 像素的上限。** 小字号可能变糊；`scale` 与原始窗口尺寸都返回，
需要更清楚时可以未来加局部放大/crop。当前优先控制 MCP 单帧大小。

**接受了徽标可能遮挡内容。** 标签画在元素左上角；密集 UI 会重叠。文本清单是兜底，
不把“图上没看清”当成“元素不存在”。

**没有做坐标点击。** `screenshot_id` 已经为它留好绑定；`click_at` 是下一步，
需要单独决定鼠标事件投递方式（postToPid / 真实光标 / 虚拟光标）。

## 后果

- 线协议升到 v6：新增 `captureWindow` 请求与 `windowCapture` 应答；
- MCP 新增只读工具 `get_screenshot`，返回文本元数据 + PNG 图像内容；
- 新增 CoreGraphics/CoreText 叠加，避免 NSImage 在无 GUI 会话里的 TIFF 失败；
- 后续 `click_at` 复用 `screenshot_id` 与坐标换算；
- 截图权限、隐私与窗口选择写入已知限制。

## 相关文档

- [原生层线协议](../interfaces/native_wire_protocol.md)
- [MCP 接入面](../interfaces/mcp_surface.md)
- [ADR-0018](adr_0018_label_addressing.md)
- [真实应用验证](../../verification/2026-10-19-real-app-netease.md)
