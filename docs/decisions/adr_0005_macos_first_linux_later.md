# ADR-0005 平台顺序：macOS 优先，Linux 后续

- **状态**：已接受
- **日期**：2026-10-16

## 背景

桌面自动化的平台实现差异很大，三平台的成熟度和可用技术栈都不相同。
需要在首版确定支持范围。

已知的平台能力对照：

| 能力 | macOS | Linux | Windows |
| --- | --- | --- | --- |
| 无障碍树 | AXUIElement，系统原生，质量高 | AT-SPI2，取决于工具包 | UI Automation |
| 事件注入 | CGEvent | XTest（X11）/ libinput（Wayland） | SendInput |
| 屏幕捕获 | ScreenCaptureKit | PipeWire / X11 | Desktop Duplication |
| 权限模型 | 辅助功能 + 屏幕录制，按可执行文件授予 | 通常无权限门槛 | 通常无权限门槛 |

Linux 侧的特殊困难：X11 与 Wayland 的注入机制不同，
无障碍树质量在 GTK / Qt 应用之间差异明显，且无障碍服务可能未启动。

## 决策

**首版只支持 macOS。架构上保留跨平台抽象，但不在首版实现 Linux。**

- 协议层面向平台无关的目标接口工作，不出现平台判断
- 平台差异全部隔离在原生层
- Linux（Ubuntu）列入规划，不设时间表
- Windows 暂不考虑

## 取舍

**放弃了首版的覆盖面。** macOS only 意味着 Linux 用户无法使用，
即使协议层的设计本身是平台无关的。

**接受了跨平台抽象的先期成本。** 在只有单一平台的情况下维护抽象层
是一种投资——它可能抽象错方向，而错误只有在真正实现第二个平台时
才会暴露。

做出这个取舍的原因：P0 的目标是验证协议语义
（元素身份、令牌失效、效果回报），这些与平台无关。
在一个平台上把这些想清楚，比在两个平台上同时铺开更有价值。

## 后果

- 元素身份算法需要平台提供的字段，macOS 侧的字段选择
  在 Linux 侧不一定有对应物（例如显式标识符在 AT-SPI2 里的对应关系待确认）
- 跨平台抽象的正确性无法在首版验证，属于已知风险
- 与浏览器标签页交互的部分（页面目标）本身是跨平台的，
  不受此决策影响

## 追加记录（2026-10-22）

<a id="addendum_2026_10_22"></a>

0.4.x 的代码复核确认：决策本身不变（macOS 优先、保留跨平台抽象），但**实现尚未达到“平台差异全部隔离在原生层”**。
`SCUCore` 仍直接使用三处 macOS API：

- `AppLauncher`：AppKit `NSWorkspace` + `/usr/bin/open` 启动应用；
- `PolicyGate`：Darwin `proc_pidinfo` 读取 SCU 自身的宿主祖先链；
- `ScreenshotDiff`：CoreGraphics/ImageIO 做截图像素 diff。

另外，代码里尚无文中所说的平台无关 `Target` 协议；`DesktopSession` 仍直接绑定 `pid` / `windowTitle` / `AXNode`。
后果是“移植 Linux 只需替换原生进程”目前不成立。移植前需要先把上述三处移到平台侧（或改走线协议请求），
并在浏览器适配器之前抽出令牌/效果/授权接缝。此次只修文档与代码不一致，不移动这些实现。

## 相关文档

- [系统总览](../architecture/system_overview.md)
- [本地环境](../operations/local_setup.md)
