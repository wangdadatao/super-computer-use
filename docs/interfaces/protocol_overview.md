# 协议总览

SCU 对 agent 暴露的交互面。分层结构见[系统总览](../architecture/system_overview.md)，
设计理由见 [ADR-0002](../decisions/adr_0002_code_mode_surface.md)。

## 导航

- [工具面形态](#工具面形态)、[会话 API](#会话-api)：agent 侧的调用入口
- [目标绑定](#目标绑定)、[状态读取](#状态读取)、[动作执行](#动作执行)：主要交互面
- [动作效果](#动作效果)：成功返回的结构
- [失败返回](#失败返回)、[约束](#约束)

运行时的执行模型、输出通道与沙箱边界不在本文，见[运行时契约](runtime_contract.md)。
协议层与原生层之间的内部线协议也不在本文，见[原生层线协议](native_wire_protocol.md)。

## 工具面形态

SCU 对 agent **只暴露少量工具**，核心是一个 JavaScript 执行入口：

| 工具 | 作用 |
| --- | --- |
| `js` | 在会话运行时中执行 JavaScript，返回执行结果 |
| `js_reset` | 重置运行时，丢弃全部绑定 |

能力全部通过 JavaScript API 提供，而不是每个能力一个工具。
理由与代价见 [ADR-0002](../decisions/adr_0002_code_mode_surface.md)。

首版只提供 MCP stdio 形态。是否需要面向 agent 会话的独立 CLI 待定；仓库里已有面向开发者的诊断命令（`scu permissions` / `apps` / `windows` / `dump` / `identity`），它们不是这里讨论的接入形态。

**已实现的只是其中的一小部分**，工具也不是 `js`：见 [MCP 接入面](mcp_surface.md)——
五个只读工具（`check_permissions`、`list_apps`、`list_windows`、`get_ax_state`、`get_screenshot`），
加 `--actions` 时提供 `launch_app`、`click`、`click_at`、`scroll_at`、`drag`、`type_text`、`press_key`、`set_value`。
本文描述的 `js` 工具面与会话 API 仍是拟实施设计。

## 会话 API

运行时在全局注入一个对象，命名为 `scu`。

```ts
interface Scu {
  /** 列出当前可见的目标（应用与浏览器标签页）。 */
  getState(): Promise<State>;

  /** 绑定一个应用目标。返回 App 句柄。 */
  getApp(ref: string | { pid: number; windowId?: number }): Promise<App>;

  /** 绑定一个页面目标。 */
  getTab(ref: string | { url: string }): Promise<Tab>;

  /** 列出可绑定的应用。 */
  listApps(): Promise<AppInfo[]>;

  /** 列出可见的浏览器标签页。 */
  listTabs(): Promise<TabInfo[]>;
}
```

`App` 与 `Tab` 共享同一操作面（见[系统总览](../architecture/system_overview.md)的跨平台抽象）。
差异只在 `App` 额外提供 `pressKey` 与 `paste`：浏览器标签页的按键与粘贴
由页面自身的接口承担，不走系统级输入。

## 目标绑定

绑定是**显式**的，不隐式选择目标。

`getApp` 接受的引用形式：应用名、bundle id、可执行文件路径，或 `{ pid, windowId }`。
浏览器标签页不接受按名称推断，必须给出运行时的标签页标识、完整引用或指定浏览器下的唯一 URL
匹配。

**歧义即失败。** URL 匹配到多个标签页、名称匹配到多个应用时返回错误，
不选第一个。理由：隐式选择会让调用方在不知情的情况下操作错误的目标。

## 状态读取

```ts
interface Target {
  /** 读取无障碍树，返回文本化的元素表与快照令牌。 */
  getAXState(options?: { refresh?: boolean }): Promise<{
    text: string;
    snapshotToken: string;
  }>;

  /** 捕获屏幕或目标窗口。 */
  screenshot(options?: { geometryToken?: string }): Promise<{
    image: Uint8Array;
    geometryToken: string;
  }>;
}
```

**元素表是文本。** 每行一个元素，形如：

```
[AXWindow#1] "网易云音乐"
  [AXTextField#t7] "搜索" value="" actions=[press]
  [AXButton#1a] "搜索"
```

格式定义见[元素寻址](element_addressing.md)。默认返回与上一次的差异，
`refresh: true` 时返回完整树。

## 动作执行

所有动作接受**元素引用**或**坐标**，两者互斥：

```ts
interface Target {
  click(target: ElementRef | Coordinates, options?: ClickOptions): Promise<Effect>;
  drag(from: Coordinates, to: Coordinates, options?: DragOptions): Promise<Effect>;
  scroll(target: ElementRef | Coordinates, direction: Direction, pages?: number): Promise<Effect>;
  typeText(text: string): Promise<Effect>;
  setValue(ref: ElementRef, value: string): Promise<Effect>;
  performSecondaryAction(ref: ElementRef, action: string): Promise<Effect>;
}

/** 应用目标特有的动作。页面目标由浏览器自身的接口承担。 */
interface AppExtensions {
  /** 按下按键或组合键。支持按住不放（见编辑类操作语义）。 */
  pressKey(key: string, options?: PressKeyOptions): Promise<Effect>;
  /** 经剪贴板写入文本，写入后恢复调用前的剪贴板内容。 */
  paste(text: string, options?: PasteOptions): Promise<Effect>;
}
```

坐标必须携带坐标令牌，否则拒绝执行：

```ts
type Coordinates = { x: number; y: number; geometryToken: string };
```

编辑类动作（设值 / 输入 / 选择 / 粘贴）的内部语义差异较大，
包括三条写入路径各自触发什么、目标解析顺序、剪贴板的快照语义。
详见[编辑类操作语义](edit_semantics.md)。

## 动作效果

> **P0 实际**：`click` 的效果摘要字段是 `delivered`、`observed`、`converged`、`treeChanged`、`targetChanged`、`noOpSuspected`、
> `polls`、`elapsed`、`tokenInvalidated`，没有 `focusStolenBy` 与 `snapshotToken`（树变化后旧令牌失效，不发新令牌，由调用方重读）。
> 见 [MCP 接入面](mcp_surface.md#click_tool)。下面的接口是拟实施设计。

每个动作返回效果摘要，而不是空返回：

```ts
interface Effect {
  delivered: boolean;          // 事件是否成功投递
  converged: boolean;          // 目标是否已进入稳定状态
  treeChanged: boolean;        // 树是否变化
  targetChanged: boolean;      // 目标元素的可观察属性是否变化
  focusStolenBy: string | null; // 焦点是否被其他目标夺走
  noOpSuspected: boolean;      // 已收敛但无任何可观测变化
  snapshotToken: string | null; // 若树已重读，返回新令牌
}
```

**\`converged\` 与 \`noOpSuspected\` 必须分开看。** 未收敛不是“没生效”，
而是“还不知道”——这两种情况对调用方的含义不同。详见
[动作收敛与等待](../architecture/action_convergence.md)。

字段语义见[术语表](../domains/glossary.md)。设计理由见
[ADR-0006](../decisions/adr_0006_action_effect_verification.md) 与
[ADR-0011](../decisions/adr_0011_convergence_over_fixed_delay.md)。

## 失败返回

动作失败时 Promise 拒绝，拒绝值是结构化的错误对象。错误码表与可重试性映射
见[错误与拒绝](error_taxonomy.md)。

**成功与失败的边界不在本处重复**，但有一条容易搞错：动作已投递但界面无变化、
以及在收敛窗口内未观察到稳定，**都属于成功返回**，不是错误。
把它们当错误处理会导致调用方对正常情况做异常分支。

## 约束

- **一次一个目标。** 会话同时只绑定一个目标。切换目标会让旧令牌全部失效。
  目标的发现与绑定规则见[目标发现与绑定](target_discovery.md)。
- **不并行。** 同一会话内的动作串行执行，收敛窗口包含在串行段内。
  这是正确性要求：桌面是单点资源，并行会导致事件顺序不可预测和焦点竞争。
  详见[会话与控制租约](../architecture/session_and_lease.md)。
- **坐标令牌必填。** 基于坐标的动作没有令牌时直接拒绝，不做默认值推断。
- **失败即拒绝。** 令牌失效、引用歧义、目标不存在时拒绝执行，不做兜底猜测。
- **动作先过策略。** 每个动作在执行前经过[策略层](../architecture/policy_layer.md)准入。
  策略拒绝与协议拒绝在返回值上必须可区分：前者不重试，后者应重读状态后重试。
