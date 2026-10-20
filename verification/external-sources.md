# 外部观察来源

SCU 的设计决策引用了一批对两套已发布实现的观察结论。本文件记录**每条结论
来自哪个工件的哪个证据**，使结论可复核、可判断是否已过时。

本文件属于**证据**，不属于 Project Doc 文档库（`docs/`）。
文档库中的结论引用本文的来源 ID。

## 为什么需要它

审计（R-07）指出：文档中有 30 余处「参考实现中观察到……」，**零处记录来源**。
后果是具体的：

- 结论无法核实，读者只能选择相信或不相信
- 参考实现更新后，无法判断哪些结论已经过时
- 采集时的方法错误也无法被发现（本文件已记录三处，见「已知纠正」）

## 工件清单

### Codex Computer Use（OpenAI）

| ID | 工件 | 版本 / 标识 | 采集日期 |
| --- | --- | --- | --- |
| `CU-APP` | 主程序 `SkyComputerUseService`<br><sub>`~/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/`</sub> | `26.1013.1001501` (build 1001501)<br>sha256 `f21c31c0ee5df419dbd165bf76ebd65c64d864c6fec5b6c6c3a23c42ff3d2e13`<br>Mach-O arm64, 24934560 字节 | 2026-10-16 |
| `CU-CLIENT` | 客户端 `SkyComputerUseClient`<br><sub>`~/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/`</sub> | `26.1013.1001501` (build 1001501)<br>sha256 `4861d29eb73f6f71a5a82dc94fc7c696d34e8cd6493f1932f6ba7b51f6448cf5`<br>Mach-O arm64, 15502928 字节 | 2026-10-20 |
| `CU-PLUGIN-OLD` | 插件 `computer-use`（7 月版本快照）<br><sub>`~/.codex-proxy/plugins/cache/openai-bundled/computer-use/1.0.1000366/`</sub> | `1.0.1000366` | 2026-10-16 |
| `CU-PLUGIN` | 插件 `computer-use`<br><sub>`~/.codex/.tmp/bundled-marketplaces/openai-bundled/plugins/computer-use/`</sub> | `1.0.1001501`<br>`SKILL.md` sha256 `e6a2b212bacad8d16a9a07e2fef5d428ea00c7b9a8f8529bec1bd2ba48a49c4f` | 2026-10-20 |
| `CU-UNIFIED` | 插件 `unified-computer-use` | `26.1013.31256` | 2026-10-16 |
| `CU-SKY` | JS 包 `@oai/sky`<br><sub>`/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/`</sub> | `0.7.8` | 2026-10-16 |
| `CU-SKY-POLICY` | `@oai/sky` 的应用策略入口<br><sub>`dist/project/cua/sky_js/src/targets/mac/computer-use-policy.js`</sub> | `0.7.8`<br>sha256 `a00024117e11f2d1e4151e140bede2c0ed7931625aa0f79a427457cb1103524e` | 2026-10-20 |
| `CU-CUA` | JS 包 `@oai/cua` | `0.2.6` | 2026-10-16 |
| `CU-REPL` | JS 包 `@oai/cua-repl` | `0.1.0` | 2026-10-16 |

### Grok Bot Computer Use（xAI / Anysphere）

| ID | 工件 | 版本 / 标识 | 采集日期 |
| --- | --- | --- | --- |
| `GB-NATIVE` | 主程序 `CUGrokBotService`<br><sub>`/Applications/Grok Bot.app/Contents/Helpers/Grok Bot Computer Use.app/Contents/MacOS/`</sub> | `1.0.0` (build 1)<br>sha256 `ebcb4aeba02914e0cf073fd3493b2c1235b73814fe60fd7854c296591b68bbc5`<br>Mach-O universal (x86_64 + arm64) | 2026-10-16 |
| `GB-ASAR` | Electron 主程序 `app.asar`<br><sub>`/Applications/Grok Bot.app/Contents/Resources/`</sub> | Grok Bot `0.71.2`<br>sha256 `055b087a9bacc3be4e5f80c468edf2fd031dd5b928ab2e7da7e01dd10de0e860`<br>43877938 字节 | 2026-10-16 |

## 采集方法

