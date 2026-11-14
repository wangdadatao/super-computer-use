import Foundation
import SCUCore
import SCUWire

extension ScuTool {
    static func header(
        pid: Int, table: ElementTable.Result, depthLimit: Int, budgetMs: Int, truncated: Bool, focused: Bool,
        token: SnapshotToken, policy: PolicyGate.Decision = .allow, appName: String? = nil,
        windowID: UInt32? = nil, windowTitle: String? = nil,
        actionsEnabled: Bool = false, diff: ElementTable.Diff? = nil
    ) -> String {
        var h = "# pid=\(pid) 令牌 \(token) 元素 \(table.total)"
        if let windowID { h += " window_id=\(windowID)" }
        if let windowTitle { h += " 窗口=\"\(windowTitle)\"" }
        if let diff {
            if diff.unchanged {
                h += "。与上次读取相同。"
            } else {
                h += "。差异 +\(diff.added) ~\(diff.changed) -\(diff.removed)"
                if let ids = diff.removedIDs { h += "，删除的旧句柄 \(ids)" }
                h += "；只显示变化，需要完整表用 full=true。"
            }
        } else if focused {
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
        if diff == nil && table.shown < table.scope {
            h += "按层级优先显示；行尾 (折叠 N) 表示其下还有 N 个后代未显示。用 focus 看某一部分，或调大 max_elements。"
        }
        h += "句柄只在该令牌有效期内可用（界面结构变化后令牌失效）；"
        if !table.labels.isEmpty {
            h += "可交互元素前的 [a] 是本次快照的标签，动作工具可用 label 代替 handle。"
        }
        if table.labelTotal > ElementTable.maxLabels {
            h += "可交互元素超过 \(ElementTable.maxLabels) 个，只标了前 \(ElementTable.maxLabels) 个。"
        }
        h +=
            actionsEnabled
            ? "用 click(token, handle) 点击，用 type_text / press_key 输入，或用 set_value 直接写值。" : "目前没有工具接受句柄（动作档未开启）。"
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
        if let details = e.detailsText {
            s += "\ndetails: " + details
        }
        switch e.code {
        case "stale_snapshot", "element_gone":
            s += "\n请重新调用 get_ax_state 取得新令牌与标签/句柄；用 focus 按文本重新定位目标。"
        case "stale_geometry":
            s += "\n窗口位置/缩放或截图已变化：重新 get_screenshot，使用新的 screenshot_id。"
        case "action_outcome_unknown":
            s += "\n动作请求已发出但没有等到应答，动作可能已经执行：先重新读取界面/截图确认，再决定是否重发；不要立即重试。"
        case "platform_unavailable":
            s += "\n原生进程已重建；读操作可以重试，动作操作先重新读取状态确认没有执行。"
        case "app_not_found":
            s += "\n用 bundle id、显示名或完整 .app 路径重试；不要猜一个相近的名字。"
        case "app_not_authorized":
            s += "\n该应用不在本次连接的允许列表里：让用户确认后调整 --allow-app / --allow-app-file 并重启服务；不要重试或换相近应用。"
        case "window_not_found":
            s += "\n指定的窗口标题不存在或已变化：重新 get_ax_state 查看当前窗口标题，再绑定仍存在的窗口。"
        case "ambiguous_reference":
            s += "\n标题对应多个窗口：改用 window_id（list_windows 可查），或关闭多余窗口后重试。"
        case "focus_not_established":
            s += "\n焦点不在目标上：先处理挡住目标的窗口/sheet，或改用 set_value；本次未发送任何按键。"
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

    /// `verificationReason` 的人话。原因码原样附在后面，调用方仍按码分支。
    static func verificationReasonText(_ reason: VerificationReason?) -> String {
        guard let reason else { return "无法判定（未给出原因）" }
        switch reason {
        case .postconditionAbsent: return "postcondition_absent（声明的后置条件为假）"
        case .observationFailed: return "observation_failed（事后重读界面失败）"
        case .treeTruncated: return "tree_truncated（事后读取被截断）"
        case .screenshotUnavailable: return "screenshot_unavailable（事后截图取不到或不可比）"
        case .baselineUnavailable: return "baseline_unavailable（动作前的基线读不到）"
        case .geometryChanged: return "geometry_changed（动作后窗口位置/缩放变了）"
        case .noReadablePostcondition:
            return "no_readable_postcondition（这个动作没有可读的后置条件）"
        case .targetNotVisible: return "target_not_visible（落点或目标在事后已不可读）"
        case .notConverged: return "not_converged（界面在静默窗口内没有稳定）"
        }
    }

    /// 坐标点击结果。没有元素身份：`delivered` 只说明事件已投递；`verification` 是三值结论，
    /// `verified` 只为向后兼容保留。refuted 只否定声明的后置条件，unknown 不等于成功。
    static func coordinateText(_ r: CoordinateReport, action: String, detail: String) -> String {
        func flag(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "unknown" }
        let secs = String(format: "%.1f", r.elapsed)
        var probe = ""
        if r.landingRole != nil || r.selectionBefore != nil || r.landingElementValid != nil {
            probe =
                " landingRole=\(r.landingRole ?? "-") selectionBefore=\(r.selectionBefore ?? "-")"
                + " selectionAfter=\(r.selectionAfter ?? "-")"
                + " elementValid=\(flag(r.landingElementValid))"
                + " clickCount=\(r.clickCount.map { String($0) } ?? "unknown")"
        }
        var lines = [
            "已对 pid \(r.pid) 的\(detail) 投递\(action)。",
            "effect: delivered=\(flag(r.delivered)) verification=\(r.verificationState.rawValue) "
                + "verificationReason=\(r.verificationReason?.rawValue ?? "-") "
                + "verified=\(flag(r.verified)) verifiedBy=\(r.verifiedBy ?? "-") "
                + "observed=\(flag(r.observed)) treeChanged=\(flag(r.treeChanged)) "
                + "screenshotChanged=\(flag(r.screenshotChanged)) "
                + "diffRatio=\(r.diffRatio.map { String(format: "%.4f", $0) } ?? "unknown") "
                + "geometryChanged=\(flag(r.geometryChanged)) "
                + "noOpSuspected=\(flag(r.noOpSuspected)) elapsed=\(secs)s\(probe)",
        ]
        switch r.verificationState {
        case .verified:
            switch r.verifiedBy {
            case "caret_pixels":
                lines.append("已验证：落点所在文本行出现了插入光标形态的像素变化（启发式判据，未读取焦点）。")
            case "selection_changed":
                lines.append(
                    "已验证：落点文本元素的选区从 \(r.selectionBefore ?? "-") 变为 \(r.selectionAfter ?? "-")"
                        + "（同一 AX 元素，点击前后各读一次）。")
            default:
                lines.append("已验证：观察到后置条件 \(r.verifiedBy ?? "未知")。")
            }
        case .refuted:
            lines.append(
                "已确认未生效（refuted）：落点文本元素的插入光标/选区变化在稳定窗口内为假。"
                    + "这只否定该后置条件，不证明界面外没有副作用。")
            if let note = r.verifiedNote { lines.append("观察细节：\(note)") }
        case .unknown:
            lines.append(
                "结果未知（unknown）：\(verificationReasonText(r.verificationReason))。"
                    + "unknown 不等于成功，不得据此认为动作已生效。")
            if let note = r.verifiedNote { lines.append("观察细节：\(note)") }
        }
        if !r.observed {
            lines.append("⚠️ 点击已投递，但事后读不到界面，不知道效果；请用 get_screenshot 核实。")
        } else if r.treeChanged == true {
            lines.append(
                "投递后界面结构发生变化（这不证明命中：也可能来自应用自身刷新或窗口激活），旧令牌已作废，请重新 get_ax_state。")
        } else if r.treeChanged == false, r.screenshotChanged == true {
            lines.append("AX 树没有变化，但截图检测到像素变化；可能是画布/悬停/局部刷新，同样不证明命中。")
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
            "effect: delivered=\(flag(r.delivered)) verification=\(r.verificationState.rawValue) "
                + "verificationReason=\(r.verificationReason?.rawValue ?? "-") "
                + "verified=\(flag(r.verified)) verifiedBy=\(r.verifiedBy ?? "-") "
                + "observed=\(flag(r.observed)) converged=\(flag(r.converged)) "
                + "treeChanged=\(flag(r.treeChanged)) targetChanged=\(flag(r.targetChanged)) "
                + "noOpSuspected=\(flag(r.noOpSuspected)) polls=\(r.polls) elapsed=\(secs)s",
        ]
        switch r.verificationState {
        case .verified:
            let what = r.verifiedBy == "target_changed" ? "目标已不是原来那个" : "目标自身的字段发生变化"
            lines.append("已验证：\(what)（\(r.verifiedBy ?? "-")）。")
        case .refuted:
            lines.append(
                "已确认未生效（refuted）：目标自身的字段变化或目标被替换在稳定窗口内为假。"
                    + "这只否定该后置条件，不证明界面外没有副作用。")
        case .unknown:
            lines.append(
                "结果未知（unknown）：\(verificationReasonText(r.verificationReason))。"
                    + "unknown 不等于成功，不得据此认为动作已生效。")
        }
        if !r.observed {
            lines.append(
                "⚠️ 动作已投递，但事后读不到界面（\(r.observationError ?? "未知原因")），不知道效果；请用 get_ax_state 确认。")
        } else if r.treeChanged == true {
            lines.append(
                "投递后界面结构发生变化（这不证明命中：也可能来自应用自身刷新），旧令牌已作废，请重新 get_ax_state。")
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
}
