import Foundation
import SCUCore
import SCUWire

/// 工具目录。只读工具恒有；**会改变桌面状态的工具（`isAction`）只在启动时显式开启动作档才暴露**，
/// 未开启时它们不出现在 `tools/list`，调用也按未知工具处理。每个工具都带 `readOnlyHint` 如实声明。
// @project-doc docs/interfaces/mcp_surface.md#tool_catalog
enum ScuTool: String, CaseIterable {
    case checkPermissions = "check_permissions"
    case listApps = "list_apps"
    case getAXState = "get_ax_state"
    case getScreenshot = "get_screenshot"
    case launchApp = "launch_app"
    case click
    case clickAt = "click_at"
    case scrollAt = "scroll_at"
    case drag
    case typeText = "type_text"
    case pressKey = "press_key"
    case setValue = "set_value"

    var isAction: Bool {
        self != .checkPermissions && self != .listApps && self != .getAXState && self != .getScreenshot
    }

    static func available(actions: Bool) -> [ScuTool] {
        allCases.filter { actions || !$0.isAction }
    }

    var title: String {
        switch self {
        case .checkPermissions: return "检查辅助功能权限"
        case .listApps: return "列出应用"
        case .getAXState: return "读取无障碍树"
        case .getScreenshot: return "截取窗口并叠加标签"
        case .launchApp: return "启动应用"
        case .click: return "点击元素"
        case .clickAt: return "按截图坐标点击"
        case .scrollAt: return "按截图坐标滚动"
        case .drag: return "按截图坐标拖拽"
        case .typeText: return "向元素输入文本"
        case .pressKey: return "向元素发送按键"
        case .setValue: return "直接写入元素的值"
        }
    }

