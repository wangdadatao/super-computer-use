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
    case click

    var isAction: Bool { self == .click }

    static func available(actions: Bool) -> [ScuTool] {
        allCases.filter { actions || !$0.isAction }
    }

    var title: String {
        switch self {
        case .checkPermissions: return "检查辅助功能权限"
        case .listApps: return "列出应用"
        case .getAXState: return "读取无障碍树"
        case .click: return "点击元素"
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
        case .click:
            return """
                点击元素：对 get_ax_state 输出里的某个句柄执行 AXPress（无障碍的"按下"，不移动真实鼠标）。会改变应用的状态。\
                必须同时给出该输出的令牌与句柄；令牌失效（界面结构变了）、目标已不是读取时的那个、\
                或应用属于拒绝类目（终端、脚本运行器、密码管理器、系统设置、Cursor 等）时，动作不会执行，并返回分类的错误。\
                返回的是**观察到的效果**，不是"成功"的保证：已投递只表示系统没有报错；\
                之后会重读界面直到稳定（最多约 3 秒），报告结构是否变化。\
                "疑似空操作"表示界面稳定后结构没有任何变化，请核实后再继续。\
                结构变化时旧令牌作废，需重新 get_ax_state。不支持 AXPress 的元素返回 unsupported_operation。
                """
        case .getAXState:
            return """
                读取指定应用的无障碍树，返回文本化元素表。只读，不会操作应用。\
                每行一个元素，缩进表示层级，格式 [角色#句柄] "标题" 属性…。\
                输出带一个令牌，句柄与令牌配对、只在该令牌有效期内可用（界面结构变化后令牌失效）；click 工具（仅动作档提供）接受它们。\
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
        case .click:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "该输出元素表里的句柄编号（[角色#句柄] 的数字）"],
                ],
                "required": ["token", "handle"],
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
    struct Outcome {
        var text: String
        var isError: Bool
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

            case .click:
                try Self.requireNoExtra(args, allowed: ["token", "handle"])
                guard let token = try Self.string(args, "token") else { throw ArgumentError(message: "缺少参数 token") }
                guard let handle = try Self.int(args, "handle", range: 1...Int(Int32.max), required: true) else {
                    throw ArgumentError(message: "缺少参数 handle")
                }
                let report = try session.click(token: token, handle: handle)
                return Outcome(text: Self.clickText(report, handle: handle), isError: false)
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
        h += actionsEnabled ? "用 click(token, handle) 点击。" : "目前没有工具接受句柄（动作档未开启）。"
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
            s += "\n请重新调用 get_ax_state 取得新令牌与句柄；用 focus 按文本重新定位目标。"
        case "target_switched":
            s += "\n令牌属于之前读取的另一个应用：请对要操作的应用重新 get_ax_state。"
        case "unsupported_operation":
            s += "\n该元素不能被点击；可尝试它的父元素或子元素，或换一个元素。"
        case "policy_denied":
            s += "\n这是不可协商的拒绝，不要重试或换用别的方式绕过；请告知用户由他自己完成这一步。"
        default:
            break
        }
        if e.code == "system_permission_missing" {
            s += "\n权限按宿主应用归属：请给启动本服务的应用授予辅助功能权限，可用 check_permissions 确认。"
        }
        return s
    }

    /// 点击结果的文本：先一行机器可读的摘要，再用人话解释。只陈述观察到的事实。
    static func clickText(_ r: DesktopSession.ClickReport, handle: Int) -> String {
        func flag(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "unknown" }
        let label = [r.target.title, r.target.description].compactMap { $0 }.first { !$0.isEmpty }
        var name = "\(r.target.role)#\(handle)"
        if let label { name += " " + ElementTable.quote(label) }
        let secs = String(format: "%.1f", r.elapsed)
        var lines = [
            "已对 \(name)（pid \(r.pid)）投递点击。",
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