| 方法 | 用途 | 命令 |
| --- | --- | --- |
| 未定义符号 | 判断某系统 API 是否被调用 | `nm -u -arch arm64 <binary>` |
| 字符串提取 | 读取文案、类名、工具描述 | `strings -n <len> <artifact>` |
| 链接框架 | 判断依赖的框架 | `otool -L <binary>` |
| 属性列表 | 版本、bundle id、权限声明 | `plutil -extract <key> raw <Info.plist>` |
| 源码直读 | JS 包的类型定义、文档、配置 | 直接读取文件 |
| ASAR 解包 | 读取 Electron 主程序内的压缩 JS、i18n 表 | `npx @electron/asar extract <app.asar> <dir>`（只读解包，不改原工件） |
| REA 静态分析 | 对 ASAR 做结构化重建（应用图、Electron 边界、完整性核对），给出可引用的证据 ID | `rea analyze-javascript-application <asar> --integrity-policy record-and-continue --format json --full-output`（REA 6.5.0）。完整性不符时默认失败，见下文「2026-10-18 复核记录」 |

**方法注意事项（会直接影响结论的正确性）**

1. **`strings` 看不到未定义符号。** 判断"是否调用了某 API"必须用 `nm -u`。
   本文档的「已知纠正 C-1」就是因为在 `nm` 与 `strings` 之间混用而得出错误结论。
2. **universal binary 需要指定架构。** `nm -u <universal>` 可能只返回第一个架构的符号，
   而该架构可能是 x86_64。`GB-NATIVE` 必须用 `-arch arm64`。
3. **符号名带前导下划线。** 查 `AXUIElementPerformAction` 实际匹配 `_AXUIElementPerformAction`。
4. **Objective-C 类以 `_OBJC_CLASS_$_` 前缀出现在符号表里**，
   在 `strings` 里通常只有类名本身。

## 结论 → 来源映射

下表把文档中的结论落到具体证据。**「证据」一列是可复核的最小单元。**

### 寻址与元素表

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| 两套实现都以无障碍树为首选路径 | `CU-APP`、`GB-NATIVE` | 两处 `nm -u` 均含完整 `AXUIElement*` 符号集（复制属性、执行动作、设属性、取位置元素） |
| 坐标是兜底路径 | `CU-REPL`、`GB-NATIVE` | `CU-REPL` 的 `instructions/macos/computer.md`；`GB-NATIVE` 的工具描述含 "Prefer this over coordinate clicks when the element is in the tree" |
| 元素表是带短 ID 的文本 | `CU-REPL`、`GB-NATIVE` | `GB-NATIVE` 工具描述："Read the app's accessibility tree as text (no image): one element per line" |
| 位置寻址（帧内序号） | `CU-SKY`、`GB-NATIVE` | `CU-SKY` 的 `Click.d.ts` 注释 "Element index from the latest `get_app_state()` text"；`GB-NATIVE` 有 `element_id` 与 `snapshot_id` |

### 坐标与截图（2026-10-19 复核）

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| Codex 的截图是**目标窗口**，坐标以窗口截图的逻辑像素计 | `CU-SKY` | `docs/sky-window-api.md`：`Screenshot.width/height` 注释 "logical pixels"；`Screenshot.originX/originY` 是屏幕原点；`ClickInput.x/y` 注释 "in the app-window screenshot" |
| Codex 的点击可传 `element_index` 或 `x/y`；有元素时优先元素 | `CU-SKY` | `docs/sky-window-api.md`：`click` "either an indexed element … or a coordinate in the app window"；`CU-PLUGIN-OLD` SKILL.md："Prefer `element_index`-based actions … fall back to using screenshots and coordinate clicks" |
| Codex 的坐标动作可绑定 `screenshotId`，截图必须为目标窗口缓存 | `CU-SKY` | `docs/sky-window2-api.md`：`screenshotId` "when supplied, it must be cached for the target window" |
| Codex 让模型直接看窗口截图定位，不预先枚举按钮坐标 | `CU-PLUGIN-OLD` | SKILL.md：`get_app_state` 返回 `{ text, screenshot }`；截图用 `nodeRepl.emitImage` 读入；`click({ app, x, y })` |
| Codex 的 `element_index` 只对最新状态有效 | `CU-PLUGIN-OLD` | SKILL.md："forces you to re-derive fresh `element_index` values … instead of reusing stale ones" |

**复核记录**：`CU-SKY` 为 `@oai/sky` `0.7.8`，
`docs/sky-window-api.md` sha256 `18d387e9…`、`docs/sky-window2-api.md` sha256 `85fa55b9…`；
`CU-PLUGIN-OLD` 的 `skills/computer-use/SKILL.md` sha256 `8e6a753c…`。
采集方法：直接读取 JS 包内 API 文档与技能文件（2026-10-19）。

