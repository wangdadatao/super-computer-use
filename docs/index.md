# SCU 工程文档

> Project Doc 根目录。加载 `project-doc` 技能后，每个仓库任务先完整读取本文件，
> 再按「读取时机」进入相关分类。

## 文档范围

本库描述 **SuperComputerUse (SCU)** 的持久工程知识：分层架构、策略与准入、
元素寻址与快照语义、会话与控制租约、动作收敛、协议契约、平台约束，
以及已接受的设计决策及其依据。

**不覆盖**：对外介绍的 [README](../README.md)、逐条实现计划、
以及尚未定案的设计草案（未定案的取舍在相关文档中标注为待定，不单独立档）。

## 当前阶段

**v1 已完成（0.1.0，2026-10-19）：读取、点击、输入、设值；P0 的出口门槛全部满足或判定不适用。**
源码构建交付，**暂不提供分发包**；v1 用平铺 MCP 工具，code mode 后置到 v2。
**新增（未发版）：快照内短标签寻址 + 窗口截图**——元素表输出 `[a]` 与 `frame`，四个元素动作工具（`click`/`type_text`/`press_key`/`set_value`）接受 `label`；`get_screenshot` 截取目标窗口并叠加标签，`click_at` 可按截图坐标点击。已在网易云（CEF）上验证（[ADR-0018](decisions/adr_0018_label_addressing.md)、[ADR-0019](decisions/adr_0019_window_screenshot.md)、[ADR-0020](decisions/adr_0020_coordinate_click.md)）。

仓库有一个 Swift package，
实现了两进程通信、版本协商、权限检测、无障碍树读取、快照令牌与按路径定位句柄、`AXPress` 点击与最小效果摘要、
拒绝类目（`PolicyGate`），以及 MCP stdio 服务（`scu mcp`，见 [MCP 接入面](interfaces/mcp_surface.md)）。
**默认只读，`scu mcp --actions` 才暴露 `click` / `type_text` / `press_key` / `set_value`。**
**未实现**：句柄注册表（跨快照延续，按 K4 验证结果不实现）、滚动与拖拽、应用启动、审批与租约、指示层、code mode。
验证状态：令牌与效果摘要在受控夹具上满足（误拒 0/8；每次改值点击后都要重读）；输入、按键与设值在夹具与网易云（CEF，带无障碍启动参数）上成立（其他真实应用与输入法未验证）；收敛有已知缺口、不列为出口门槛；策略在夹具上满足；身份 K4 按冻结规则不成立；经宿主调用动作仍未验证。见[测试策略](operations/testing.md#当前状态)。
v2 候选范围（截图+坐标、滚动/拖拽、应用启动、审批、`batch` 等）见 [ADR-0013 的 v2 候选](decisions/adr_0013_p0_vertical_slice.md#v2_candidates_2026_10_19)，
接口演进顺序见 [ADR-0002 的追加记录](decisions/adr_0002_code_mode_surface.md)。
范围与出口门槛见 [ADR-0013](decisions/adr_0013_p0_vertical_slice.md)，
已实现内容见[本地环境](operations/local_setup.md)。
给 agent 的使用指导（何时用、核心循环、动作选择、错误处理）在 [skills/scu/SKILL.md](../skills/scu/SKILL.md)。

除「已实现」一节列出的内容外，文档描述的都是已确定的设计意图，不是已验证的系统行为。

**未定项散落在各文档内就地标注**，不集中登记。检索方式：

| 标记 | 含义 | 典型位置 |
| --- | --- | --- |
| 「待验证」 | 假设尚未证实或推翻 | [元素身份](architecture/element_identity.md)、[测试策略](operations/testing.md) |
| 「未定项」「待定」 | 有意留到实现时决定 | [元素寻址](interfaces/element_addressing.md)、[动作收敛](architecture/action_convergence.md) |
| 「风险」 | 已知可能失败的取舍 | 各 ADR、[虚拟指示层](architecture/virtual_indicator.md) |

全文检索关键词：`待验证`、`未定项`、`待定`、`风险`、`待实现`。

## 分类

- [架构](architecture/index.md)：四层分层、策略与准入、会话与租约、元素身份、快照生命周期、动作收敛、应用知识、虚拟指示层。读取时机：改协议语义、寻址策略、进程边界或用户可见行为时。
- [领域](domains/index.md)：核心术语与失效模型。读取时机：确认某个概念在 SCU 里的确切含义时。
- [接口](interfaces/index.md)：协议面、目标发现与绑定、元素寻址格式、编辑类操作语义。读取时机：增删接口、写 agent 集成或客户端时。
- [运维](operations/index.md)：本地开发环境、macOS 权限、测试策略。读取时机：搭建环境、排障、处理权限问题时。
- [决策](decisions/index.md)：20 条 ADR，含对外部实现取舍的分析结论。读取时机：质疑「为什么这样设计」或要推翻某个既有选择时。
