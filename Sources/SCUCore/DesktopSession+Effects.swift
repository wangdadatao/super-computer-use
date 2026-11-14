import Foundation
import SCUWire

extension DesktopSession {
    // MARK: - 点击与效果

    /// 动作的效果摘要（点击、输入、按键共用）。**只陈述观察到的事实**，不声称动作"成功"：
    /// `delivered` 只表示平台没有报错。
    public struct ClickReport: Equatable, Sendable {
        public var pid: Int32
        public var target: TargetKey
        /// 动作已投递给平台。返回报告就意味着它为真；保留字段是为了与对外的摘要格式一致。
        public var delivered: Bool
        /// 观察到**目标自身**的后置条件：目标已不是原来那个（`target_changed`），
        /// 或路径上同一节点的自身字段变了（`target_state`）。
        /// 不从“整棵树变了”推导：树变化也可能来自应用自身刷新。
        /// 恒等于 `verificationState == .verified`（见 `Verification`）。
        public var verified: Bool
        /// 后置条件的种类；只有 `verified` 时有值。
        public var verifiedBy: String?
        /// 三值结论：`verified` / `refuted` / `unknown`。唯一判定点是 `Verification.action(_:)`。
        /// `refuted` 只否定声明的后置条件，不证明界面外没有副作用；`unknown` 不等于成功。
        public var verificationState: VerificationState
        /// `refuted` / `unknown` 的原因；`verified` 时为 nil。
        public var verificationReason: VerificationReason?
        /// 动作之后成功重读过界面。重读失败时为 false，下面三项均为 nil。
        public var observed: Bool
        /// 重读的静默已足够长（见 `Settle.quietPollsAfterChange` / `quietPollsWithoutChange`）。
        /// 上限内一直在变化则为 false。
        public var converged: Bool
        /// 与动作前相比结构是否变化。动作前或动作后的读取被截断时无法比较，为 nil。
        public var treeChanged: Bool?
        /// 目标元素在稳定后的树里是否已不是原来那个（路径对不上或核对键不同）。树被截断时为 nil。
        public var targetChanged: Bool?
        /// 已投递、界面已收敛、结构没有任何变化：**疑似**空操作（也可能动作只改变了无障碍树之外的东西）。
        public var noOpSuspected: Bool?
        public var polls: Int
        public var elapsed: TimeInterval
        /// 因树变化，调用时所用的令牌已被会话作废。
        public var tokenInvalidated: Bool
        public var observationError: String?

        /// 把三值判定写进报告：`verified` / `verifiedBy` 是派生字段，只在这里赋值。
        /// 观察到目标自身的后置条件时清掉 `noOpSuspected`（两者同时为真没有意义）。
        mutating func apply(_ verdict: VerificationVerdict) {
            verificationState = verdict.state
            verificationReason = verdict.reason
            verified = verdict.state == .verified
            verifiedBy = verdict.by
            if verified { noOpSuspected = false }
        }
    }

    /// 点击：执行 `AXPress`，再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#click_tool
    public func click(token: String, handle: Int) throws -> ClickReport {
        try perform(token: token, handle: handle) { target, locator in
            try reader.performAction(target: target, locator: locator, action: .press)
        }
    }

