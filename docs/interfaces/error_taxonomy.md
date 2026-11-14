# 错误与拒绝

SCU 失败返回的结构、分类与可重试性。成功返回的形态见
[协议总览](protocol_overview.md)的效果摘要。

## 导航

- [为什么需要独立契约](#为什么需要独立契约)
- [成功与失败的边界](#成功与失败的边界)
- [错误结构](#错误结构)
- [错误码表](#错误码表)
- [details](#details)
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
| 动作之后元素不在了 | 成功 | 动作后的重读里目标不在原路径上，是状态事实：效果摘要的 `targetChanged=true`。**与 `element_gone` 不同**——后者是动作**之前**句柄就不在令牌对应的快照里，动作没有执行，是错误 |
| 策略判定为"需确认" | 失败 | 动作尚未执行，调用方必须处理 |

前两项对应[动作收敛与等待](../architecture/action_convergence.md)的
`converged` 与 `noOpSuspected` 两个字段。**把它们做成错误会诱导调用方
对正常情况做异常处理。**

效果摘要的 `verificationState`（`verified` / `refuted` / `unknown`）同理：`refuted` 与 `unknown`
都是**成功返回**，不是错误码。`refuted` 只否定声明的后置条件，`unknown` 只表示判不了；
原因在 `verificationReason` 里，调用方按码分支，不要为了“动作没生效”去匹配错误。

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
  /** 错误码特定的补充信息。值为字符串，键由错误码定义；见下文“details”。 */
  details?: Record<string, string>;
  /** 仅 ambiguous_reference 的**目标**歧义携带：候选目标列表，调用方可直接选用。
   *  窗口标题歧义目前只写 message，不带这个字段。 */
  candidates?: TargetRef[];
}
```

**`code` 是唯一的分支依据。** 协议保证 `code` 的稳定性和语义；
`message` 的措辞可能随时调整，解析它是未定义行为。

<a id="error_codes"></a>
## 错误码表

| code | layer | retry | 含义 |
| --- | --- | --- | --- |
| `stale_snapshot` | protocol | `after_refresh` | 快照令牌失效，树已变化 |
| `stale_geometry` | protocol | `after_refresh` | 截图不存在、已过期、不属于当前令牌，或动作前复核发现绑定窗口的几何已变化（见 [MCP 接入面](mcp_surface.md#click_tool)）。`details.reason` 见下文 |
| `invalid_coordinates` | protocol | `no` | 坐标不在截图范围内；v2 新增 |
| `target_switched` | protocol | `after_rebind` | 令牌属于已解绑的目标 |
| `target_missing` | protocol | `no` | 目标不存在或已退出 |
| `element_gone` | protocol | `after_refresh` | 引用在新快照中无法匹配 |
| `app_not_found` | protocol | `no` | 启动/解析时找不到应用；v2 新增 |
| `app_not_authorized` | policy | `no` | 应用不在本次连接的允许列表里；v2 新增，见 [ADR-0024](../decisions/adr_0024_app_authorization.md) |
| `window_not_found` | protocol | `after_refresh` | 指定的窗口 ID 或标题不存在、已变化或窗口已重建（读取、截图、坐标动作与元素动作都可能返回）；v2 新增，见 [ADR-0026](../decisions/adr_0026_window_selection.md)、[ADR-0027](../decisions/adr_0027_window_root_locator.md)、[ADR-0031](../decisions/adr_0031_window_identity.md) |
| `conflicting_target` | protocol | `no` | 目标同时给了窗口 ID 与标题，无法判定按哪个绑定；协议不替调用方挑一个。标题只作线索的写法是 `Target.forWindow`，见 [ADR-0027](../decisions/adr_0027_window_root_locator.md#window_root_locator) |
| `ambiguous_reference` | protocol | `after_disambiguation` | 引用歧义：标题去重后匹配 ≥2 个窗口（窗口标题当身份时）；**零动作**。`details.reason=title_ambiguous`、`candidate_count=N`，候选写在 `message`。应用/URL 标签页的歧义仍是设计目标 |
| `unsupported_operation` | protocol | `no` | 元素或参数不支持该操作（如不可写元素设值、元素不接受焦点、不认识的键名） |
| `focus_not_established` | platform | `after_user_action` | 键盘动作投递前，应用级 `AXFocusedUIElement` 不是目标（或读不到）；**零按键**。`details.reason` 见下文 |
| `policy_denied` | policy | `no` | 命中拒绝类目，不可协商 |
| `authorization_denied` | policy | `no` | 用户在授权提示中明确拒绝 |
| `authorization_timeout` | policy | `after_user_action` | 授权提示超时未响应 |
| `confirmation_denied` | policy | `no` | 用户在审批提示中明确拒绝 |
| `confirmation_timeout` | policy | `after_user_action` | 审批提示超时未响应 |
| `system_permission_missing` | platform | `after_user_action` | 系统权限未授予（辅助功能或屏幕录制） |
| `platform_unavailable` | platform | `immediate` | 原生层不可达、崩溃，或**读请求**等待应答超时（请求未产生动作） |
| `action_outcome_unknown` | platform | `after_refresh` | **动作请求已写出**但等应答超时、连接在应答前断开、通信失败或应答帧错位；动作可能已经执行，先重读状态再决定是否重发 |
| `action_failed` | platform | `immediate` | 目标仍在、定位核对通过，但平台拒绝或未能完成动作（如 `AXPress` 返回 `cannotComplete`）。P0 新增，见 [ADR-0015](../decisions/adr_0015_handle_resolution_by_path.md) |
| `protocol_version_mismatch` | boundary | `no` | 两侧协议版本不一致 |
| `internal_error` | boundary | `immediate` | 未归类的内部故障 |

**当前实际发出的码**：`stale_snapshot`、`stale_geometry`、`invalid_coordinates`、`app_not_found`、`app_not_authorized`、`window_not_found`、`conflicting_target`、`ambiguous_reference`、`focus_not_established`、`target_switched`、`element_gone`、
`unsupported_operation`、`policy_denied`、`system_permission_missing`、`target_missing`、`platform_unavailable`、
`action_outcome_unknown`、`action_failed`、`protocol_version_mismatch`、`internal_error`。
`ambiguous_reference` 目前只在**窗口标题**歧义时发出（`candidates` 未实现）；`authorization_*`、`confirmation_*` 仍是设计目标，尚无构造它们的代码（逐次审批未实现）。
应用允许列表的拒绝使用 `app_not_authorized`，不是 `authorization_denied`；后者保留给交互式授权提示。

<a id="details"></a>
## details

`details` 只给三个码用，值一律是字符串（不塞数组、不塞嵌套对象）。`message` 的措辞可变，
调用方只按 `code` 与 `details` 分支。没有需要说明的补充信息时**不出现该字段**（不是空对象）。

**`stale_geometry`**：`reason` 按坐标路径的检查顺序取**第一个**失败项，同一次调用永远同一个 reason；
只有实际失败的那一项带 `expected` / `actual`。

| 顺序 | `reason` | 判据 | 额外键 |
| --- | --- | --- | --- |
| 0 | `capture_unknown` | `screenshot_id` 不存在或已被淘汰 | — |
| 1 | `capture_token_mismatch` | 绑定存在但不属于当前令牌 | — |
| 2 | `window_gone` | 动作前复核时窗口已找不到（原生 `window_not_found` 在协议层翻译） | `bound_by=window_id\|window_title` |
| 3 | `window_replaced` | 绑定与当前 `windowID` 都非 nil 且不相等（ID 变了、几何没变） | `expected=#旧ID`、`actual=#新ID` |
| 4 | `frame_changed` | 窗口 frame 不等 | `expected=x,y,w,h`、`actual=x,y,w,h` |
| 5 | `scale_changed` | 截图 scale 不等（三位小数） | `expected`、`actual` |
| 6 | `size_changed` | 图像宽高不等 | `expected=w×h`、`actual=w×h` |

`get_screenshot` 自己取新截图时若窗口已关，仍报 `window_not_found`，不翻译成 `stale_geometry`。

**`ambiguous_reference`**：`reason=title_ambiguous`、`candidate_count=N`。候选的窗口号与 frame
只写在 `message` 里（按视觉顺序 y、x，最多 5 个），类型化的 `candidates` 未实现。

**`focus_not_established`**：`reason` 为 `focused_element_elsewhere` / `focused_element_unreadable` /
`window_not_key` 之一；`observed_role` 在读得到当前焦点时给出；`app_active` 只是诊断，不作门禁；
`keys_posted` 恒为 `0`——判定在字符/按键循环之前，一个按键都没有发。

输出层：MCP 首行保持 `[code] message（retry=…）`，有 `details` 时追加一行
`details: reason=… key=value`（`reason` 在前，其余键按字母序）；CLI 的 stderr 用同样格式。

**接入层（MCP）自己的码**不经原生层，没有 `layer` 与 `retry`，工具文本里不带 `（retry=…）`：

| code | 含义 |
| --- | --- |
| `invalid_argument` | 工具参数缺失、类型或范围不对、出现未声明参数。调用方改参数后重试 |
| `tool_unavailable` | 保留码；P0 里到不了（动作档未开启时 `click` 在 JSON-RPC 层按未知工具被拒，见 [MCP 接入面](mcp_surface.md)） |

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

**关于"超时"为什么不是 `immediate`**：这里的“超时”专指**等待用户响应**的授权/审批提示。
超时的原因是用户没有响应。立即重试会重新弹出提示——如果用户仍然不在，就是一次无效的弹窗循环。
因此这种超时归为 `after_user_action`：它要求的是"用户回到电脑前"这个动作，而不是重试本身。

**动作传输失败是另一回事**：请求已经写出，原生层可能已经执行了点击/输入，只是应答没回来。
这包括等待应答超时、对端在应答前断开、socket 通信失败与应答帧 id 错位。把它标成 `immediate`
会让调用方重复一次动作；因此动作类请求在**完整写出之后**的这些失败都返回 `action_outcome_unknown`
（`after_refresh`）：先重读状态，确认动作是否已经生效，再决定是否重发。
读请求，以及尚未完整写出的动作请求，仍是 `platform_unavailable`（`immediate`），因为没有产生动作。

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
