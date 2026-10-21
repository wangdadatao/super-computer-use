# ADR-0030 浏览器操作面通过适配器接入，不把扩展塞进核心

- **状态**：已接受（规划，2026-10-21；未实现）
- **日期**：2026-10-21

<a id="browser_surface_decision"></a>

## 背景

Codex 的 Browser 插件能在用户已打开的 Edge 标签页里按 URL 选中目标，
claim 后使用 DOM/Playwright 风格 API 操作。这条链路由浏览器扩展、native messaging host、
tab claim 和 `chrome.debugger`/CDP 组成，和 Codex Computer Use 是两条独立路径。

Grok Bot 0.71.2 的静态分析没有找到同类扩展/native host/tab claim 链路，
只有通用 CUA 与 AX/截图；这不能证明它没有云端或未启用的浏览器路径，但至少不支持
“照搬扩展”是唯一解。

SCU 目前只有桌面操作面：AX、输入、截图和坐标。它可以操作浏览器窗口，
但无法枚举页面标签页、读取 DOM 或继承用户登录态。用户希望把 SCU 做成
“super computer use”，于是出现一个自然问题：是否要照搬 Codex 的浏览器扩展。

同时，[ADR-0010](adr_0010_ui_automation_only.md) 明确排除了 SCU 核心内嵌
“浏览器扩展的安装与集成”。这条边界不能因为一个功能想法被悄悄绕过。

## 外部观察来源

本文关于 Codex Browser 插件与 Grok Bot 的观察来自 `CU-BROWSER`、`CU-BROWSER-EXT`、`GB-ASAR`，
工件版本、SHA-256、采集方法与证据映射见
[verification/external-sources.md](../../verification/external-sources.md) 的「浏览器操作面」一节。
结论是静态分析与本机运行时进程关系，不是对“具体 claim 了哪个标签页”的抓包验证。

## 决策

### 1. 用操作面模型，而不是把浏览器塞进 AX 层

SCU 面对三个操作面：

- **桌面**：原生应用、窗口、菜单、系统对话框；
- **浏览器（自有上下文）**：可复现的网页任务，Playwright MCP 是代表；
- **浏览器（用户上下文）**：用户现有标签页和登录态，扩展/CDP 是代表。

三者共享会话、令牌、效果和策略的**语义**，但使用各自的句柄空间和传输。
编排层负责路由和跨面流程，不是第四个操作面。

### 2. 先做适配器，后做扩展

浏览器能力通过 `BrowserAdapter` 进入编排层：

1. 先接 Playwright MCP 或 CDP endpoint；
2. 需要“用户现有标签页”时，再接扩展 + native host；
3. 扩展是适配器后端，不是 SCU 核心的一部分。

这样可以在不发布浏览器扩展的情况下，先验证目标枚举、令牌、效果和跨面流程。

### 3. SCU 核心继续只做 UI 自动化

ADR-0010 继续有效：SCU 核心不负责扩展商店发布、native host 安装、浏览器配置修改。
浏览器适配器可以是外部服务、外部 MCP 或用户安装的组件。若将来 SCU 自己发布扩展，
必须新写 ADR 复核 ADR-0010，而不是把它当成一个普通工具增量。

### 4. 浏览器动作需要独立的策略和效果

浏览器适配器不能复用桌面应用允许列表作为完整策略：

- 应用允许列表回答“能不能操作这个浏览器”；
- 还需要 origin 级允许列表，回答“能不能在这个站点提交、上传或读取敏感内容”；
- 浏览器 effect 使用 URL/title/DOM/AX diff 与截图 diff，不复用 AX 树变化字段；
- 浏览器令牌和桌面令牌不能互换。

### 5. 路由优先于聚合

网页内容优先走浏览器操作面；浏览器外壳和原生应用走桌面操作面。
不把 Playwright MCP 的全部工具原样代理进 SCU 的 MCP 服务；编排层可以分别调用两个服务。

## 取舍

**接受了“先把浏览器交给外部工具”。** 这会让 SCU 自己暂时不能 claim 用户标签页，
但避免了扩展发布、商店审核、native host 安装和高权限扩展的维护成本。

**接受了 CDP 先行的限制。** CDP 通常要求浏览器以调试端口启动，可能需要重启；
扩展/native host 才能做到“无感接管当前标签页”。先用 CDP 验证价值，再决定是否值得做扩展。

**接受了跨面流程的额外编排。** 浏览器和桌面各有令牌，跨面任务需要在编排层重新绑定目标，
不能靠一个全局句柄贯穿两个操作面。

**没有解决“用户现有标签页”的最终体验。** 这是一项明确的产品决策，不是实现细节；
需要真实任务数据证明它比“新开浏览器上下文 + 登录”更值得。

## 后果

- 新增[操作面模型](../architecture/surface_model.md)；
- 不新增线协议、MCP 工具或浏览器扩展；当前行为不变；
- `target_discovery.md` 的页面发现仍是设计，不是已实现；
- 后续实现从适配器接口和 Playwright MCP/CDP 后端开始；
- 如果做扩展，需要新的分发、签名、隐私与安全评审。

## 相关文档

- [操作面模型](../architecture/surface_model.md)
- [目标发现与绑定](../interfaces/target_discovery.md)
- [系统总览](../architecture/system_overview.md)
- [ADR-0010 范围限定为 UI 自动化](adr_0010_ui_automation_only.md)
- [ADR-0024 连接级应用允许列表](adr_0024_app_authorization.md)
- [分发](../operations/distribution.md)