    var description: String {
        switch self {
        case .checkPermissions:
            return """
                检查启动本服务的宿主应用是否已获得 macOS 辅助功能权限。只读。\
                权限归属于宿主应用（启动本服务的程序），不是整台机器；未授权时 get_ax_state 无法读取。
                """
        case .listApps:
            return """
                列出可读取的正在运行的应用，每行 pid、名称、bundle id（制表符分隔）。只读。\
                get_ax_state 需要这里的 pid。
                """
        case .getScreenshot:
            return """
                截取 get_ax_state 令牌对应的目标窗口，并在图上叠加可交互元素的短标签；只读，需要屏幕录制权限。\
                返回 PNG 图像与 screenshot_id；图像坐标以窗口左上角为原点，`scale` 是图像像素 / 窗口点。\
                文本元素表仍是权威：徽标太小、重叠或被裁掉时，按 get_ax_state 的标签选择。\
                屏幕录制权限按宿主应用归属，未授予时返回 system_permission_missing。
                """
        case .scrollAt:
            return """
                在 get_screenshot 的截图坐标 (x, y) 投递滚轮事件。会改变应用的状态。\
                坐标以截图左上角为原点，单位是图像像素；必须给出令牌与 screenshot_id。\
                dy > 0 表示向下滚，dx > 0 表示向右滚；增量为 0 会被拒绝。\
                点击前会激活并 raise 目标窗口；滚动后重读 AX 树并比较全图像素比例。\
                返回 noOpSuspected=true 时不要反复滚；先用 get_screenshot 核实。
                """
        case .drag:
            return """
                在 get_screenshot 的截图坐标内从 (from_x, from_y) 拖到 (to_x, to_y)。\
                会移动真实光标并可能改变应用状态（移动文件/列表项/画布）。\
                坐标以截图左上角为原点；必须给出令牌与 screenshot_id；duration_ms 默认 400，范围 100...2000。\
                点击前会激活并 raise 目标窗口；拖拽后重读 AX 树并比较全图像素比例。\
                这是高风险动作：调用前应确认起点/终点，不要对不确定的界面拖拽。
                """
        case .launchApp:
            return """
                启动（或激活）一个应用。identifier 可以是 bundle id、显示名或 .app 路径。\
                启动前会解析 bundle id 并检查拒绝类目；终端、脚本运行器、密码管理器、系统设置等会被拒绝。\
                已在运行的应用会被激活而不是重复启动。启动后会等待 10 秒确认进程出现。\
                这是会改变桌面状态的动作；启动成功后用 list_apps 或 get_ax_state 继续。
                """
        case .clickAt:
            return """
                在 get_screenshot 的截图坐标 (x, y) 投递一次鼠标左键点击。会改变应用的状态。\
                坐标以截图左上角为原点，单位是图像像素；必须同时给出令牌与 screenshot_id。\
                点击前会核对截图属于该令牌、窗口位置/缩放未变；坐标越界返回 invalid_coordinates。\
                返回的是**观察到的效果**：点击后重读 AX 树，报告结构是否变化。\
                坐标点击可能只改变像素而不改 AX 树，这时会报 noOpSuspected=true；\
                请用 get_screenshot 核实，不要反复点。屏幕保护/遮挡等情况下可能点到别处，\
                调用前应确认目标窗口可见且在前台。
                """
        case .click:
            return """
                点击元素：对 get_ax_state 输出里的某个句柄执行 AXPress（无障碍的"按下"，不移动真实鼠标）。会改变应用的状态。\
                必须给出该输出的令牌，并用句柄或标签指定目标（二者二选一）；令牌失效（界面结构变了）、目标已不是读取时的那个、\
                或应用属于拒绝类目（终端、脚本运行器、密码管理器、系统设置、Cursor 等）时，动作不会执行，并返回分类的错误。\
                返回的是**观察到的效果**，不是"成功"的保证：已投递只表示系统没有报错；\
                之后会重读界面直到稳定（最多约 3 秒），报告结构是否变化。\
                "疑似空操作"表示界面稳定后结构没有任何变化，请核实后再继续。\
                结构变化时旧令牌作废，需重新 get_ax_state。不支持 AXPress 的元素返回 unsupported_operation。
                """
        case .typeText:
            return """
                把文本逐字输入到指定元素：先聚焦它，再向目标进程投递按键事件。会改变应用的状态。\
                必须给出 get_ax_state 输出的令牌，并用句柄或标签指定目标（二者二选一）；令牌失效、目标已不是读取时的那个、\
                或应用属于拒绝类目时不会执行，并返回分类的错误。\
                输入经过应用的按键处理（与"设值"不同），可以触发自动完成、实时校验与回车等行为。\
                文本里的换行与制表符分别按 Return 与 Tab 投递。\
                返回的是**观察到的效果**，不是"成功"的保证：之后会重读界面直到稳定，报告结构是否变化；\
                结构变化时旧令牌作废，需重新 get_ax_state。
                """
        case .pressKey:
            return """
                向指定元素发送一个按键或组合键（先聚焦它）：如 Return、Tab、esc、cmd+c、shift+左方向键。\
                键名用 + 分隔，修饰键顺序无关；不认识键名会拒绝，不猜测。会改变应用的状态。\
                必须给出 get_ax_state 输出的令牌，并用句柄或标签指定目标（二者二选一）；令牌失效、目标对不上或应用属于拒绝类目时不会执行。\
                返回的是**观察到的效果**，不是"成功"的保证；结构变化时旧令牌作废。
                """
        case .setValue:
            return """
                直接把值写入指定元素（无障碍设值）。会改变应用的状态。\
                这是默认的写入路径：不经过键盘与输入法，速度快、不触发按键处理；\
                因此也不会触发自动完成、实时校验这类"输入过程中"的行为。\
                只有元素声明了可写的 AXValue 时才执行；不支持时返回 unsupported_operation，\
                不会自动改成逐字输入（两者的副作用不同）。必须给出令牌，并用句柄或标签指定目标（二者二选一）；\
                值变化后令牌作废，需要重新 get_ax_state。
                """
        case .getAXState:
            return """
                读取指定应用的无障碍树，返回文本化元素表。只读，不会操作应用。\
                每行一个元素，缩进表示层级，格式 [a] [角色#句柄] "标题" 属性… frame=(x,y,w,h)。\
                可交互元素前的 [a] 是本次快照的标签；click / type_text / press_key / set_value 可以用 label 代替 handle。\
                输出带一个令牌，句柄与令牌配对、只在该令牌有效期内可用（界面结构变化后令牌失效）；click / type_text / press_key / set_value（仅动作档提供）接受它们。\
                读取有总时间预算，耗尽时输出会明确标注"已截断"。\
                元素多于 max_elements 时按层级优先显示（先看整体结构，不是先序的前 N 个），\
                被折叠的元素行尾标 (折叠 N)，表示其下还有 N 个后代未显示。\
                要看某一部分，用 focus（按标题、描述、值或标识符的子串匹配）和/或 focus_role（角色）：\
                只展开匹配的子树，并在前面用 "@ 祖先链" 说明它在哪里。\
                推荐流程：先不带 focus 看概览，再用 focus 逐块展开。\
                Electron/Chromium 应用的树大小可能随读取时机变化（原因未确定），读到的树明显偏小时可稍后重读。\
                先用 list_apps 取得 pid。
                """
        }
    }