### 状态与失效

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| Codex 靠提示词约定"每步重取" | `CU-PLUGIN-OLD` | `skills/computer-use/SKILL.md`：「After performing one or more UI actions, call `get_app_state(...)` … forces you to re-derive fresh `element_index` values … instead of reusing stale ones」 |
| Grok 用快照令牌 | `GB-NATIVE` | 32 处 `coordinate_token`、40 处 `snapshot_id`；工具描述明确 "It stays valid across actions until you read a new tree" |
| Grok 在动作时比对检测失效 | `GB-NATIVE` | **无 `AXObserver*` 符号**（见纠正 C-1），但含字符串 "The accessibility tree changed (" 与 "changed while accessibility state was captured." |
| Codex 有变更通知驱动的失效检测 | `CU-APP` | `nm -u` 含完整 `AXObserver*` 符号集；含类 `AccessibilitySupport.UIElementTreeInvalidationMonitor` |

### 动作与效果

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| 两套实现的动作接口不返回效果摘要 | `CU-SKY`、`GB-NATIVE` | `CU-SKY` 的 `Click.d.ts` 返回类型为 `Promise<void>`；`GB-NATIVE` 工具描述称 "The result is text only" |
| Grok 有结构化拒绝返回 | `GB-NATIVE` | 工具描述："A refused call returns isError=true with structuredContent {code, message, escalation: {recommended, reason}}" |
| Grok 有错误码到升级建议的映射 | `GB-NATIVE` | 字符串 `escalationByCode`、`reasonByEscalation` |
| Codex 动作后自动等待 | `CU-PLUGIN-OLD` | `SKILL.md`：「It waits about 1 second, with additional delays of up to 5 seconds if the app has a loading indicator」 |
| Grok 提供显式等待原语 | `GB-NATIVE` | `computer_wait` 描述，默认 1000 毫秒 |

### 接口形态

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| Codex 用 code mode（少量工具） | `CU-UNIFIED` | `.mcp.json` 的 `enabled_tools` 只有 `js`、`js_reset`、`turn_ended` |
| Grok 用平铺工具（十余个） | `GB-NATIVE` | 工具名清单：`computer_screenshot`、`computer_click`、`computer_move`、`computer_drag`、`computer_type`、`computer_key`、`computer_scroll`、`computer_wait`、`computer_check_permissions`、`computer_apps`、`computer_resolve_app`、`computer_app_state`、`computer_set_value`、`computer_app_action`（另含 `computer_start_control`、`computer_release_control`） |
| Codex 有协议版本协商 | `CU-APP` | 字符串 `clientApiVersion`、`serverApiVersion`、`incompatibleClientVersion` |

### 用户可见与安全

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| Codex 有虚拟光标 | `CU-APP` | 类 `ComputerUse.FogCursorStyle`、`ComputerUse.SoftwareCursorStyle`、`SlimCore.ArrowWindow`；协议 `AccessibilitySupport.VirtualCursor` |
| Grok 有光标覆盖层与窗口边框 | `GB-NATIVE` | 类 `CUCore/CUCursorOverlay.swift`、`CUCore/CUWindowBorderOverlay.swift`、`CUCursorOverlayKind`、`CUCursorOverlayTarget` |
| Grok 用辉光区分接管模式 | `GB-NATIVE` | 类 `CUCore/CURemoteControlGlowOverlay.swift`、`CURemoteControlOverlayController` |
| 覆盖层排除出截图的机制 | `CU-APP`、`GB-NATIVE` | 两处均含符号 `initWithDisplay:excludingWindows:`；`GB-NATIVE` 另含 `setSharingType:` |
| 覆盖层不接收鼠标事件 | `CU-APP`、`GB-NATIVE` | 两处均含符号 `setIgnoresMouseEvents:` |
| Codex 有按应用知识注入 | `CU-APP` | 字符串 `<app_specific_instructions>` 成对出现；`bundleIdentifiersWithDeliveredInstructions`；应用说明文件位于 `Package_ComputerUse.bundle/Contents/Resources/AppInstructions/`（7 个） |
| Codex 的审批以提示词表达 | `CU-PLUGIN-OLD` | `SKILL.md` 的 "Computer Use Confirmations Policy" 一节，条目以 `[15]`、`[2.1]`、`[8.3]` 等编号组织 |
| Grok 用硬编码应用黑名单 | `GB-ASAR` | 字符串 `runsShellCommands`、`runsScripts`、`holdsPasswords`、`hostsTerminalsAndAgents`、`changesSystemSettings`、`hostsGrokBot` 及其应用清单；拒绝文案 "…never drives a terminal, an app that runs scripts, an app that holds passwords, System Settings, Cursor, Sand, or its computer-use helper." **位于 asar（Electron 侧），不在原生二进制**（见纠正 C-3） |
| Grok 有逐应用三态决策 | `GB-ASAR` | 字符串 `decideAppUse` 与其分支 `allow` / `ask` / `refused` |

