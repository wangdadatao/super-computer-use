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
        /// 动作之后成功重读过界面。重读失败时为 false，下面三项均为 nil。
        public var observed: Bool
        /// 连续两次重读的结构一致。上限内一直在变化则为 false。
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
    }

    /// 点击：执行 `AXPress`，再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#click_tool
    public func click(token: String, handle: Int) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, windowTitle, locator in
            try reader.performAction(
                pid: pid, windowTitle: windowTitle, locator: locator, action: .press)
        }
    }

    /// 逐字输入到目标元素（先聚焦），再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func typeText(token: String, handle: Int, text: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, windowTitle, locator in
            try reader.typeText(pid: pid, windowTitle: windowTitle, locator: locator, text: text)
        }
    }

    /// 向目标元素发送按键（先聚焦），再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func pressKey(token: String, handle: Int, key: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, windowTitle, locator in
            try reader.pressKey(pid: pid, windowTitle: windowTitle, locator: locator, key: key)
        }
    }

    /// 通过无障碍接口直接写元素的值，再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func setValue(token: String, handle: Int, value: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, windowTitle, locator in
            try reader.setValue(pid: pid, windowTitle: windowTitle, locator: locator, value: value)
        }
    }

    /// 动作的统一路径：策略 → 令牌 → 原生层核对 → 投递 → 事后观察。
    /// 点击、输入、按键共用同一套效果摘要与令牌作废规则。
    func perform(
        token: String, handle: Int,
        action: (Int32, String?, ElementLocator) throws -> ActionOutcome
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
            pid: record.pid, target: locator.target, delivered: true, observed: false, converged: false,
            treeChanged: nil, targetChanged: nil, noOpSuspected: nil, polls: 0, elapsed: 0,
            tokenInvalidated: false, observationError: nil)

        let start = settle.now()
        var previous: Int?
        var settled: TreeReading?
        var settledDigest = 0
        do {
            while true {
                settle.sleep(settle.interval)
                let reading = try reader.readTree(
                    pid: record.pid, windowTitle: record.windowTitle,
                    maxDepth: pre.maxDepth, budgetMs: pre.budgetMs)
                report.polls += 1
                let digest = Self.structuralDigest(ElementTable.flatten(reading.root))
                settled = reading
                settledDigest = digest
                if let p = previous, p == digest, !reading.truncated {
                    report.converged = true
                    break
                }
                previous = digest
                if settle.now().timeIntervalSince(start) >= settle.cap { break }
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
        return report
    }
}
