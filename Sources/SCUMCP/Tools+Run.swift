import Foundation
import SCUCore
import SCUWire

extension ScuTool {
    struct ArgumentError: Error { var message: String }

    struct ImageContent: Sendable {
        var data: Data
        var mimeType: String
    }

    struct Outcome {
        var text: String
        var isError: Bool
        var images: [ImageContent] = []
    }

    /// 执行工具。参数错误与原生层错误都以 `Outcome.isError` 返回，而不是协议错误：
    /// 模型能读到文本并自行纠正。
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

            case .listWindows:
                try Self.requireNoExtra(args, allowed: ["pid"])
                guard let pid = try Self.int(args, "pid", range: 1...Int(Int32.max), required: true) else {
                    throw ArgumentError(message: "缺少参数 pid")
                }
                let windows = try session.listWindows(pid: Int32(pid))
                let lines = windows.map { window in
                    let title = window.title.map { "\"\($0)\"" } ?? "-"
                    let frame =
                        window.frame.map {
                            "(\(Int($0.x)),\(Int($0.y)),\(Int($0.width)),\(Int($0.height)))"
                        } ?? "-"
                    return "\(title)\t\(frame)"
                }
                return Outcome(
                    text: lines.isEmpty ? "（没有可枚举的窗口）" : lines.joined(separator: "\n"),
                    isError: false)

            case .getAXState:
                try Self.requireNoExtra(
                    args,
                    allowed: [
                        "pid", "max_depth", "budget_ms", "max_elements", "focus", "focus_role", "window",
                        "full",
                    ])
                guard let pid = try Self.int(args, "pid", range: 1...Int(Int32.max), required: true) else {
                    throw ArgumentError(message: "缺少参数 pid")
                }
                let depth =
                    try Self.int(args, "max_depth", range: 0...scuMaxTreeDepth, required: false) ?? Self.defaultDepth
                let budget =
                    try Self.int(args, "budget_ms", range: scuTreeBudgetMsRange, required: false)
                    ?? scuDefaultTreeBudgetMs
                let maxElements =
                    try Self.int(
                        args, "max_elements", range: ElementTable.maxElementsRange, required: false)
                    ?? ElementTable.defaultMaxElements

                let focusText = try Self.string(args, "focus")
                let focusRole = try Self.string(args, "focus_role")
                let focus =
                    (focusText != nil || focusRole != nil)
                    ? ElementTable.Focus(text: focusText, role: focusRole) : nil
                let windowTitle = try Self.string(args, "window")
                let full = try Self.bool(args, "full") ?? false

                let state = try session.readState(
                    pid: Int32(pid), maxDepth: depth, budgetMs: budget, windowTitle: windowTitle)
                let reading = state.reading
                let table = ElementTable.render(reading.root, maxElements: maxElements, focus: focus)
                // 差异只影响展示；完整树仍留在会话快照里，句柄解析不依赖它。
                let diff = (!full && focus == nil) ? state.diff : nil
                let useDiff = diff.map { !$0.budgetExceeded } ?? false
                var head = Self.header(
                    pid: pid, table: table, depthLimit: depth, budgetMs: budget,
                    truncated: reading.truncated, focused: focus != nil, token: state.token,
                    policy: state.policy, appName: state.appName, windowTitle: state.windowTitle,
                    actionsEnabled: actionsEnabled, diff: useDiff ? diff : nil)
                if let diff, diff.budgetExceeded {
                    head +=
                        "\n⚠️ 差异超过 \(ElementTable.defaultMaxDiffLines) 行（\(diff.lineCount) 行变化），已回退完整表；需要更小范围时用 window/focus。"
                }
                let body: String
                if useDiff, let diff {
                    body = diff.unchanged ? "界面与上次读取相同；令牌仍有效。" : diff.text
                } else {
                    body = table.text
                }
                return Outcome(text: body.isEmpty ? head : head + "\n" + body, isError: false)

            case .getScreenshot:
                try Self.requireNoExtra(args, allowed: ["token"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                let shot = try session.captureScreenshot(token: token)
                let overlaid = ScreenshotOverlay.render(capture: shot.capture, labels: shot.labels) ?? shot.capture.png
                let text = """
                    screenshot_id=\(shot.id) 图像 \(shot.capture.width)x\(shot.capture.height) scale=\(String(format: "%.3f", shot.capture.scale)) window=(\(Int(shot.capture.windowFrame.x)),\(Int(shot.capture.windowFrame.y)),\(Int(shot.capture.windowFrame.width)),\(Int(shot.capture.windowFrame.height))) title="\(shot.capture.windowTitle ?? "-")"
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
                    text:
                        "应用已在运行或已启动：\(launched.name)（pid \(launched.pid)，bundle \(bundle)）。\n用 list_apps 或 get_ax_state 继续。",
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
                    args,
                    allowed: [
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
                guard text.count <= scuMaxInputTextLength else {
                    throw ArgumentError(message: "text 最长 \(scuMaxInputTextLength) 个字符")
                }
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
                guard value.count <= scuMaxInputTextLength else {
                    throw ArgumentError(message: "value 最长 \(scuMaxInputTextLength) 个字符")
                }
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
}