    var inputSchema: JSONValue {
        switch self {
        case .checkPermissions, .listApps:
            return ["type": "object", "properties": [:], "additionalProperties": false]
        case .getScreenshot:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                ],
                "required": ["token"],
                "additionalProperties": false,
            ]
        case .launchApp:
            return [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "bundle id、显示名或 .app 路径"],
                ],
                "required": ["app"],
                "additionalProperties": false,
            ]
        case .clickAt:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "screenshot_id": ["type": "string", "description": "get_screenshot 返回的 screenshot_id"],
                    "x": ["type": "integer", "minimum": 0, "description": "截图内的 x 像素（左上角原点）"],
                    "y": ["type": "integer", "minimum": 0, "description": "截图内的 y 像素（左上角原点）"],
                ],
                "required": ["token", "screenshot_id", "x", "y"],
                "additionalProperties": false,
            ]
        case .scrollAt:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "screenshot_id": ["type": "string", "description": "get_screenshot 返回的 screenshot_id"],
                    "x": ["type": "integer", "minimum": 0, "description": "滚动位置 x（截图像素）"],
                    "y": ["type": "integer", "minimum": 0, "description": "滚动位置 y（截图像素）"],
                    "dx": ["type": "integer", "description": "水平增量；正数向右，默认 0"],
                    "dy": ["type": "integer", "description": "垂直增量；正数向下"],
                ],
                "required": ["token", "screenshot_id", "x", "y", "dy"],
                "additionalProperties": false,
            ]
        case .drag:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "screenshot_id": ["type": "string", "description": "get_screenshot 返回的 screenshot_id"],
                    "from_x": ["type": "integer", "minimum": 0, "description": "起点 x（截图像素）"],
                    "from_y": ["type": "integer", "minimum": 0, "description": "起点 y（截图像素）"],
                    "to_x": ["type": "integer", "minimum": 0, "description": "终点 x（截图像素）"],
                    "to_y": ["type": "integer", "minimum": 0, "description": "终点 y（截图像素）"],
                    "duration_ms": ["type": "integer", "minimum": 100, "maximum": 2000, "description": "拖拽时长，默认 400"],
                ],
                "required": ["token", "screenshot_id", "from_x", "from_y", "to_x", "to_y"],
                "additionalProperties": false,
            ]
        case .click:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "该输出元素表里的句柄编号（[角色#句柄] 的数字）；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签（[a] 的字母）；与 handle 二选一"],
                ],
                "required": ["token"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .typeText:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "要输入到的元素句柄；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签；与 handle 二选一"],
                    "text": ["type": "string", "minLength": 1, "maxLength": 10000, "description": "要输入的文本"],
                ],
                "required": ["token", "text"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .pressKey:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "接收按键的元素句柄（会先聚焦它）；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签；与 handle 二选一"],
                    "key": [
                        "type": "string", "minLength": 1,
                        "description": "按键或组合键，如 Return、Tab、esc、cmd+c；修饰键可用 cmd/shift/alt/ctrl",
                    ],
                ],
                "required": ["token", "key"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .setValue:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "要写入的元素句柄；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签；与 handle 二选一"],
                    "value": ["type": "string", "maxLength": 10000, "description": "要写入的值"],
                ],
                "required": ["token", "value"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .getAXState:
            return [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer", "description": "目标应用的进程 id，来自 list_apps"],
                    "max_depth": [
                        "type": "integer", "minimum": 0, "maximum": .int(scuMaxTreeDepth),
                        "description": .string("读取深度上限，默认 \(Self.defaultDepth)"),
                    ],
                    "budget_ms": [
                        "type": "integer", "minimum": .int(scuTreeBudgetMsRange.lowerBound),
                        "maximum": .int(scuTreeBudgetMsRange.upperBound),
                        "description": .string("读取的总时间预算（毫秒），默认 \(scuDefaultTreeBudgetMs)"),
                    ],
                    "focus": [
                        "type": "string",
                        "description": "只显示匹配的子树：与标题、描述、值、标识符做不区分大小写的子串匹配。可与 focus_role 同时给出（需同时满足）",
                    ],
                    "focus_role": [
                        "type": "string",
                        "description": "只显示该角色的子树，如 AXButton 或 Button（等价）",
                    ],
                    "max_elements": [
                        "type": "integer", "minimum": .int(ElementTable.maxElementsRange.lowerBound),
                        "maximum": .int(ElementTable.maxElementsRange.upperBound),
                        "description": .string("最多输出的元素数，默认 \(ElementTable.defaultMaxElements)"),
                    ],
                ],
                "required": ["pid"],
                "additionalProperties": false,
            ]
        }
    }

    var definition: JSONValue {
        [
            "name": .string(rawValue),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(!isAction),
                "destructiveHint": .bool(isAction),
                "idempotentHint": .bool(!isAction),
                "openWorldHint": .bool(isAction),
            ],
        ]
    }

    static let defaultDepth = scuDefaultTreeDepth

    // MARK: - 执行

    struct ArgumentError: Error { var message: String }

    /// 执行工具。参数错误与原生层错误都以 `Outcome.isError` 返回，而不是协议错误：
    /// 模型能读到文本并自行纠正。
    struct ImageContent: Sendable {
        var data: Data
        var mimeType: String
    }

    struct Outcome {
        var text: String
        var isError: Bool
        var images: [ImageContent] = []
    }

    func run(arguments: JSONValue?, session: DesktopSession, actionsEnabled: Bool = false) -> Outcome {
        // 纵深防御：接入层本就不会把动作工具派发到这里。
        if isAction, !actionsEnabled {
            return Outcome(text: "[tool_unavailable] 动作档未开启（启动 scu mcp 时加 --actions）。", isError: true)
        }
        do {
            let args = try Self.objectArguments(arguments)
            switch self {
            case .checkPermissions:
                try Self.requireNoExtra(args, allowed: [])
                let ok = try session.reader.checkPermissions()
                return Outcome(
                    text: ok
                        ? "辅助功能：已授予（针对启动本服务的宿主应用）"
                        : "辅助功能：未授予。请在 系统设置 > 隐私与安全性 > 辅助功能 中给启动本服务的宿主应用授权；权限按宿主归属，不是整台机器。",
                    isError: false)

            case .listApps:
                try Self.requireNoExtra(args, allowed: [])
                let apps = try session.reader.listApps()
                let lines = apps.map { "\($0.pid)\t\($0.name)\t\($0.bundleId ?? "-")" }
                return Outcome(text: lines.isEmpty ? "（没有可读取的应用）" : lines.joined(separator: "\n"), isError: false)

            case .getAXState:
                try Self.requireNoExtra(
                    args, allowed: ["pid", "max_depth", "budget_ms", "max_elements", "focus", "focus_role"])
                guard let pid = try Self.int(args, "pid", range: 1...Int(Int32.max), required: true) else {
                    throw ArgumentError(message: "缺少参数 pid")
                }
                let depth = try Self.int(args, "max_depth", range: 0...scuMaxTreeDepth, required: false) ?? Self.defaultDepth
                let budget = try Self.int(args, "budget_ms", range: scuTreeBudgetMsRange, required: false)
                    ?? scuDefaultTreeBudgetMs
                let maxElements = try Self.int(
                    args, "max_elements", range: ElementTable.maxElementsRange, required: false)
                    ?? ElementTable.defaultMaxElements

                let focusText = try Self.string(args, "focus")
                let focusRole = try Self.string(args, "focus_role")
                let focus = (focusText != nil || focusRole != nil)
                    ? ElementTable.Focus(text: focusText, role: focusRole) : nil

                let state = try session.readState(pid: Int32(pid), maxDepth: depth, budgetMs: budget)
                let reading = state.reading
                let table = ElementTable.render(reading.root, maxElements: maxElements, focus: focus)
                let head = Self.header(
                    pid: pid, table: table, depthLimit: depth, budgetMs: budget,
                    truncated: reading.truncated, focused: focus != nil, token: state.token,
                    policy: state.policy, appName: state.appName, actionsEnabled: actionsEnabled)
                return Outcome(text: table.text.isEmpty ? head : head + "\n" + table.text, isError: false)

            case .getScreenshot:
                try Self.requireNoExtra(args, allowed: ["token"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                let shot = try session.captureScreenshot(token: token)
                let overlaid = ScreenshotOverlay.render(capture: shot.capture, labels: shot.labels) ?? shot.capture.png
                let text = """
                    screenshot_id=\(shot.id) 图像 \(shot.capture.width)x\(shot.capture.height) scale=\(String(format: "%.3f", shot.capture.scale)) window=(\(Int(shot.capture.windowFrame.x)),\(Int(shot.capture.windowFrame.y)),\(Int(shot.capture.windowFrame.width)),\(Int(shot.capture.windowFrame.height)))
                    图上 [a] 是快照标签；文本表可能因 max_elements/focus 只显示一部分，未在文本表出现的标签也仍可用。\n标签只对本次令牌有效；截图绑定窗口位置与缩放，窗口移动后需要重新截。
                    """
                return Outcome(
                    text: text, isError: false,
                    images: [Self.ImageContent(data: overlaid, mimeType: "image/png")])

            case .click:
                try Self.requireNoExtra(args, allowed: ["token", "handle", "label"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                let (handle, label) = try Self.targetHandle(args, token: token, session: session)
                let report = try session.click(token: token, handle: handle)
                return Outcome(
                    text: Self.actionText(report, handle: handle, verb: "点击", labelRef: label), isError: false)

            case .launchApp:
                try Self.requireNoExtra(args, allowed: ["app"])
                guard let app = try Self.string(args, "app"), !app.isEmpty else {
                    throw ArgumentError(message: "缺少参数 app")
                }
                let launched = try session.launchApp(identifier: app)
                let bundle = launched.bundleId ?? "-"
                return Outcome(
                    text: "应用已在运行或已启动：\(launched.name)（pid \(launched.pid)，bundle \(bundle)）。\n用 list_apps 或 get_ax_state 继续。",
                    isError: false)

            case .clickAt:
                try Self.requireNoExtra(args, allowed: ["token", "screenshot_id", "x", "y"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                guard let screenshotID = try Self.string(args, "screenshot_id") else {
                    throw ArgumentError(message: "缺少参数 screenshot_id")
                }
                guard let x = try Self.int(args, "x", range: 0...100_000, required: true),
                    let y = try Self.int(args, "y", range: 0...100_000, required: true)
                else {
                    throw ArgumentError(message: "x 与 y 必须是坐标整数")
                }
                let report = try session.clickAt(
                    token: token, screenshotID: screenshotID, x: Double(x), y: Double(y))
                return Outcome(
                    text: Self.coordinateText(
                        report, action: "点击", detail: "截图坐标 (\(x), \(y))"), isError: false)

            case .scrollAt:
                try Self.requireNoExtra(args, allowed: ["token", "screenshot_id", "x", "y", "dx", "dy"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                guard let screenshotID = try Self.string(args, "screenshot_id") else {
                    throw ArgumentError(message: "缺少参数 screenshot_id")
                }
                guard let x = try Self.int(args, "x", range: 0...100_000, required: true),
                    let y = try Self.int(args, "y", range: 0...100_000, required: true),
                    let dy = try Self.int(args, "dy", range: -100_000...100_000, required: true)
                else {
                    throw ArgumentError(message: "x、y、dy 必须是坐标整数")
                }
                let dx = try Self.int(args, "dx", range: -100_000...100_000, required: false) ?? 0
                let report = try session.scrollAt(
                    token: token, screenshotID: screenshotID,
                    x: Double(x), y: Double(y), dx: Double(dx), dy: Double(dy))
                return Outcome(
                    text: Self.coordinateText(
                        report, action: "滚动",
                        detail: "截图坐标 (\(x), \(y)) 增量 (\(dx), \(dy))"), isError: false)

            case .drag:
                try Self.requireNoExtra(
                    args, allowed: [
                        "token", "screenshot_id", "from_x", "from_y", "to_x", "to_y", "duration_ms",
                    ])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                guard let screenshotID = try Self.string(args, "screenshot_id") else {
                    throw ArgumentError(message: "缺少参数 screenshot_id")
                }
                guard let fromX = try Self.int(args, "from_x", range: 0...100_000, required: true),
                    let fromY = try Self.int(args, "from_y", range: 0...100_000, required: true),
                    let toX = try Self.int(args, "to_x", range: 0...100_000, required: true),
                    let toY = try Self.int(args, "to_y", range: 0...100_000, required: true)
                else {
                    throw ArgumentError(message: "from_x、from_y、to_x、to_y 必须是坐标整数")
                }
                let duration = try Self.int(args, "duration_ms", range: 100...2_000, required: false) ?? 400
                let report = try session.drag(
                    token: token, screenshotID: screenshotID,
                    fromX: Double(fromX), fromY: Double(fromY),
                    toX: Double(toX), toY: Double(toY), durationMs: duration)
                return Outcome(
                    text: Self.coordinateText(
                        report, action: "拖拽",
                        detail: "截图坐标 (\(fromX), \(fromY)) → (\(toX), \(toY))"), isError: false)

            case .typeText:
                try Self.requireNoExtra(args, allowed: ["token", "handle", "label", "text"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                let (handle, label) = try Self.targetHandle(args, token: token, session: session)
                guard let text = try Self.string(args, "text"), !text.isEmpty else {
                    throw ArgumentError(message: "text 不能为空")
                }
                guard text.count <= 10000 else { throw ArgumentError(message: "text 最长 10000 个字符") }
                let typed = try session.typeText(token: token, handle: handle, text: text)
                return Outcome(
                    text: Self.actionText(typed, handle: handle, verb: "输入", labelRef: label), isError: false)

            case .pressKey:
                try Self.requireNoExtra(args, allowed: ["token", "handle", "label", "key"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                let (handle, label) = try Self.targetHandle(args, token: token, session: session)
                guard let key = try Self.string(args, "key"), !key.isEmpty else {
                    throw ArgumentError(message: "key 不能为空")
                }
                let pressed = try session.pressKey(token: token, handle: handle, key: key)
                return Outcome(
                    text: Self.actionText(pressed, handle: handle, verb: "按键", labelRef: label), isError: false)

            case .setValue:
                try Self.requireNoExtra(args, allowed: ["token", "handle", "label", "value"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                let (handle, label) = try Self.targetHandle(args, token: token, session: session)
                guard let value = try Self.stringAllowingEmpty(args, "value") else {
                    throw ArgumentError(message: "缺少参数 value")
                }
                guard value.count <= 10000 else { throw ArgumentError(message: "value 最长 10000 个字符") }
                let written = try session.setValue(token: token, handle: handle, value: value)
                return Outcome(
                    text: Self.actionText(written, handle: handle, verb: "设值", labelRef: label), isError: false)
            }
        } catch let e as ArgumentError {
            return Outcome(text: "[invalid_argument] \(e.message)", isError: true)
        } catch let e as WireError {
            return Outcome(text: Self.describe(e), isError: true)
        } catch {
            return Outcome(text: "[internal_error] \(error)", isError: true)
        }
    }

    static func header(
        pid: Int, table: ElementTable.Result, depthLimit: Int, budgetMs: Int, truncated: Bool, focused: Bool,
        token: SnapshotToken, policy: PolicyGate.Decision = .allow, appName: String? = nil, actionsEnabled: Bool = false
    ) -> String {
        var h = "# pid=\(pid) 令牌 \(token) 元素 \(table.total)"
        if focused {
            let m = table.matches ?? 0
            if m == 0 {
                h += "；没有元素匹配 focus。"
                if truncated { h += "树不完整（见下），匹配的元素可能没读到。" }
            } else {
                h += "；focus 命中 \(m) 处（范围内 \(table.scope) 个元素）"
                if m > ElementTable.maxFocusMatches { h += "，仅展开前 \(ElementTable.maxFocusMatches) 处" }
                h += "，显示 \(table.shown)。以 @ 开头的行是命中子树的祖先链。"
            }
        } else if table.shown < table.total {
            h += "，显示 \(table.shown)。"
        } else {
            h += "。"
        }
        if table.shown < table.scope {
            h += "按层级优先显示；行尾 (折叠 N) 表示其下还有 N 个后代未显示。用 focus 看某一部分，或调大 max_elements。"
        }
        h += "句柄只在该令牌有效期内可用（界面结构变化后令牌失效）；"
        if !table.labels.isEmpty {
            h += "可交互元素前的 [a] 是本次快照的标签，动作工具可用 label 代替 handle。"
        }
        if table.labelTotal > ElementTable.maxLabels {
            h += "可交互元素超过 \(ElementTable.maxLabels) 个，只标了前 \(ElementTable.maxLabels) 个。"
        }
        h += actionsEnabled ? "用 click(token, handle) 点击，用 type_text / press_key 输入，或用 set_value 直接写值。" : "目前没有工具接受句柄（动作档未开启）。"
        if case .deny(let category) = policy {
            h += "\n⚠️ 策略：\(appName ?? "该应用") 属于拒绝类目 \(category)，对它的动作会被拒绝（读取不受限）。"
        }
        if truncated { h += "\n⚠️ 已截断：\(budgetMs) 毫秒的读取预算耗尽，树不完整。" }
        if table.depth >= depthLimit { h += "\n⚠️ 已达深度上限 \(depthLimit)：更深的节点未读取。" }
        return h
    }

    /// 按 `code` 分支给出提示，不解析 `message`（error_taxonomy.md）。
    static func describe(_ e: WireError) -> String {
        var s = "[\(e.code)] \(e.message)（retry=\(e.retry)）"
        switch e.code {
        case "stale_snapshot", "element_gone":
            s += "\n请重新调用 get_ax_state 取得新令牌与标签/句柄；用 focus 按文本重新定位目标。"
        case "stale_geometry":
            s += "\n窗口位置/缩放或截图已变化：重新 get_screenshot，使用新的 screenshot_id。"
        case "app_not_found":
            s += "\n用 bundle id、显示名或完整 .app 路径重试；不要猜一个相近的名字。"
        case "target_switched":
            s += "\n令牌属于之前读取的另一个应用：请对要操作的应用重新 get_ax_state。"
        case "unsupported_operation":
            s += "\n该元素不能被点击；可尝试它的父元素或子元素，或换一个元素。"
        case "invalid_coordinates":
            s += "\n坐标不在截图范围内：重新 get_screenshot，用截图里的坐标。"
        case "policy_denied":
            s += "\n这是不可协商的拒绝，不要重试或换用别的方式绕过；请告知用户由他自己完成这一步。"
        default:
            break
        }
        if e.code == "system_permission_missing" {
            if e.message.contains("屏幕录制") {
                s += "\n权限按宿主应用归属：请在 系统设置 > 隐私与安全性 > 屏幕录制 中授权启动本服务的宿主应用，然后重启该宿主。"
            } else {
                s += "\n权限按宿主应用归属：请给启动本服务的应用授予辅助功能权限，可用 check_permissions 确认。"
            }
        }
        return s
    }

    /// 坐标点击结果。没有元素身份，只报告树变化；像素变化需要截图 diff。
    static func coordinateText(_ r: CoordinateReport, action: String, detail: String) -> String {
        func flag(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "unknown" }
        let secs = String(format: "%.1f", r.elapsed)
        var lines = [
            "已对 pid \(r.pid) 的\(detail) 投递\(action)。",
            "effect: observed=\(flag(r.observed)) treeChanged=\(flag(r.treeChanged)) "
                + "screenshotChanged=\(flag(r.screenshotChanged)) "
                + "diffRatio=\(r.diffRatio.map { String(format: "%.4f", $0) } ?? "unknown") "
                + "geometryChanged=\(flag(r.geometryChanged)) "
                + "noOpSuspected=\(flag(r.noOpSuspected)) elapsed=\(secs)s",
        ]
        if !r.observed {
            lines.append("⚠️ 点击已投递，但事后读不到界面，不知道效果；请用 get_screenshot 核实。")
        } else if r.treeChanged == true {
            lines.append("界面结构已变化，旧令牌已作废，请重新 get_ax_state。")
        } else if r.treeChanged == false, r.screenshotChanged == true {
            lines.append("AX 树没有变化，但截图检测到像素变化；可能是画布/悬停/局部刷新。")
        } else if r.geometryChanged {
            lines.append("⚠️ 点击后窗口位置或缩放变化，截图 diff 不可比；重新 get_screenshot 核实。")
        } else if r.noOpSuspected {
            lines.append(
                "⚠️ AX 树与截图都没有明显变化。坐标点击可能没点到或应用忽略了点击；不要重复点。")
        }
        if r.tokenInvalidated {
            lines.append("旧令牌已失效；重新 get_ax_state 后再继续。")
        }
        return lines.joined(separator: "\n")
    }

    /// 点击结果的文本：先一行机器可读的摘要，再用人话解释。只陈述观察到的事实。
    static func actionText(
        _ r: DesktopSession.ClickReport, handle: Int, verb: String, labelRef: String? = nil
    ) -> String {
        func flag(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "unknown" }
        let label = [r.target.title, r.target.description].compactMap { $0 }.first { !$0.isEmpty }
        var name = "\(r.target.role)#\(handle)"
        if let labelRef { name = "[\(labelRef)] " + name }
        if let label { name += " " + ElementTable.quote(label) }
        let secs = String(format: "%.1f", r.elapsed)
        var lines = [
            "已对 \(name)（pid \(r.pid)）投递\(verb)。",
            "effect: delivered=\(flag(r.delivered)) observed=\(flag(r.observed)) converged=\(flag(r.converged)) "
                + "treeChanged=\(flag(r.treeChanged)) targetChanged=\(flag(r.targetChanged)) "
                + "noOpSuspected=\(flag(r.noOpSuspected)) polls=\(r.polls) elapsed=\(secs)s",
        ]
        if !r.observed {
            lines.append(
                "⚠️ 动作已投递，但事后读不到界面（\(r.observationError ?? "未知原因")），不知道效果；请用 get_ax_state 确认。")
        } else if r.treeChanged == true {
            lines.append("界面结构已变化，旧令牌已作废，请重新 get_ax_state。")
        } else if r.noOpSuspected == true {
            lines.append(
                "⚠️ 疑似空操作：界面稳定后结构没有任何变化。也可能动作只改变了无障碍树之外的东西（剪贴板、文件、窗口外状态），"
                    + "请核实后再继续。令牌仍有效。")
        } else if r.treeChanged == nil {
            lines.append("读取被截断，无法判断结构是否变化；令牌未作废，下一次动作会由原生层再核对一遍目标。")
        }
        if r.observed, !r.converged {
            lines.append("⚠️ 界面在 \(secs) 秒上限内没有稳定，读到的可能是中间状态；稍后再读。")
        }
        if r.targetChanged == true, r.treeChanged != true {
            lines.append("目标元素已不在原位置（已消失或被替换）。")
        }
        return lines.joined(separator: "\n")
    }

    /// 解析动作目标：`handle` 与 `label` 必须二选一。
    static func targetHandle(
        _ args: [String: JSONValue], token: String, session: DesktopSession
    ) throws -> (handle: Int, label: String?) {
        let label = try Self.string(args, "label")
        let handle = try Self.int(args, "handle", range: 1...Int(Int32.max), required: false)
        guard (label == nil) != (handle == nil) else {
            throw ArgumentError(message: "handle 与 label 必须二选一")
        }
        if let label {
            return (try session.resolveLabel(token: token, label: label), label)
        }
        return (handle!, nil)
    }

    // MARK: - 参数校验

    static func objectArguments(_ v: JSONValue?) throws -> [String: JSONValue] {
        guard let v, v != .null else { return [:] }
        guard case .object(let o) = v else { throw ArgumentError(message: "arguments 必须是对象") }
        return o
    }

    /// 拒绝未声明的参数：拼错的参数名被静默忽略，调用方会以为生效了。
    static func requireNoExtra(_ args: [String: JSONValue], allowed: Set<String>) throws {
        let extra = Set(args.keys).subtracting(allowed).sorted()
        if !extra.isEmpty { throw ArgumentError(message: "未知参数：\(extra.joined(separator: "、"))") }
    }

    static func string(_ args: [String: JSONValue], _ name: String) throws -> String? {
        guard let v = args[name] else { return nil }
        guard let s = v.stringValue else { throw ArgumentError(message: "参数 \(name) 必须是字符串") }
        // 空串等价于未给出：模型常把"不需要的可选参数"填成空串。
        return s.isEmpty ? nil : s
    }

    /// 与 `string` 相同，但保留空串——设值的空串是"清空这个字段"，是有意义的值。
    static func stringAllowingEmpty(_ args: [String: JSONValue], _ name: String) throws -> String? {
        guard let v = args[name] else { return nil }
        guard let s = v.stringValue else { throw ArgumentError(message: "参数 \(name) 必须是字符串") }
        return s
    }

    static func int(
        _ args: [String: JSONValue], _ name: String, range: ClosedRange<Int>, required: Bool
    ) throws -> Int? {
        guard let v = args[name] else {
            if required { throw ArgumentError(message: "缺少参数 \(name)") }
            return nil
        }
        guard let n = v.intValue else { throw ArgumentError(message: "参数 \(name) 必须是整数") }
        guard range.contains(n) else {
            throw ArgumentError(message: "参数 \(name) 必须在 \(range.lowerBound)...\(range.upperBound)")
        }
        return n
    }
}
