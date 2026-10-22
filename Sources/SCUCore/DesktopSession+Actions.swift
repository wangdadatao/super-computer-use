import Foundation
import SCUWire

extension DesktopSession {
    // MARK: - 解析与动作

    /// 令牌 + 句柄 → (进程, 定位器)。不联系原生层。
    public func resolve(token: String, handle: Int) throws -> (pid: Int32, locator: ElementLocator) {
        guard let r = records[token] else {
            throw WireError.staleSnapshot("令牌 \(token) 未签发或已被丢弃，请重新读取界面。")
        }
        switch r.status {
        case .switched:
            throw WireError.targetSwitched("令牌 \(token) 属于已被切换走的目标（pid \(r.pid)），请重新读取并绑定目标。")
        case .stale:
            throw WireError.staleSnapshot("令牌 \(token) 已失效：界面结构已变化，请重新读取界面。")
        case .current:
            break
        }
        guard let snap = r.snapshot else { throw WireError.internalError("当前令牌缺少快照") }
        guard handle >= 1, handle <= snap.entries.count else {
            throw WireError.elementGone("句柄 #\(handle) 不在令牌 \(token) 的快照里（共 \(snap.entries.count) 个元素）。")
        }
        return (r.pid, Self.locator(for: handle - 1, in: snap.entries))
    }

    /// 标签 → 句柄。标签与句柄同属一个快照，不跨令牌；大小写不敏感。
    /// 只做解析，不做策略检查；调用方应使用 `click` / `typeText` 等动作入口。
    public func resolveLabel(token: String, label: String) throws -> Int {
        guard let r = records[token] else {
            throw WireError.staleSnapshot("令牌 \(token) 未签发或已被丢弃，请重新读取界面。")
        }
        switch r.status {
        case .switched:
            throw WireError.targetSwitched("令牌 \(token) 属于已被切换走的目标（pid \(r.pid)），请重新读取并绑定目标。")
        case .stale:
            throw WireError.staleSnapshot("令牌 \(token) 已失效：界面结构已变化，请重新读取界面。")
        case .current:
            break
        }
        guard let snap = r.snapshot else { throw WireError.internalError("当前令牌缺少快照") }
        let wanted = label.lowercased()
        guard let index = snap.entries.firstIndex(where: { $0.label == wanted }) else {
            throw WireError.elementGone(
                "标签 [\(label)] 不在令牌 \(token) 的快照里（共 \(snap.entries.count) 个元素）。请重新读取界面。")
        }
        return index + 1
    }

    static func locator(for index: Int, in entries: [ElementTable.Entry]) -> ElementLocator {
        var steps: [PathStep] = []
        var i = index
        while entries[i].parent >= 0 {
            let parent = entries[entries[i].parent].node
            steps.append(
                PathStep(
                    index: entries[i].indexInParent,
                    // 真实子节点数；没有时（理论上只有测试替身）退回列表长度。
                    siblings: parent.childCount ?? parent.children.count,
                    role: entries[i].node.role))
            i = entries[i].parent
        }
        return ElementLocator(path: steps.reversed(), target: TargetKey(entries[index].node))
    }

    /// 策略检查 + 令牌解析。策略先于令牌：被拒绝的动作不消耗令牌，
    /// 也不因令牌状态而改变结论（ADR-0015 §5）。
    func authorizedTarget(token: String, handle: Int) throws -> (pid: Int32, locator: ElementLocator) {
        if let r = records[token] {
            // 读取时身份查询失败：这里重查；仍然失败就不执行（无法确认策略，不放行）。
            try authorizer.authorizeAction(try identity(for: r), pid: r.pid)
        }
        return try resolve(token: token, handle: handle)
    }

    /// 动作的统一投递路径：策略/令牌解析（`authorizedTarget`）→ 原生层核对 → 投递 → 失效映射。
    /// `act` 与 `perform` 都走这里，避免两条路径在失效语义上分叉。
    func deliver(
        token: String, handle: Int,
        action: (Int32, String?, ElementLocator) throws -> ActionOutcome
    ) throws -> (pid: Int32, locator: ElementLocator, outcome: ActionOutcome) {
        let windowTitle = records[token]?.windowTitle
        let (pid, locator) = try authorizedTarget(token: token, handle: handle)
        let outcome: ActionOutcome
        do {
            outcome = try action(pid, windowTitle, locator)
        } catch {
            discardAfterUnknownOutcome(error, token: token)
            throw error
        }
        if case .stale(let d) = outcome, let r = records[token] {
            invalidate(r, to: .stale)
            removeScreenshots(for: token)
            throw WireError.staleSnapshot("句柄 #\(handle) 已失效：\(Self.describe(d))。请重新读取界面。")
        }
        return (pid, locator, outcome)
    }

    /// 动作请求已经写出但结果未知时，旧令牌和旧截图绑定都不能再用于重试。
    /// 错误本身继续抛给调用方；作废状态让下一次 `after_refresh` 真正需要重新读取。
    func discardAfterUnknownOutcome(_ error: Error, token: String) {
        guard let e = error as? WireError, e.code == "action_outcome_unknown",
            let r = records[token]
        else { return }
        invalidate(r, to: .stale)
        removeScreenshots(for: token)
    }

    /// 对令牌里的句柄执行动作。会话已知失效的令牌不会联系原生层。
    public func act(token: String, handle: Int, action: ActionKind) throws -> ActionOutcome {
        try deliver(token: token, handle: handle) { pid, windowTitle, locator in
            try reader.performAction(
                pid: pid, windowTitle: windowTitle, locator: locator, action: action)
        }.outcome
    }
}
