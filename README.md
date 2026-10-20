# SuperComputerUse (SCU)

让 AI agent 可靠地操作桌面应用和浏览器。

SCU 是一个本地桌面自动化服务。它在 agent 与操作系统的无障碍（Accessibility）、
图像捕获和输入事件系统之间，提供一层**可验证**的协议：agent 声明要操作哪个元素，
SCU 负责寻址、执行，并回报这次动作是否真的产生了预期效果。

## 外部观察来源

本文涉及对两套已发布实现的观察结论。来源、具体证据与复核方法见
[verification/external-sources.md](verification/external-sources.md)。

## 它想解决什么

现有的桌面自动化方案能"点到"东西，但普遍不能回答一个更基本的问题：**点对了吗？**

具体表现为三类静默失败：

- **寻址失效**：上一轮拿到的元素编号在这一轮已经指向了别的控件，但调用方不知道。
- **动作落空**：点击被投递了，但界面没有响应，或者焦点被别的窗口抢走。
- **无人核对**：没有任何环节检查"我以为发生的事"和"实际发生的事"是否一致。

SCU 把这三个问题从"调用方自律"提升为**协议保证**：每次读取状态都带版本令牌，
每次动作都回报可机器核对的效果摘要。

## 定位

SCU 的目标是做一个**对 AI 更好用**的桌面操作工具：以 Codex Computer Use 与 Grok Computer Use 为参照，
结合两者的长处，并补上两者都缺的动作效果回报。好用的评判者是 AI，不是人。

**目前没有任何"优于"两者的证据**：对两者的了解只来自程序工件的观察，
也没有任务集和度量数据。度量方式与"优于"的声称条件见 [ADR-0014](docs/decisions/adr_0014_positioning_ai_usability.md)。

## 设计出发点

SCU 的设计建立在对两套已发布实现的观察之上：OpenAI 的 Codex Computer Use
和 xAI / Anysphere 的 Grok Bot Computer Use。两者独立收敛到了同一套核心技术选择
（无障碍树优先、坐标兜底、文本化元素表、IPC 分离的原生服务进程），
也各自留下了不同的未解问题。

SCU 采纳其中已被验证的模式，并针对未解问题引入新的机制：

- **稳定元素身份**：把元素引用从位置寻址改为内容寻址，使引用能跨快照使用
- **收敛判定**：区分“没有变化”与“还没稳定”，而不是用固定延时猜测
- **协议级失效契约**：令牌由服务端签发并主动上报失效，不依赖调用方自律
- **策略层独立成层**：把动作准入从提示词约束提升为代码强制

逐条理由记录在[决策记录](docs/decisions/index.md)。

## 平台范围

- **当前**：macOS 14.4+
- **规划**：Linux（Ubuntu，通过 AT-SPI2）
- **暂不考虑**：Windows

## 范围边界

SCU **只做 UI 自动化**。不提供日历、消息、系统活动录制等
绕过界面的数据访问能力，即使它们看起来更快捷。
理由：SCU 要保证的正是“用户能看见发生了什么”。
详见 [ADR-0010](docs/decisions/adr_0010_ui_automation_only.md)。

## 当前状态

**v1 已完成（0.1.0，2026-10-19）。** 源码构建交付，暂不提供分发包；MCP 用平铺工具，code mode 后置到 v2。
已实现：两进程通信、版本协商、权限检测、无障碍树读取与导出、
快照令牌与按路径定位句柄、`AXPress` 点击、输入与设值、最小效果摘要、拒绝类目、MCP 服务（默认只读，`--actions` 才暴露动作）。
v1 功能点：读取、点击、输入、设值；元素表带快照内短标签与 `frame`，动作工具接受 `label`；
窗口截图（`get_screenshot`）带标签叠加；`launch_app` 启动应用；动作档可用 `--allow-app` 配置连接级应用允许列表；
`list_windows` 枚举窗口，`get_ax_state(window=...)` 以指定窗口为根读树，截图、坐标动作与元素动作都绑定该窗口；
`click_at` / `scroll_at` / `drag` 按截图坐标操作（会激活窗口、移动光标）；
未实现：句柄注册表、逐次审批与租约、完整指示层/虚拟光标。

**关键机制的验证**：令牌与效果摘要在受控夹具上满足（误拒 0/8；每次改值点击后都要重读）；
输入、按键、设值在网易云音乐（CEF，带无障碍启动参数）上完成了一次真实端到端验证（搜索并播放）；
收敛判定是启发式初值（0.2 秒轮询、连续两次一致、3 秒上限），已知会错过两秒后的变化，
按 ADR-0013 的 2026-10-19 追加记录不列为 P0 门槛；
元素身份的 K4 比例按冻结规则不成立，因此不做句柄注册表。
验证内嵌在 P0 中，作为完成门槛，见
[ADR-0013](docs/decisions/adr_0013_p0_vertical_slice.md)，结果见 [verification/](verification/README.md)。

```bash
swift build && swift test
.build/out/Products/Debug/scu apps               # 查 pid
.build/out/Products/Debug/scu windows --pid <pid>  # 多窗口时先看标题
.build/out/Products/Debug/scu dump --pid <pid> [--window <标题>]
```

构建与命令说明见[本地环境](docs/operations/local_setup.md)。
除其中「当前已实现」列出的内容外，请把文档读作设计意图，而不是已验证的系统行为。

## 给 agent 用

两份给 agent 的文档：

- [skills/scu/INSTALL.md](skills/scu/INSTALL.md)：安装、宿主配置、授权与自检（授权必须由人完成）
- [skills/scu/SKILL.md](skills/scu/SKILL.md)：何时用、核心循环（读 → 一个动作 → 重读）、动作选择、效果摘要与错误处理

动作档（`--actions`）才有 `click` / `click_at` / `type_text` / `press_key` / `set_value`。

## 文档

工程文档入口：[docs/index.md](docs/index.md)。它按分类路由到架构、领域、接口、运维和决策。

其中值得先读的三处：

- [决策记录](docs/decisions/index.md)：15 条取舍的背景与代价，包括对本项目有直接影响的两套外部实现分析。
- [元素身份](docs/architecture/element_identity.md)：SCU 相对现有方案的核心差异点。
- [策略与审批](docs/architecture/policy_layer.md)：动作准入机制，SCU 的安全边界。
