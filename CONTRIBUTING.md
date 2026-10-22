# 参与 SCU

感谢你考虑参与。SCU 还处在早期阶段（0.x），接口和行为都可能变；讨论与 issue 同样有价值。

## 环境

- macOS 14.4+，Swift 6.x（Xcode 命令行工具）
- 无第三方依赖，纯 SwiftPM

```bash
swift build
swift test
scripts/check.sh          # 提交前统一入口
git config core.hooksPath scripts/hooks   # 可选：启用 pre-commit
```

真实应用测试需要宿主有辅助功能权限。没有权限时 `scripts/check.sh` 会失败并提示；
CI 用 `SCU_SKIP_LIVE=1` 跳过这部分，本地不必模仿。

## 提交前

`scripts/check.sh` 是唯一的提交前入口，依次做：

1. 文档结构与链接/锚点检查（`scripts/check_docs.sh`，含 mermaid 渲染，装了就查）
2. 代码格式检查（`scripts/format.sh --check`）
3. `swift build`
4. `swift test`
5. CLI 与 MCP 冒烟：退出码、stdout 只含协议消息、被 SIGKILL 后不泄漏临时目录

改过的代码请直接用 `scripts/format.sh <文件…>` 格式化，不要手工调缩进。

## 代码约定

- 分层边界见 `docs/architecture/system_overview.md`：`SCUWire` 不知道 AX，`SCUNative` 不做策略，
  `SCUCore` 不 import AppKit；跨层只通过消息。
- 在手写入口加 `// @project-doc docs/<path>.md#<anchor>`，锚点必须是目标文档的显式 `<a id="…">`。
- 不把决策理由写进代码注释：写 ADR，注释里指向它。
- 新增行为要带测试；无法自动化的验证写进 `verification/YYYY-MM-DD-<主题>.md`，
  区分"成立""不成立""未验证"，不要把设计意图写成已验证结论。

## 文档

- `docs/` 是工程文档库，入口 `docs/index.md`；文件名用小写 `snake_case`。
- 架构取舍写 ADR（`docs/decisions/`），字段齐全；推翻旧决策时新增 ADR，不改写历史。
- 图示用 mermaid 内联，不提交外部图片。
- 引用外部实现的观察前，先在 `verification/external-sources.md` 登记来源（工件、版本、哈希、采集方法、日期）。

## 提交与 PR

提交信息用 `类型: 摘要`，类型取 `feat` / `fix` / `docs` / `test` / `build` / `refactor` / `release`。
一次提交解决一件事；文档与代码的行为变更尽量同一次提交。

PR 描述里写清：

- 改了什么、为什么；
- 跑了哪些检查（`scripts/check.sh` 的结果；跳过 live 测试时说明原因）；
- 如果改了协议或工具面，列出受影响的文档。

不要提交 `dist/`、`.build/`、证书（`.p12`/`.cer`）、密钥或任何本机路径。

## 发布（维护者）

1. 改 `Sources/scu/main.swift` 的 `scuVersion`，同步 `CHANGELOG.md` 与 `docs/index.md` 的「当前阶段」；
2. `scripts/check.sh` 全绿；
3. 打 tag：`git tag -a vX.Y.Z -m "..."`；
4. `scripts/build_dist.sh` 产出通用二进制 zip；有 Developer ID 时同时公证；
5. `scripts/verify_dist.sh dist/scu-X.Y.Z-macos-universal.zip`；
6. GitHub Release：附 zip、`.sha256` 与 `CHANGELOG` 段落。

**未公证的包不得作为对外下载发布**，也不得描述成"已签名发布"。
详见 [docs/operations/distribution.md](docs/operations/distribution.md)。

## 许可证

贡献即同意以 [MIT](LICENSE) 许可发布。
