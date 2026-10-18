# SCU 项目 Agent 指令

## 项目定位

SuperComputerUse（SCU）是一个开源桌面自动化服务。当前处于 P0：
已有 Swift 脚手架（`Package.swift`、`Sources/`、`Tests/`），核心机制仍在实现中。
验证内嵌在 P0 里作为出口门槛，见 `docs/decisions/adr_0013_p0_vertical_slice.md`。
项目目标是做对 AI 更好用的桌面操作工具（以 Codex / Grok Computer Use 为参照），
度量方式与"优于"的声称条件见 `docs/decisions/adr_0014_positioning_ai_usability.md`；
在对照可行之前不要在文档里声称"优于"。
构建与测试：`swift build && swift test`。

## 文档协作规则

- 开始项目任务前，先读取 `docs/index.md`，按目录中的读取时机查阅相关文档。
- 当前环境提供 `project-doc` 时使用该技能；未提供时按本项目文档规范继续工作。
- 修改实现时同步相关文档，区分拟实施设计、已实现行为和已验证结果。
- 不因技能未安装或未加载而停止项目任务。

## 工程约定

- 文档库根为 `docs/`，命名遵循小写 `snake_case`。
- 架构决策写入 `docs/decisions/`，不把决策理由散落在代码注释里。
- 设计文档描述**当前已确定的设计意图**；不确定的取舍标为待决，不写成既成事实。
- 参考外部实现时只借鉴设计模式，不复制代码。文档中注明灵感来源。
- **图示用 mermaid 内联在 markdown 中**，不使用外部图片。理由：可 diff、可版本控制、
  人和 agent 都能直接读。
- **提交前运行 `scripts/check.sh`**：文档检查 + `swift build` + `swift test` + 命令行冒烟，
  是唯一的提交前入口。启用 pre-commit：`git config core.hooksPath scripts/hooks`。
  其中的 `scripts/check_docs.sh` 检查命名、H1 唯一性、链接可达性（含锚点）、
  分类路由、ADR 字段、废弃术语、mermaid 语法与代码侧 `@project-doc` 锚点；
  若本机安装了 `mmdc` 则一并做渲染验证。
- **代码锚点**：在实现某份文档所描述的契约的手写入口处，加一行
  `// @project-doc docs/<path>.md#<id>`。`<id>` 必须是目标文档里 `<a id="..."></a>` 的显式 ID，
  不指向标题 slug。改契约时同步改文档与锚点，`check_docs.sh` 会校验锚点有效。
- **宿主相关的事实不要写成机器级事实**：权限（辅助功能、屏幕录制）按宿主进程归属，
  记录时写明在哪个宿主、哪个环境下观察到，并用 `scu permissions` 而不是 `osascript` 判断。
- **引用外部实现的观察时，先在 `verification/external-sources.md` 登记来源**：
  工件路径、版本、SHA-256、采集方法、日期，并把结论落到具体证据。
  文档中只引用来源 ID，不重复证据本身。
  理由：无来源的观察无法复核，也无法判断参考实现更新后结论是否仍成立。
- **采集外部证据时注意方法**：判断"是否调用某 API"用 `nm -u`（`strings` 看不到未定义符号）；
  universal binary 需指定架构（`-arch arm64`）。这两点都曾导致过错误结论。
