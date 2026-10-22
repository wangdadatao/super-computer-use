# 验证产物

本目录存放**证据**，不属于 Project Doc 文档库（`docs/`）。
文档库描述当前结论，本目录存放得出结论所依据的样本与记录。

## 目录结构

```
verification/
  samples/                    原始样本（无障碍树导出、截图元数据等）；目前尚未使用，该目录不存在
  YYYY-MM-DD-<主题>.md        单次验证或测量的记录（以主题命名，如 `2026-10-18-identity-k4.md`）
```

## 为什么与文档库分开

样本是数据，工程知识是结论。两者的更新周期和读者都不同：

- 样本体积大、随采集时间累积、多数时候只被引用不被阅读
- 结论应当被阅读、被引用、随代码演进维护

混在一起会让文档库充满无法维护的二进制与数据集。

## 内容

| 文件 | 内容 |
| --- | --- |
| `external-sources.md` | 外部实现观察的来源清单：工件标识、采集方法、结论到证据的映射、复核步骤 |
| `samples/` | 采集到的原始样本（尚未使用） |
| `2026-10-16-baseline-identity.md` | 元素身份各档位分布的**基线记录**（不是验证结论） |
| `2026-10-17-read-latency.md` | 读树耗时：逐属性读取与批量读取的对比（性能测量，不是验证结论） |
| `2026-10-18-identity-k4.md` | 元素身份 K4 比例的正式验证（3 个判定样本，结论不成立，限定见文内） |
| `2026-10-18-fixture-validation.md` | 夹具应用上的令牌、动作效果、收敛、策略验证：哪些成立、哪些是缺口 |
| `2026-10-19-token-reject-rate.md` | 令牌误拒率与重读成本：A/B 误拒 0/8，C 保守拒绝 8/8，D 改值点击后令牌失效 8/8 |
| `2026-10-19-real-app-netease.md` | 真实第三方应用端到端（网易云 CEF）：正常启动无 AX，带 `--force-renderer-accessibility` 后读/输入/点击/播放核实成立 |
| `2026-10-20-approval-triggers.md` | Grok Bot 与 Codex Computer Use 的审批触发：应用级运行时审批与动作级提示词的区分 |
| `2026-10-20-window-root.md` | TextEdit 两窗口上的 `list_windows`、窗口根读取与跨窗口 `set_value` 实测 |
| `2026-10-20-real-tasks.md` | 真实任务第一轮：TextEdit 编辑/保存/多窗口隔离、计算器、访达新建文件夹（部分通过）、Edge 链接、TextEdit 撤销（失败） |
| `2026-10-21-distribution.md` | macOS 通用二进制 zip 的构建、ad-hoc 签名、校验和、解压后 MCP 冒烟与安装脚本验证；未公证 |
| `2026-10-22-architecture-fixes.md` | 架构修复轮：输入超时、截图标注、坐标绑定、动作超时、策略集中化、文件拆分、CI/许可证；构建与测试证据 |
| `2026-10-22-open-source-prep.md` | 开源准备：git 历史脱敏、中英 README 与社区文件、`--help`、5 步检查入口与 CI、一次性产物清理 |

## 结论文件格式

见 [docs/operations/testing.md](../docs/operations/testing.md) 的
「验证产物与标记约定」一节。

## 当前状态

**v2 已收口（0.2.0，2026-10-20）；0.3.0（默认差异）；当前 0.4.0（分发）；P0 的出口门槛全部满足或判定不适用。** 十二份记录：元素身份基线
（[2026-10-16](2026-10-16-baseline-identity.md)，不是结论）、读树耗时
（[2026-10-17](2026-10-17-read-latency.md)）、夹具验证（[2026-10-18](2026-10-18-fixture-validation.md)）、
K4 正式验证（[2026-10-18](2026-10-18-identity-k4.md)，不成立）、令牌误拒与重读成本
（[2026-10-19](2026-10-19-token-reject-rate.md)，A/B 0/8、C 8/8、D 8/8）、
真实应用端到端（[2026-10-19](2026-10-19-real-app-netease.md)，网易云 CEF）、审批触发
（[2026-10-20](2026-10-20-approval-triggers.md)，Grok/Codex 静态分析）、窗口列表与窗口根
（[2026-10-20](2026-10-20-window-root.md)，TextEdit 两窗口）、真实任务第一轮
（[2026-10-20](2026-10-20-real-tasks.md)，6 个任务：5 个通过、1 个部分通过）、分发包
（[2026-10-21](2026-10-21-distribution.md)，ad-hoc 通用 zip，未公证）、架构修复轮
（[2026-10-22](2026-10-22-architecture-fixes.md)，无新功能；153 个测试与文档/冒烟检查）、开源准备
（[2026-10-22](2026-10-22-open-source-prep.md)，历史脱敏、文档与检查入口；不含功能变更）。
指示层隔离（需要屏幕录制）等 P0 之外的假设仍未验证。
门槛见 [ADR-0013](../docs/decisions/adr_0013_p0_vertical_slice.md)；
权限状态见 [docs/operations/permissions.md](../docs/operations/permissions.md)。
真实第三方应用上的 `click` 与宿主接入仍是未验证项，见
[MCP 接入面](../docs/interfaces/mcp_surface.md#未验证项)。