### 拒绝清单的内容（2026-10-18 复核）

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| Grok 的拒绝清单按 6 个类目组织，每个类目是"bundle id → 显示名"的映射 | `GB-ASAR` | 压缩后的 JS 中对象 `lAt`，类目 `runsShellCommands`、`runsScripts`、`holdsPasswords`、`hostsTerminalsAndAgents`、`changesSystemSettings`、`hostsGrokBot`（采集方法：`strings`，见复核记录） |
| `runsShellCommands` 含 9 个 bundle id | `GB-ASAR` | `com.apple.terminal`、`com.googlecode.iterm2`、`dev.warp.warp-stable`、`net.kovidgoyal.kitty`、`org.alacritty`、`io.alacritty`、`com.github.wez.wezterm`、`com.mitchellh.ghostty`、`co.zeit.hyper` |
| `runsScripts` 含 3 个 | `GB-ASAR` | `com.apple.scripteditor2`、`com.apple.automator`、`com.apple.shortcuts` |
| `holdsPasswords` 含 2 个 | `GB-ASAR` | `com.apple.keychainaccess`、`com.apple.passwords` |
| `hostsTerminalsAndAgents` 含 5 个，全是 Cursor 变体 | `GB-ASAR` | `com.todesktop.230313mzl4w4u92`、`co.anysphere.cursor.nightly`、`co.anysphere.cursor.lab`、`co.anysphere.cursor.alpha`、`co.anysphere.cursor.dev` |
| `changesSystemSettings` 含 1 个 | `GB-ASAR` | `com.apple.systempreferences` |
| `hostsGrokBot` 含 1 个，另有两个**前缀**同样被拒 | `GB-ASAR` | `com.anysphere.sand`；前缀 `com.anysphere.sand.`、`co.anysphere.grok-bot-` |
| 匹配规则：bundle id 去空白后**转小写**再比对；按应用名解析时同样转小写，且一个类目可有多个别名 | `GB-ASAR` | 函数 `$Ae`（`trim().toLowerCase()` 后查集合或前缀）与 `zAe`（`app_name` 经小写后查别名表） |
| **只读状态读取同样被拒**，不止点击和输入 | `GB-ASAR` | 工具分类表 `Lee` 把 `computer_app_state` 归为 `"app"` 范围，`qAe` 对 `"app"` 范围先调用 `Mee`，`Mee` 首先 `$Ae(bundleId)` 判断 |
| 拒绝文案告诉模型"让用户自己做这一步" | `GB-ASAR` | 函数 `Dee`："… is off limits to computer use. … Ask the user to do this step themselves." |
| 拒绝发生在 asar（宿主）侧，在转发给原生服务**之前** | `GB-ASAR` | `qAe` 返回 `{kind:"relay"}` 才转发；`refused` 不转发（与纠正 C-3 一致） |

