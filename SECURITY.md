# 安全策略

SCU 能读取屏幕内容、模拟点击与键盘输入，因此默认按**高权限本地服务**对待：
默认只读、动作档需显式开启、可限定应用允许列表、危险应用类目默认拒绝。

## 支持范围

| 版本 | 安全修复 |
| --- | --- |
| 0.4.x | 支持 |
| < 0.4 | 不单独维护 |

项目处于 0.x，安全修复会进入下一个补丁版本，不承诺长期维护分支。

## 报告漏洞

**不要开公开 issue。** 请用 GitHub 仓库的
Security → Report a vulnerability（私密 Security Advisory）提交，并附：

- 受影响的版本与 commit；
- 复现步骤（最小化，注明是否需要辅助功能/屏幕录制权限）；
- 影响：能读到什么、能改什么、是否需要本地用户交互；
- 你希望的披露时间。

如果私密入口不可用，先开一个**不含细节**的 issue 说明需要私下联系，维护者会建立私密通道。
一般 7 天内首次回复；修复与披露时间按问题严重程度协商。

## 在范围内

- 绕过动作策略：在未开启 `--actions` 时调用动作工具，或让被拒绝类目的应用成为动作目标；
- 绕过连接级应用允许列表（`app_not_authorized` 之后仍能读或动）；
- 令牌/句柄越权：用失效或他人的快照令牌操作元素；
- 本地提权或命令执行：通过 `scu`/`scu-native` 的消息、socket、`SCU_NATIVE`、允许列表文件路径等；
- 通过 MCP 工具输入触发路径穿越、任意文件读写、shell 注入；
- 未预期地把截图、窗口内容或本机路径写入日志、stdout 或临时文件（stdout 只允许协议消息）；
- 子进程/临时目录/文件描述符泄漏导致拒绝服务。

## 不在范围内

- macOS TCC（辅助功能、屏幕录制）本身的授权模型，或用户主动授予的权限；
- 目标应用自身的无障碍实现缺陷；
- 提示注入导致的"模型做了用户不想做的事"——SCU 的边界是**动作准入**，
  不判断用户意图；需要更强约束时使用 `--allow-app` 与只读档；
- 用户自行从非官方渠道取得的二进制或改过的包；
- 已被上游修复、且未给本项目留下利用面的问题。

## 安全相关的设计

- [策略与审批](docs/architecture/policy_layer.md)：拒绝类目、允许列表与宿主判定；
- [MCP 接入面](docs/interfaces/mcp_surface.md)：工具注释、错误通道、stdout 纪律；
- [ADR-0009](docs/decisions/adr_0009_policy_layer.md)、
  [ADR-0010](docs/decisions/adr_0010_ui_automation_only.md)、
  [ADR-0024](docs/decisions/adr_0024_app_authorization.md)。

## 分发

分发包当前是 ad-hoc 签名、未公证。请只从本仓库的 Release 获取产物并核对 `SHA256SUMS`；
未公证的包不应被当作可信来源。签名与公证流程见
[docs/operations/distribution.md](docs/operations/distribution.md)。