    /// 逐字输入到目标元素（先聚焦），再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func typeText(token: String, handle: Int, text: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { target, locator in
            try reader.typeText(target: target, locator: locator, text: text)
        }
    }

    /// 向目标元素发送按键（先聚焦），再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func pressKey(token: String, handle: Int, key: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { target, locator in
            try reader.pressKey(target: target, locator: locator, key: key)
        }
    }

    /// 通过无障碍接口直接写元素的值，再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func setValue(token: String, handle: Int, value: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { target, locator in
            try reader.setValue(target: target, locator: locator, value: value)
        }
    }

    /// 动作的统一路径：策略 → 令牌 → 原生层核对 → 投递 → 事后观察。
    /// 点击、输入、按键共用同一套效果摘要与令牌作废规则。
    func perform(
        token: String, handle: Int,
        action: (Target, ElementLocator) throws -> ActionOutcome
    ) throws -> ClickReport {
        // 先于动作取走动作前的快照信息：动作中途令牌可能被作废并释放快照。
        let pre = records[token]?.snapshot
        let (_, locator, outcome) = try deliver(token: token, handle: handle, action: action)
        guard case .acted = outcome else {
            throw WireError.internalError("动作得到了非预期的应答：\(outcome)")
        }
        // authorizedTarget 已经通过解析，记录与快照必然存在。
        guard let record = records[token], let pre else { throw WireError.internalError("动作后令牌记录丢失") }
        var report = ClickReport(
            pid: record.pid, target: locator.target, delivered: true, verified: false, verifiedBy: nil,
            verificationState: .unknown, verificationReason: .observationFailed,
            observed: false, converged: false,
            treeChanged: nil, targetChanged: nil, noOpSuspected: nil, polls: 0, elapsed: 0,
            tokenInvalidated: false, observationError: nil)

        let start = settle.now()
        var previous: Int?
        var settled: TreeReading?
        var settledDigest = 0
        /// 连续多少次重读与上次一致。任何一次差异都归零。
        var quietStreak = 0
        /// 相对动作前是否已观察到变化。动作前的读取被截断时无从比较，按"已变化"处理：
        /// 没有比较基准就不该再等"静默"，报告里也只会给 unknown。
        var sawChange = pre.truncated
        do {
            while true {
                settle.sleep(settle.interval)
                let reading = try reader.readTree(
                    target: record.target, maxDepth: pre.maxDepth, budgetMs: pre.budgetMs)
                report.polls += 1
                let digest = Self.structuralDigest(ElementTable.flatten(reading.root))
                settled = reading
                settledDigest = digest
                if !pre.truncated, !reading.truncated, digest != pre.digest { sawChange = true }
                if let p = previous, p == digest, !reading.truncated {
                    quietStreak += 1
                    let needed =
                        sawChange ? settle.quietPollsAfterChange : settle.quietPollsWithoutChange
                    if quietStreak >= needed {
                        report.converged = true
                        break
                    }
                } else {
                    quietStreak = 0
                }
                previous = digest
                // 上限约束的是"还要不要继续看是否在变"；若已经进入静默确认（刚读到一致），
                // 允许把这一轮确认做完：读一次树的耗时随树大小变化，卡在最后一次确认上会
                // 把"已稳定"误报成"未收敛"。丢掉的只是一轮确认，不是无限等待。
                if settle.now().timeIntervalSince(start) >= settle.cap, quietStreak == 0 { break }
            }
        } catch let e as WireError {
            report.observationError = "[\(e.code)] \(e.message)"
        }
        report.elapsed = settle.now().timeIntervalSince(start)

        guard let settled else { return report }
        report.observed = true
        if !pre.truncated, !settled.truncated {
            let changed = settledDigest != pre.digest
            report.treeChanged = changed
            report.noOpSuspected = report.converged && !changed
            if changed, let r = records[token], r.status == .current {
                invalidate(r, to: .stale)
                report.tokenInvalidated = true
            }
        }
        if !settled.truncated {
            report.targetChanged = !Self.targetPresent(locator, in: settled.root)
        }
        // 后置条件只认目标自身：目标被替换/移除，或同一路径上的节点自身字段变了。
        // 整棵树的变化不算：它可能就是应用自己的刷新，与这次动作无关。
        let stateChanged: Bool
        if !settled.truncated, handle >= 1, handle <= pre.entries.count,
            let afterNode = Self.node(at: locator.path, in: settled.root)
        {
            stateChanged = Self.selfFieldsDiffer(pre.entries[handle - 1].node, afterNode)
        } else {
            stateChanged = false
        }
        // 三值结论只在 `Verification.action` 里算一次；下面四个字段全由它派生。
        let verdict = Verification.action(
            .init(
                observed: report.observed, converged: report.converged,
                baselineAvailable: !pre.truncated, truncated: settled.truncated,
                targetChanged: report.targetChanged, stateChanged: stateChanged))
        report.apply(verdict)
        return report
    }

    /// 沿路径取下节点（与 `targetPresent` 相同的核对规则）。取不到时返回 nil。
    static func node(at path: [PathStep], in root: AXNode) -> AXNode? {
        var current = root
        for step in path {
            guard (current.childCount ?? current.children.count) == step.siblings,
                current.children.indices.contains(step.index)
            else { return nil }
            let next = current.children[step.index]
            guard next.role == step.role else { return nil }
            current = next
        }
        return current
    }

    /// 节点**自身**的可观察字段是否不同（不含子节点内容）。
    static func selfFieldsDiffer(_ a: AXNode, _ b: AXNode) -> Bool {
        a.role != b.role || a.subrole != b.subrole || a.title != b.title
            || a.identifier != b.identifier || a.description != b.description
            || a.value != b.value || a.enabled != b.enabled
            || (a.childCount ?? a.children.count) != (b.childCount ?? b.children.count)
    }
}
