# 变更记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本号遵循语义化版本。
0.x 阶段不保证向后兼容，线协议版本单独记录在
[docs/interfaces/native_wire_protocol.md](docs/interfaces/native_wire_protocol.md)。

## Unreleased

### 新增

- **动作效果的验证三值化。** `click` / `type_text` / `press_key` / `set_value` 与坐标动作
  （`click_at` / `scroll_at` / `drag`）的效果摘要新增 `verificationState`
  （`verified` / `refuted` / `unknown`）与 `verificationReason`；0.5.1 的 `verified` / `verifiedBy`
  原样保留，恒等于 `verificationState == .verified`，老客户端不受影响。线协议不变。
  - `refuted` 是"**声明的后置条件为假**"，只否定那一条可读谓词，不证明界面外没有副作用。
  - `unknown` 是"判不了"，**不等于成功**；原因码：`observation_failed`、`tree_truncated`、
    `screenshot_unavailable`、`baseline_unavailable`、`geometry_changed`、`no_readable_postcondition`、
    `target_not_visible`、`not_converged`。
  - 非文本落点的坐标点击、`scroll_at`、`drag` 没有可读的后置条件，恒为 `unknown` +
    `no_readable_postcondition`；要 `verified` 请用元素寻址的 `click`。
  - 效果行改为 `effect: delivered=… verification=… verificationReason=… verified=…`；
    refuted / unknown 各有一句说明，取代原来笼统的"是否命中未验证"。
  - `noOpSuspected` 降级为观察事实，不参与判定；观察到后置条件时恒为 false。

- **窗口标题歧义拒绝（`ambiguous_reference`）。** 标题被当作窗口身份时，去重后匹配两个以上
  窗口返回 `ambiguous_reference`（`retry=after_disambiguation`，零动作），候选写在 `message`；
  恰好一个不变，零个仍是 `window_not_found`。读树、截图与元素动作的窗口根三处入口统一。
  观测摘要的标题回退遇歧义只让 `treeChanged=unknown`，不抛错。

- **键盘动作的焦点门禁（`focus_not_established`）。** `type_text` / `press_key` 投递前读应用级
  `AXFocusedUIElement`，必须与目标元素一致（`press_key` 另要求目标窗口是 `AXFocusedWindow`）；
  不一致或读不到就抛错，`keys_posted=0`，一个按键都不发。读回最多 600ms，不重试 set。

### 变更

- **线协议 14：`failure.error` 增加可选 `details`。** `scu` 与 `scu-native` 必须成对替换；
  为 nil 时该键不出现在 JSON 里。`details` 只给 `stale_geometry`、`ambiguous_reference`、
  `focus_not_established` 三个码用。
- **`stale_geometry` 带 `details.reason`。** 坐标路径按固定顺序只报第一个失败项：
  `capture_unknown`、`capture_token_mismatch`、`window_gone`（带 `bound_by`）、
  `window_replaced`、`frame_changed`、`scale_changed`、`size_changed`（后四项带 `expected`/`actual`）。
  原生层的 `window_not_found` 在坐标动作的复核点翻成 `stale_geometry/window_gone`；
  `get_screenshot` 仍报 `window_not_found`。MCP 与 CLI 在错误首行后追加 `details: k=v` 一行。

## 0.5.1 — 2026-11-04

### 修复

- **窗口几何变化不再连坐选区判据。** `geometry_changed` 只说明截图不可比，此前却当成
  坐标判据的全局门禁：窗口挪动或缩放时，能确认的 `selection_changed` 与能确认的
  “选区没变”都被降级成 `unknown`。现在这条门禁只作用于像素判据（`caret_pixels`），
  选区读数来自 AX、与窗口几何无关，照常判 `verified` / `refuted`。
- **坐标点击能证明命中。** 文本落点不再靠像素猜：点击前记下落点元素的 AX 引用与
  `AXSelectedTextRange`，点击后只读**同一个引用**，选区变了 → `verified=true`、
  `verifiedBy=selection_changed`；元素被应用重建或读不到选区时如实 `verified=false`，
  并给出 `unverifiedReason`，不退回像素、也不看别的元素。非文本落点仍走插入光标的
  像素形态（`caret_pixels`）。两条判据按落点类型二选一，不 OR。
- **截图铺满缓冲区，`scale` 描述内容而不是缓冲区。** 此前截图按窗口 points 的 1:1
  画进按 `1600/frame.width` 放大的缓冲区（880pt 的窗口 → 内容 880×640 贴在
  1600×1164 的左上角，右侧/下方是黑边），回报的 `scale` 却是缓冲区/窗口 = 1.818：
  按图像像素点击会整体偏 1.818 倍，`changedRatio` 也被稀释到阈值以下。现在内容铺满
  缓冲区、`scale` 由实际图像尺寸得出，阈值也按这个 `scale` 推。线协议随之升到 v13
  （`clickAt` 应答为 `clicked`，带选区观察），`scu` 与 `scu-native` 必须成对替换。

## 0.5.0 — 2026-11-04

### 新增

- 窗口身份：`Target`（pid + CGWindowID + title）贯通线协议 v12；`list_windows` 与 `get_screenshot`
  返回 `windowID`，`get_ax_state` 新增 `window_id`；截图坐标动作绑定实际截图的窗口 ID。
  见 [ADR-0031](docs/decisions/adr_0031_window_identity.md)。

- `scu --help` / `scu help` 与 `scu --version`；未知命令现在会提示查看帮助。
- 英文 README（`README.en.md`）；`CONTRIBUTING.md`、`SECURITY.md`、本变更记录。
- `scripts/check.sh` 增加格式检查与帮助命令冒烟，共 5 步；CI 改为直接运行同一入口。

### 变更

- 动作后的收敛判定改为按静默次数分两档：已观察到变化时连续 1 次一致（约 0.4 秒），从未观察到变化时
  连续 11 次一致（约 2.4 秒）才判定"稳定且无变化"；总上限仍为 3 秒。修复两秒加载被误判为
  "已收敛・无变化"的已知缺口，代价是无加载信号的空操作从 0.4 秒变为约 2.4 秒。
  见 [ADR-0011 追加记录](docs/decisions/adr_0011_convergence_over_fixed_delay.md)。
- **线协议升到 v12：窗口相关请求使用 `Target`，新增 `windowID`。`scu` 与 `scu-native` 必须成对升级，
  0.4.0（v11）与 0.5.0（v12）的二进制不能混用，没有数据迁移。**
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
