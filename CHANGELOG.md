# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号遵循语义化版本。
0.x 阶段不保证向后兼容，线协议版本单独记录在
[docs/interfaces/native_wire_protocol.md](docs/interfaces/native_wire_protocol.md)。

## 未发布

### 新增

- `scu --help` / `scu help` 与 `scu --version`；未知命令现在会提示查看帮助。
- 英文 README（`README.en.md`）；`CONTRIBUTING.md`、`SECURITY.md`、本变更记录。
- `scripts/check.sh` 增加格式检查与帮助命令冒烟，共 5 步；CI 改为直接运行同一入口。

### 变更

- 全树按 `.swift-format` 统一格式化，格式检查进入提交前入口与 CI。
- README 重写：明确"桌面应用"范围，补快速开始、MCP 配置与已实现/未实现边界。
- 文档中不再出现构建机的证书身份信息（历史记录同步清理）。
- 移除根目录的一次性文档审计报告（历史保留在 git 中）。

### 修复

- `action_outcome_unknown`：动作完整写出后，等待超时、对端断开、写失败或应答 id 错位统一按"结果未知"
  返回，并立即让令牌失效；读请求仍按 `platform_unavailable` 返回。
- `get_screenshot` 的绑定窗口改为实际截到的窗口，标签只保留落在该窗口内的元素。
- 截图工具如实声明 `readOnlyHint: false`、`idempotentHint: false`（截图前会激活并 raise 窗口）。
- 策略检查集中到 `TargetAuthorizer`，读取/截图/坐标动作/元素动作/`launch_app` 走同一入口。
- 输入超时按字符数计算（30–180 秒），不再固定 30 秒。

## 0.4.0 — 2026-10-21

### 新增

- macOS 通用二进制 zip（arm64 + x86_64）、`build_dist.sh`、`install.sh`、`verify_dist.sh`、`SHA256SUMS`。
- Developer ID 签名与 `notarytool` 公证流水线（可用环境变量启用）。

### 说明

- 已产出的包是 **ad-hoc 签名、未公证**；构建机没有 Developer ID 证书，公证路径未实际执行。

## 0.3.0 — 2026-10-21

### 变更

- `get_ax_state` 默认返回与上次读取的增量差异；`full=true` 取完整元素表（ADR-0028）。

## 0.2.0 — 2026-10-20

### 新增

- `get_screenshot`：截取目标窗口并叠加元素标签。
- `click_at` / `scroll_at` / `drag`：按截图坐标操作，动作前显示指示环，绑定截图窗口。
- `launch_app`：解析应用、策略前置、启动或激活。
- `list_windows`；`get_ax_state(window=…)` 以指定窗口为根读取，元素动作绑定该窗口。
- 连接级应用允许列表 `--allow-app` / `--allow-app-file`（ADR-0024）。

### 修复

- 键盘输入前先 raise 目标窗口，并保留已有选区。

## 0.1.0 — 2026-10-19

### 新增

- 元素表短标签 `[a]` 与 `frame`，四个元素动作工具接受 `label`（ADR-0018）。
- `type_text` / `press_key` / `set_value`。
- `skills/scu/SKILL.md` 与 `skills/scu/INSTALL.md`。
- 网易云音乐（CEF，带无障碍启动参数）上的真实端到端验证。

### 变更

- MCP 只读档完成；code mode 后置到 v2；v1 不做分发。

## 0.0.1-p0 — 2026-10-19

### 新增

- Swift 双进程脚手架：`scu`（MCP/协议）+ `scu-native`（AX/截图/输入），Unix socket 线协议与版本协商。
- 无障碍树读取、文本元素表、快照令牌、按路径定位句柄、`AXPress` 点击与效果摘要、拒绝类目。
- 元素身份 K1–K4 分析与基线（K4 比例判定不成立，不实现句柄注册表）。
- 受控夹具上的令牌、效果、收敛与策略验证；外部观察来源登记。

### 说明

- P0 出口门槛按 ADR-0013 全部满足或判定不适用。
