# 2026-10-22 开源准备

## 范围

把仓库整理到可以公开托管的状态，不加运行时功能。覆盖：git 历史脱敏、对外文档、
社区文件、CLI 帮助、检查入口与 CI、一次性产物清理。**不覆盖**：Developer ID 签名与公证、
预编译二进制发布、浏览器操作面。

## 改变了什么

- **历史脱敏**：全部提交的作者与提交者改为 `SCU contributors <scu@local>`；
  5 个 tag 以同一身份重建（保留原 tag 信息与时间）；`verification/2026-10-21-distribution.md`
  中的两个 Apple Development 证书邮箱与 team id 在**所有历史版本**中替换为
  `redacted@example.invalid` / `redacted_team_id`；重写后 `git gc --prune=now` 清理旧对象。
- **对外文档**：`README.md` 重写（范围改为桌面应用、快速开始、MCP 配置、已实现/未实现边界、
  独立性声明）；新增 `README.en.md`、`CONTRIBUTING.md`、`SECURITY.md`、
  `CODE_OF_CONDUCT.md`、`CHANGELOG.md` 与两个 issue 模板。
- **CLI**：新增 `scu --help` / `-h` / `help` 与 `scu --version` / `-v` / `version`；
  无参数与未知命令的提示指向 `--help`。
- **检查入口**：`scripts/check.sh` 从 4 步改为 5 步，加入格式检查（`format.sh --check`）
  与 `--help`/`--version` 冒烟；全树按 `.swift-format` 重排。
- **CI**：`.github/workflows/check.yml` 只调用 `SCU_SKIP_LIVE=1 scripts/check.sh`
  （macOS runner 上先确保 `swift-format` 可用），与本地入口一致。
- **清理**：删除根目录一次性审计报告 `docs_audit_2026-10-16.md`（历史可追溯）；
  `.gitignore` 增加证书、密钥与本地环境文件。
- **外部观察**：`verification/external-sources.md` 增加法律与归属声明。

## 证据

环境：macOS 开发宿主（辅助功能已授权），Swift 6.4。

格式与构建：

```text
scripts/format.sh
format: 格式化 56 个文件

swift build --disable-sandbox
Build complete!
```

帮助与版本：

```text
scu --help          -> 退出码 0，打印用法、退出码与文档位置
scu --version       -> "scu 0.4.0"，退出码 0
scu bogus           -> 退出码 64，提示用 scu --help 查看用法
scu（无参数）        -> 退出码 64
```

提交前入口（`scripts/check.sh`）：

```text
1/5 文档与代码锚点：结构与链接检查通过（含 mermaid 渲染）
2/5 代码格式：56 个文件通过
3/5 构建：Build complete!
4/5 测试：153 tests in 12 suites passed（1 个既有 known issue：收敛的已知缺口）
5/5 冒烟：help/version、退出码、失败路径、MCP 握手、SIGKILL 回收均通过
```

历史脱敏核对：

```text
git log --all --format='%an <%ae> | %cn <%ce>' | sort -u
SCU contributors <scu@local> | SCU contributors <scu@local>

遍历全部提交的 git grep（原作者名、两个证书邮箱、两个 team id）：无命中
```

## 边界与后续

- 分发包仍是 **ad-hoc 签名、未公证**；本次**没有**发布二进制，README 与 INSTALL 明确要求
  源码构建。公开下载需要 Developer ID Application 证书与公证。
- GitHub 仓库创建后需要启用 Security Advisory（`SECURITY.md` 指向它），
  并可补 issue 模板的 `config.yml` 安全入口。
- 英文文档只覆盖 README；`docs/` 仍是中文。这是有意的范围控制，不声称已完成国际化。
- 未验证：GitHub Actions 上的首次完整运行（本地等价命令已通过）。