### 审批触发（2026-10-20 复核）

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| Grok 在应用级做运行时审批，不逐动作审批 | `GB-ASAR` | `dist/local-exec-daemon/main.cjs` 的 `qAe`/`Mee`/`decideAppUse`：scope 为 `app` 时先解析目标，再调用 `decideAppUse(bundleId)`；`describes.action` 固定为 `use-app` |
| Grok 的应用审批只有三个结果：allow / ask / refused | `GB-ASAR` | `Mee` 的 `switch`；`qAe` 的 `scope` 表 |
| Grok 的审批卡片提供 Always allow / Allow once / Never | `GB-ASAR` | `dist/renderer/assets/chunk-view-BtE9RKtM.js` 的 `Ii` 与 i18n `NoKBgy`、`pFfO26`、`qqeAJM`；文案 `TsmRYW` / `mk09HK` / `NV+jvp` |
| Grok 的 Allow once 覆盖当前 turn，Always allow 持久并可撤销 | `GB-ASAR` | 文案 `3w8V6a` / `mFJh/I`；`recordLocalToolApproval`、`recordLocalToolStandingGrant`、`listComputerUseAllowedApps`、`revokeComputerUseAllowedApp`；设置项 `Always-allowed apps` |
| Grok 团队策略可禁止 Always allow，强制每 turn 审批 | `GB-ASAR` | `standingGrant.kind === "offered"` 分支；文案 `z6H5uV`；团队上限文案 `68SHzZ`（Always allow / Ask every time / Never allow） |
| Grok 的硬黑名单在审批之前，命中即拒绝且读也拒绝 | `GB-ASAR` | `Mee` 先调用 `$Ae(bundleId)`；scope 表把 `computer_app_state` / `computer_screenshot` 归为 `app`；类目对象 `lAt` |
| Grok 的 `computer_apps` / `computer_resolve_app` 不触发应用审批 | `GB-ASAR` | scope 表 `Oee`/`Lee`：`free` 与 `resolve` 分支直接返回 |
| Codex 在运行时做应用级审批，不按动作语义审批 | `CU-SKY-POLICY`、`CU-CLIENT` | `withComputerUsePolicy` 只把 `app` 传给 `getAppPolicy` 和 `createElicitation`；`computer-use-policy.js` 无动作分类分支 |
| Codex 的审批在 `getAppPolicy` 的 `allowed` 分支才发起 | `CU-SKY-POLICY` | `getAppPolicy` 返回 `allowed` / `denied` / `forbidden`；后两者直接抛错，不调用 `createElicitation` |
| Codex 的 elicitation 支持 session 与 always 两档 | `CU-SKY-POLICY` | `persist: policy.allowPersistentApproval ? ["session","always"] : ["session"]`；`approval_persistence` 取 `_meta.persist` |
| Codex 持久化应用审批文件为 `ComputerUseAppApprovals.json` | `CU-CLIENT` | 字符串 `ComputerUseAppApprovals.json`、`AppApprovalStore`、`persistentApprovals`、`sessionApprovedBundleIdentifiers` |
| Codex 组织策略可以拒绝应用，且不给用户同意入口 | `CU-SKY-POLICY` | `denied` → `Computer Use is blocked ... by your organization's policy`；`forbidden` → `... for safety reasons` |
| Codex 的动作级确认写在 SKILL，不是运行时闸门 | `CU-PLUGIN` | `SKILL.md` 的 “Computer Use Confirmations Policy”；`CU-SKY-POLICY` 只有应用级 `getAppPolicy`/elicitation |
| Codex 的应用审批警告提到 prompt injection | `CU-CLIENT` | 字符串 `Allowing ChatGPT to use this app introduces new risks, including ... prompt injection ...` |

### 范围与平台

| 结论 | 来源 | 证据 |
| --- | --- | --- |
| 一套实现并列提供领域能力 | `CU-APP` | 类 `ComputerUseClient.CalendarMCPServer`、`MessagesMCPServer`、`EventStreamMCPServer`、`ComputerHistoryMCPServer` |
| 另一套提供消息读取 | `GB-ASAR` | 字符串 `MessagesSnapshot`、`attachment_not_found`、`snapshotMessagesDb` |
| Grok 使用固定逻辑画布 | `GB-NATIVE` | 工具描述："Coordinates are pixels in the fixed 1280×800 screenshot canvas, with (0, 0) at the top-left" |
| Grok 有控制租约 | `GB-NATIVE` | 工具描述："computer_start_control is escalation only: it takes the Mac and moves the real cursor"、"Release remote control after the final screen-scope action"、"App targets need no session" |
| 平台实现差异 | `CU-APP`、`GB-NATIVE` | `CU-APP` 为 thin arm64；`GB-NATIVE` 为 universal (x86_64 + arm64)——只说明构建差异，不作为能力结论 |

## 复核方法

给定任一结论，按以下步骤复核：

```bash
# 1. 定位来源工件的当前版本与哈希
plutil -extract CFBundleShortVersionString raw "<app>/Contents/Info.plist"
shasum -a 256 "<binary>"

# 2. 若哈希与本文档不符，说明参考实现已更新，结论需要重新采集
# 3. 用「证据」一列的方法重新检查（注意 nm 与 strings 的区别、universal 需指定架构）
```

