# SuperComputerUse (SCU)

用 MCP 让 AI agent 操作 macOS 应用界面：读无障碍树、执行动作，并回报动作是否真的生效。

[English](README.en.md) · [工程文档](docs/index.md) · [Agent 使用指导](skills/scu/SKILL.md)

## 它解决什么

现有桌面自动化能"点到"东西，但普遍不能回答一个更基本的问题：**点对了吗？**

具体表现为三类静默失败：

- **寻址失效**：上一轮拿到的元素编号在这一轮已经指向了别的控件，但调用方不知道。
- **动作落空**：点击被投递了，但界面没有响应，或者焦点被别的窗口抢走。
- **无人核对**：没有任何环节检查"我以为发生的事"和"实际发生的事"是否一致。

SCU 把这三件事从"调用方自律"提升为协议行为：每次读取状态都带快照令牌，令牌失效时服务端会明确拒绝；
每次动作都回报可机器核对的效果摘要，要求调用方在动作后重读。

## 现在能做什么

| 能做 | 不能做 |
| --- | --- |
| 读取正在运行的 macOS 应用的无障碍树（文本元素表） | 网页 DOM / 标签页语义（浏览器操作面尚未实现） |
| 启动、激活应用；枚举窗口并按窗口读取 | 右键、长按、输入法输入（未验证） |
| 点击元素（`AXPress`）、逐字输入、发送按键、直接设值 | 逐次审批、租约、审计日志 |
| 截取目标窗口并叠加元素标签，按截图坐标点击 / 滚动 / 拖拽 | code mode（`js` 工具面） |
| 动作后返回效果摘要，说明界面是否变化、是否疑似空操作 | Linux / Windows（规划中，未实现） |

**默认只读**：`scu mcp` 只暴露读取类工具；点击、输入、按键、设值需要 `scu mcp --actions`。
还可以用连接级应用允许列表把服务限制在指定应用上（`--allow-app`）。

## 快速开始

要求：macOS 14.4+、Swift 6.x（Xcode 命令行工具即可）。没有第三方依赖。

```bash
git clone <你的仓库地址> SuperComputerUse
cd SuperComputerUse
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
mkdir -p ~/bin/scu
cp "$BIN/scu" "$BIN/scu-native" ~/bin/scu/
~/bin/scu/scu permissions     # 退出码 2 表示还没有辅助功能权限
```

`scu` 会在自己所在目录找 `scu-native`，两者必须放在一起。授权步骤（必须在系统设置里由人完成）
见 [权限](docs/operations/permissions.md)。

### 接到 MCP 宿主

Cursor（`~/.cursor/mcp.json`）或 Claude Desktop 等宿主用同样的结构：

```json
{
  "mcpServers": {
    "scu": {
      "command": "/Users/<用户名>/bin/scu/scu",
      "args": ["mcp", "--actions", "--allow-app", "com.apple.TextEdit"]
    }
  }
}
```

只读试用去掉 `--actions`。完整安装与自检步骤（含宿主配置、授权、排错）见
[skills/scu/INSTALL.md](skills/scu/INSTALL.md)。

### 第一次读取

读取结果是一张带快照内短标签的文本元素表，动作工具用这些标签寻址：

```text
token: s3f2a.7
[a] [AXButton#3] "返回" id="go-back" frame=(10,50,24,24)
[b] [AXTextField#4] "地址与搜索" value="example.com" frame=(50,50,300,28)
```

对 `[b]` 设值后再读一次，默认只返回与上次读取的差异（`full=true` 取完整表）。
令牌在界面变化后失效，服务端返回 `stale_token`，调用方必须重读——这是刻意的设计，不是错误。

命令行诊断（不经过 MCP）：

```bash
scu apps                          # 列出运行中的应用与 pid
scu windows --pid <pid>           # 多窗口时先看标题
scu dump --pid <pid> --window "窗口标题"
scu --help
```

## 设计要点

- **无障碍树优先，坐标兜底**：读不到语义时才截图按坐标操作；坐标动作会绑定截图时的窗口。
- **位置句柄 + 快照令牌**：元素引用只在一次读取内有效，跨快照沿用句柄的注册表**没有实现**（验证未通过，见
  [元素身份](docs/architecture/element_identity.md)）。
- **默认拒绝危险类目**：终端、脚本运行器、密码管理器、系统设置等不进入动作目标
  （[策略与审批](docs/architecture/policy_layer.md)）。
- **协议层与原生层分离**：`scu`（MCP/协议）启动 `scu-native`（AX/截图/输入），两进程通过本地 socket 通信。

设计取舍与代价记录在 [决策记录](docs/decisions/index.md)（30 条 ADR），
每一条参考实现相关的观察都在 [verification/external-sources.md](verification/external-sources.md) 登记了来源。

## 项目状态

**0.4.0（2026-10-21），早期版本。** 源码构建可用；分发包是 **ad-hoc 签名、未公证**，
公开下载前需要 Developer ID 证书与公证，因此本仓库暂不提供预编译二进制。

已验证的范围：

- 153 个自动化测试；文档结构、链接、锚点与 mermaid 渲染检查；
- 令牌与效果摘要在受控夹具上成立（误拒 0/8；改值点击后必须重读）；
- 网易云音乐（CEF）、TextEdit 多窗口、计算器、Edge 窗口上的真实操作；
- 真实任务集 6 个：5 个通过、1 个部分通过（访达内联重命名）。

已知缺口：

- 浏览器操作面（Playwright MCP / CDP 适配器）仅规划，未实现；
- 收敛判定是启发式初值，可能错过两秒后的变化；
- 元素身份的 K4 路线验证不成立，不做跨快照句柄；
- 逐次审批、租约、code mode、OCR 未实现；
- 经宿主（Cursor/Claude）实际调用动作的链路未验证。

完整清单与证据见 [docs/index.md 的「当前阶段」](docs/index.md) 与 [verification/](verification/README.md)。
除标注为已实现的行为外，文档描述的是设计意图，不是已验证的系统行为。

## 文档

- [工程文档入口](docs/index.md)：架构、领域、接口、运维、决策。
- [Agent 使用指导](skills/scu/SKILL.md)：何时用、读 → 一个动作 → 重读、错误处理。
- [分发](docs/operations/distribution.md)：打包、签名、公证与安装。
- [测试策略](docs/operations/testing.md)：哪些验证在 CI 跑、哪些需要人或权限。

## 参与

- 提交前运行 `scripts/check.sh`（文档 + 格式 + 构建 + 测试 + CLI/MCP 冒烟）；
- 开发约定、文档规范与发布流程见 [CONTRIBUTING.md](CONTRIBUTING.md)；
- 安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要开公开 issue；
- 版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)。

## 独立性声明

SCU 是独立项目，与 OpenAI、xAI、Anysphere 及其产品没有关联，也没有得到它们的背书。
文档中提到的 Codex Computer Use、Grok Bot 等名称归各自所有者，仅用于标注设计参照来源；
相关结论来自对公开分发工件的外部观察，没有复制其代码。
