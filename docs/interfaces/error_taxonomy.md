# 错误与拒绝

SCU 失败返回的结构、分类与可重试性。成功返回的形态见
[协议总览](protocol_overview.md)的效果摘要。

## 导航

- [为什么需要独立契约](#为什么需要独立契约)
- [成功与失败的边界](#成功与失败的边界)
- [错误结构](#错误结构)
- [错误码表](#错误码表)
- [可重试性](#可重试性)
- [在 code mode 中的形态](#在-code-mode-中的形态)

## 为什么需要独立契约

全库至少有五处要求"返回值得可区分"，但没有一处定义过返回值的形状：

| 来源 | 要求区分的类别 |
| --- | --- |
| [失效模型](../domains/staleness_model.md) | 失效、失效类别、不重复上报 |
| [策略与审批](../architecture/policy_layer.md) | 策略拒绝 / 授权缺失 / 需确认 |
| [目标发现](target_discovery.md) | 歧义须携带候选列表 |
| [ADR-0009](../decisions/adr_0009_policy_layer.md) | 策略拒绝与协议拒绝必须可区分 |
| [编辑类操作语义](edit_semantics.md) | 元素不支持某操作时的拒绝 |

缺这个契约的后果是具体的：**调用方无法写出正确的重试逻辑**。
把"令牌失效"和"策略拒绝"都当成一般错误处理，会导致对不可协商的拒绝对无限重试，
或者对可恢复的失效直接放弃。

## 成功与失败的边界

先划清什么不算错误。以下都是**成功返回**，只是携带了需要注意的信息：

| 情况 | 归属 | 理由 |
| --- | --- | --- |
| 动作已投递但界面无变化 | 成功 | 事件确实送达了，只是没生效。这是信息，不是失败 |
| 在收敛窗口内未观察到稳定 | 成功 | "还不知道"不等于"失败" |
| 元素在快照中消失 | 成功 | 重新读取后元素不在了，是状态事实 |
| 策略判定为"需确认" | 失败 | 动作尚未执行，调用方必须处理 |

前两项对应[动作收敛与等待](../architecture/action_convergence.md)的
`converged` 与 `noOpSuspected` 两个字段。**把它们做成错误会诱导调用方
对正常情况做异常处理。**

<a id="error_structure"></a>
## 错误结构

```ts
interface ScuError {
  /** 机器可读的错误码，见下表。调用方据此分支，不要解析 message。 */
  code: ErrorCode;
  /** 产生错误的层。决定调用方该找谁介入。 */
  layer: "policy" | "protocol" | "platform" | "boundary";
  /** 可重试性。见下节。 */
  retry: RetryAdvice;
  /** 人类可读描述。用于日志与展示，不用于分支判断。 */
  message: string;
  /** 错误码特定的补充信息。 */
  details?: Record<string, unknown>;
  /** 仅 ambiguous_reference 携带：候选目标列表，调用方可直接选用。 */
  candidates?: TargetRef[];
}
```

**`code` 是唯一的分支依据。** 协议保证 `code` 的稳定性和语义；
`message` 的措辞可能随时调整，解析它是未定义行为。

## 错误码表

| code | layer | retry | 含义 |
| --- | --- | --- | --- |
| `stale_snapshot` | protocol | `after_refresh` | 快照令牌失效，树已变化 |
| `stale_geometry` | protocol | `after_refresh` | 坐标令牌失效，窗口几何已变化 |
| `target_switched` | protocol | `after_rebind` | 令牌属于已解绑的目标 |
| `target_missing` | protocol | `no` | 目标不存在或已退出 |
| `element_gone` | protocol | `after_refresh` | 引用在新快照中无法匹配 |
| `ambiguous_reference` | protocol | `after_disambiguation` | **目标**引用歧义（同名应用 / 同 URL 标签页），携带 `candidates` |
| `unsupported_operation` | protocol | `no` | 元素不支持该操作（如不可写元素设值） |
| `policy_denied` | policy | `no` | 命中拒绝类目，不可协商 |
| `authorization_denied` | policy | `no` | 用户在授权提示中明确拒绝 |
| `authorization_timeout` | policy | `after_user_action` | 授权提示超时未响应 |
| `confirmation_denied` | policy | `no` | 用户在审批提示中明确拒绝 |
| `confirmation_timeout` | policy | `after_user_action` | 审批提示超时未响应 |
| `system_permission_missing` | platform | `after_user_action` | 系统权限未授予（辅助功能 / 屏幕录制） |
| `platform_unavailable` | platform | `immediate` | 原生层不可达或崩溃 |
| `protocol_version_mismatch` | boundary | `no` | 两侧协议版本不一致 |
| `internal_error` | boundary | `immediate` | 未归类的内部故障 |

`layer` 的语义是**调用方该找谁**：

| layer | 含义 | 调用方应对 |
| --- | --- | --- |
| `policy` | 策略层不放行 | 需要用户介入或改变做法 |
| `protocol` | 状态/寻址问题 | 刷新状态或换引用后重试 |
| `platform` | 操作系统层问题 | 检查权限或稍后重试 |
| `boundary` | 两侧版本/进程问题 | 环境问题，重试通常无用 |

## 可重试性

| retry | 调用方应做 |
| --- | --- |
| `no` | **不要重试。** 重试会得到同样结果 |
| `immediate` | 可直接重试。适用于瞬时故障 |
| `after_refresh` | 先重新读取状态（`getAXState` / `screenshot`），再重试 |
| `after_rebind` | 先重新绑定目标，再重试 |
| `after_disambiguation` | 用 `candidates` 中的一项重发 |
| `after_user_action` | 需要用户完成某个动作（授权 / 确认），然后重试 |

**关于"超时"为什么不是 `immediate`**：超时的原因是用户没有响应。
立即重试会重新弹出提示——如果用户仍然不在，就是一次无效的弹窗循环。
因此超时归为 `after_user_action`：它要求的是"用户回到电脑前"这个动作，
而不是重试本身。

**`after_refresh` 是最常见的一类**，它对应[ADR-0003](../decisions/adr_0003_snapshot_token_contract.md)
的核心机制：状态已变，重新读取后即可继续。这类错误**不是故障，是正常流程的一部分**。

**`no` 是硬边界。** `policy_denied` 与 `target_missing` 属于此类。
对 `policy_denied` 重试不会改变结果——它对应的是不可协商的拒绝类目。

## 为什么没有 `confirmation_required`

策略层的"需确认"**不是返回给调用方的错误码**，理由见
[策略与审批](../architecture/policy_layer.md)：确认是**同步阻塞**的——
动作请求会一直等到用户作出决定，调用方看到的是一个尚未 resolve 的 Promise。

因此调用方只会观察到三种结果：

| 结果 | 错误码 |
| --- | --- |
| 用户同意，动作执行 | 无（正常返回效果摘要） |
| 用户明确拒绝 | `confirmation_denied` |
| 时限内无响应 | `confirmation_timeout` |

**授权请求遵循同一模型**，对应 `authorization_denied` 与 `authorization_timeout`。

这对调用方是一个重要性质：**它不需要为"等待用户"写额外的分支**——
线性代码只会在用户决定之后继续。代价是它无法在等待期间做别的事，
也无法感知"正在等待"这个中间状态。这个代价是刻意接受的，
见[策略与审批](../architecture/policy_layer.md)的取舍说明。

## 在 code mode 中的形态

动作失败时，JavaScript 的 Promise **拒绝**，拒绝值是上面的 `ScuError` 对象。

```js
try {
  await app.click("AXButton#1a");
} catch (e) {
  switch (e.code) {
    case "stale_snapshot":
      await app.getAXState();       // 刷新后重试
      break;
    case "policy_denied":
      nodeRepl.write(`不能这么做：${e.message}`);  // 不重试
      break;
    case "ambiguous_reference":
      nodeRepl.write(`候选：${e.candidates.join(", ")}`);
      break;
  }
}
```

**错误必须是可捕获的值，不是字符串。** 若只抛出字符串，
调用方只能靠匹配文本分支，这在协议演进时必然出错。

## 未定项

- **错误码的扩展规则**：新增码时是否要求向后兼容（旧调用方遇到未知码时
  应按 `layer` 做保守处理）。当前设计未定。
- **`details` 的字段约定**：每个码的补充信息形状尚未逐一规定。
  首版实现时按需要补充，但需保持"未知字段可忽略"的约定。