**哈希不匹配不等于结论失效**，只表示证据基础已变。需要重新采集才能判断结论是否仍成立。

## 已知纠正

采集过程中发现并纠正的自身错误，记录在此以免重犯。

| # | 错误 | 正确 | 影响 |
| --- | --- | --- | --- |
| C-1 | 用 `strings` 查 `AXObserverCreateWithInfoCallback` 得 0 命中，先误以为"缺少该 API"；后又误以为 Grok 使用了 `AXObserver` | 用 `nm -u -arch arm64` 确认：**Grok 确实没有 `AXObserver`**，Codex 有完整 `AXObserver*` | 修正了「Grok 用通知驱动」的隐含假设。这反而支持了 SCU 设计里"通知不可靠需要兜底"的判断——另一套实现干脆完全不用通知 |
| C-2 | 未记录 `CU-APP` 的哈希 | 该二进制在 **2026-10-16 10:31:24** 被替换（同版本号 `26.1013.1001501`，但大小由 24583472 变为 24934560，哈希由 `ac8bfe40…` 变为 `f21c31c0…`） | 本次复核在**新二进制**上重跑了全部 Codex 侧证据，结论均仍成立。若无哈希记录，这一点无法确认 |
| C-3 | 在原生二进制里找硬编码黑名单 | 黑名单在 `GB-ASAR`（Electron 侧），不在 `GB-NATIVE` | 说明 Grok 的策略判断在宿主进程而非原生服务进程。这影响"策略层放在哪一层"的参考判断 |

## 2026-10-18 复核记录：Grok 拒绝清单

**目的**：写 SCU 的最小拒绝清单之前，先复核 `GB-ASAR` 里的拒绝类目，不凭记忆写。
本次读取经用户在对话中明确允许（只读，`/Applications/Grok Bot.app/Contents/Resources/app.asar`）。

| 项 | 结果 |
| --- | --- |
| 工件版本 | Grok Bot `0.71.2`（`Info.plist` 的 `CFBundleShortVersionString`） |
| SHA-256 | `055b087a9bacc3be4e5f80c468edf2fd031dd5b928ab2e7da7e01dd10de0e860`，**与工件清单一致**，证据基础未变 |
| 清单内容的采集方法 | `strings -n 6 app.asar`，在压缩后的 JS 里读取对象 `lAt` 及相关函数。**这是文本读取，不是执行**；REA 的结构化重建（下一行）没有展开该对象字面量，所以清单内容的证据是 `strings` 而不是 REA |
| REA 6.5.0 静态分析 | 证据 ID `ev_e3ae3c7b0f4b4a4fc8dbfe197e0863032751a59759e9a171db57e1d1cdaf389f`；`derived`、`shipped-artifact`；主体 SHA-256 与上行一致；耗时约 90 秒，输出 242 MB（未入库，只记摘要） |
| REA 摘要 | 4 个窗口、11 项显式 web 偏好、6 个 context bridge API、18 个 IPC 操作、2 个原生插件绑定。与拒绝清单无关，只是确认 REA 能完整解析该工件 |
| **完整性不符** | 默认策略直接失败（`artifact_integrity_mismatch`）：ASAR 头声明的哈希与 6 个**未打包的原生文件**实际内容不符。逐一为 `dist/deps/cursor-proclist/…/cursor_proclist.node`、`dist/deps/sand-notification-settings/…/sand_notification_settings.node`、`dist/deps/tree-sitter-bash/prebuilds/darwin-arm64/tree-sitter-bash.node`、`dist/deps/tree-sitter/build/Release/tree_sitter_runtime_binding.node`、`dist/native/sand-op-launcher`、`dist/native/sand-webauthn-signer`。REA 的说明是打包工具常在写完归档后给未打包的原生二进制重新签名或剥离。**判断**：这是推断，没有做逐文件的签名核对；这 6 个文件不是 JS，与拒绝清单无关。用 `--integrity-policy record-and-continue` 继续，REA 把这些字节记为不可信 |
| 未做的事 | 没有在运行中观察拒绝行为；只读了静态代码，不能说明运行时是否还有别的分支改变结果 |

**对 SCU 的启示（设计选择，不是 Grok 的事实）**：

- Grok 的清单**同时挡住读取和操作**。SCU P0 的清单**只挡动作**，读取保持开放——这是有意的差别：
  只读档已经在对 Cursor、终端等应用做读取验证，拒绝读取会让"读 Cursor 自己的界面来定位问题"这类用法失效。
  这一点是否要收紧，待定，在 `docs/architecture/policy_layer.md` 记为待决。
