import Foundation
import SCUCore
import SCUWire

/// 只读档的工具目录。**没有任何工具会改变桌面状态**；每个工具都带 `readOnlyHint`。
// @project-doc docs/interfaces/mcp_surface.md#tool_catalog
enum ScuTool: String, CaseIterable {
    case checkPermissions = "check_permissions"
    case listApps = "list_apps"
    case getAXState = "get_ax_state"

    var title: String {
        switch self {
        case .checkPermissions: return "检查辅助功能权限"
        case .listApps: return "列出应用"
        case .getAXState: return "读取无障碍树"
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
        case .getAXState:
            return """
                读取指定应用的无障碍树，返回文本化元素表。只读，不会操作应用。\
                每行一个元素，缩进表示层级，格式 [角色#句柄] "标题" 属性…。\
                句柄只在本次输出内有效，目前没有任何工具接受句柄（SCU 尚不能操作元素）。\
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
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }

    static let defaultDepth = 12

    // MARK: - 执行

    struct ArgumentError: Error { var message: String }

    /// 执行工具。参数错误与原生层错误都以 `Outcome.isError` 返回，而不是协议错误：
    /// 模型能读到文本并自行纠正。
    struct Outcome {
        var text: String
        var isError: Bool
    }

    func run(arguments: JSONValue?, reader: DesktopReader) -> Outcome {
        do {
            let args = try Self.objectArguments(arguments)
            switch self {
            case .checkPermissions:
                try Self.requireNoExtra(args, allowed: [])
                let ok = try reader.checkPermissions()
                return Outcome(
                    text: ok
                        ? "辅助功能：已授予（针对启动本服务的宿主应用）"
                        : "辅助功能：未授予。请在 系统设置 > 隐私与安全性 > 辅助功能 中给启动本服务的宿主应用授权；权限按宿主归属，不是整台机器。",
                    isError: false)

            case .listApps:
                try Self.requireNoExtra(args, allowed: [])
                let apps = try reader.listApps()
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

                let reading = try reader.readTree(pid: Int32(pid), maxDepth: depth, budgetMs: budget)
                let table = ElementTable.render(reading.root, maxElements: maxElements, focus: focus)
                let head = Self.header(
                    pid: pid, table: table, depthLimit: depth, budgetMs: budget,
                    truncated: reading.truncated, focused: focus != nil)
                return Outcome(text: table.text.isEmpty ? head : head + "\n" + table.text, isError: false)
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
        pid: Int, table: ElementTable.Result, depthLimit: Int, budgetMs: Int, truncated: Bool, focused: Bool
    ) -> String {
        var h = "# pid=\(pid) 元素 \(table.total)"
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
        h += "句柄仅本次输出内有效，目前没有工具接受句柄。"
        if truncated { h += "\n⚠️ 已截断：\(budgetMs) 毫秒的读取预算耗尽，树不完整。" }
        if table.depth >= depthLimit { h += "\n⚠️ 已达深度上限 \(depthLimit)：更深的节点未读取。" }
        return h
    }

    /// 按 `code` 分支给出提示，不解析 `message`（error_taxonomy.md）。
    static func describe(_ e: WireError) -> String {
        var s = "[\(e.code)] \(e.message)（retry=\(e.retry)）"
        if e.code == "system_permission_missing" {
            s += "\n权限按宿主应用归属：请给启动本服务的应用授予辅助功能权限，可用 check_permissions 确认。"
        }
        return s
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