- `hostsTerminalsAndAgents` 里**只有 Cursor**。其他代理宿主（Codex、ChatGPT、VS Code 系）在 Grok 的清单里没有，
  SCU 若要覆盖，需要自己核实它们的 bundle id，不能照抄。

## 采集时的新发现

复核过程中注意到一个此前未记录的机制，供后续设计参考（当前未纳入 SCU 设计）：

**Grok 的错误返回携带升级建议。** 除错误码外，返回结构中含
`escalation: {recommended, reason}`，并有 `escalationByCode` / `reasonByEscalation`
两张映射表。即：**错误码不只表达"出了什么错"，还表达"下一步该做什么"。**

这与 SCU 已设计的 `retry` 字段语义接近，但更具体——`retry` 只有六种取值，
而升级建议是按错误码逐条给出的。是否值得采用，待实现时评估。

## 2026-10-19 REA 复核：工具面与原生入口

**目的**：回答"同样的功能上 SCU 与两套实现差多少"。本轮只采信重新读到的字节，
不重复 2026-10-18 的结论；方法为 REA 6.5 的 `open_binary` / `inspect_macho` / `inspect_analysis_view`（Mach-O），
Codex 侧另直接读插件文本。

| 项 | 结果 |
| --- | --- |
| 工件清单漂移 | 本机 Codex 插件缓存当前只有 `computer-use/1.0.1000366`（`plugin.json` 版本一致）；清单里的 `1.0.1001501` 与 `unified-computer-use/26.1013.31256` **在本机不存在**。`@oai/sky 0.7.8`、`@oai/cua 0.2.6`、`@oai/cua-repl 0.1.0` 在 ChatGPT.app 内，与清单一致 |
| `CU-APP`（sha256 `f21c31c0…`，未变） | REA 证据 `ev_5a22f67e1b5c33c7116c5856aaae1583c76753ca90044feadd1aa493f0efb2c5`。导入含完整 `AXObserver*`（4 个）、`AXUIElementCopyMultipleAttributeValues`、参数化属性、`AXUIElementPerformAction`、`AXUIElementSetAttributeValue`、`AXUIElementCopyElementAtPosition`；截图相关 `CGImage*`、`CGWindowList*`、`SCStreamFrameInfo*`；**没有 `CGEventCreate*` / `CGEventPost` 输入注入符号**（只有 `CGEventGetFlags`），`NSEvent` 类被导入。判断（推断，未验证）：该二进制承担 AX 读取/动作与捕获，合成输入不在这一层 |
| `GB-NATIVE`（sha256 `ebcb4aeb…`，未变） | REA 证据 `ev_04b02b686eff735c5161d53704faaf15e3c6535ddb65b39285e1965815b603e7`（摘要）与 `ev_d2d4027251f9c1bc284ccecb21292c9c2338aab754e07d98e3579cbd8ba2921d`（完整 Mach-O）。导入含 `AXUIElementSetAttributeValue`、`AXUIElementPerformAction`、`AXUIElementCopyElementAtPosition`、`AXUIElementIsAttributeSettable`；`CGEventCreateMouseEvent`、`CGEventCreateKeyboardEvent`、`CGEventCreateScrollWheelEvent2`、`CGEventKeyboardSetUnicodeString`；`SCStreamConfiguration`、`SCShareableContent`、`SCScreenshotManager`；**无 `AXObserver*`**（与纠正 C-1 的 `nm` 结论一致） |
| Codex 工具面（1.0.1000366） | `skills/computer-use/SKILL.md` 的 API 类型：`click`（`element_index` 或 `x`/`y`）、`drag`、`get_app_state`（text + screenshot，默认 diff）、`list_apps`、`perform_secondary_action`、`press_key`、`scroll`、`select_text`、`set_value`、`type_text`；动作返回 `Promise<void>`；`get_app_state` 会自动启动未运行的应用；动作后自动等待约 1 秒，有加载指示时最多再加 5 秒 |
| Grok 工具面 | 沿用 2026-10-16 的 `GB-NATIVE` 工具名清单（14 个，见上文）；本轮没有新的运行时观察 |

**未做的事**：没有运行两套实现做任务对照；没有在运行中观察它们的动作与失效行为。
因此本节的用途是**能力面对照**，不是效果对照。
