import Foundation
import SCUWire

extension DesktopSession {
    /// 列出窗口，走与应用读取相同的授权检查；`list_apps` 仍保持不过滤。
    public func listWindows(pid: Int32) throws -> [WindowInfo] {
        if appAuthorization.isRestricted {
            try authorizer.authorizeRead(try lookupIdentity(pid: pid), pid: pid)
        }
        return try reader.listWindows(pid: pid)
    }

    public func readState(
        pid: Int32, maxDepth: Int, budgetMs: Int, windowTitle: String? = nil
    ) throws -> SessionState {
        // 受限连接必须在读树之前确认应用身份，避免先读到数据再拒绝。
        let knownIdentity: Identity?
        if appAuthorization.isRestricted {
            let identity: Identity
            if let t = currentToken, let current = records[t], current.pid == pid,
                let known = current.identity
            {
                identity = known
            } else {
                identity = try lookupIdentity(pid: pid)
            }
            try authorizer.authorizeRead(identity, pid: pid)
            knownIdentity = identity
        } else {
            knownIdentity = nil
        }

        let reading = try reader.readTree(
            pid: pid, windowTitle: windowTitle, maxDepth: maxDepth, budgetMs: budgetMs)
        let entries = ElementTable.flatten(reading.root)
        let digest = Self.structuralDigest(entries)

        if let t = currentToken, let r = records[t], r.pid == pid,
            r.windowTitle == windowTitle, let snap = r.snapshot,
            snap.digest == digest, snap.truncated == reading.truncated
        {
            // 结构没有变化：沿用令牌。几何不进摘要，窗口移动不会让令牌失效。
            r.snapshot = Snapshot(
                entries: entries, digest: digest, truncated: reading.truncated, maxDepth: maxDepth, budgetMs: budgetMs)
            baseline =
                reading.truncated
                ? nil
                : Baseline(
                    pid: pid, windowTitle: windowTitle, maxDepth: maxDepth, budgetMs: budgetMs,
                    entries: entries)
            return state(
                token: t, record: r, reading: reading, reused: true, diff: .noChange)
        }

        // 差异只用于展示。完整 entries 仍然写进快照，动作解析不依赖差异文本。
        var diff: ElementTable.Diff?
        if let b = baseline, b.pid == pid, b.windowTitle == windowTitle,
            b.maxDepth == maxDepth, b.budgetMs == budgetMs, !reading.truncated
        {
            diff = ElementTable.diff(previous: b.entries, current: entries)
        }

        if let t = currentToken, let old = records[t] {
            invalidate(old, to: old.pid == pid ? .stale : .switched)
        }
        counter += 1
        let token = "s\(nonce).\(counter)"
        let record = Record(
            pid: pid, identity: knownIdentity ?? (try? lookupIdentity(pid: pid)), status: .current,
            windowTitle: windowTitle,
            snapshot: Snapshot(
                entries: entries, digest: digest, truncated: reading.truncated, maxDepth: maxDepth, budgetMs: budgetMs))
        records[token] = record
        order.append(token)
        while order.count > retained {
            records[order.removeFirst()] = nil
        }
        currentToken = token
        baseline =
            reading.truncated
            ? nil
            : Baseline(
                pid: pid, windowTitle: windowTitle, maxDepth: maxDepth, budgetMs: budgetMs,
                entries: entries)
        return state(token: token, record: record, reading: reading, reused: false, diff: diff)
    }

    func state(
        token: String, record: Record, reading: TreeReading, reused: Bool,
        diff: ElementTable.Diff?
    ) -> SessionState {
        SessionState(
            token: SnapshotToken(token), reading: reading, reused: reused, pid: record.pid,
            policy: policy.evaluate(pid: record.pid, bundleId: record.identity?.bundleId),
            appName: record.identity?.name, windowTitle: record.windowTitle, diff: diff)
    }

    /// 查进程的 bundle id 与名称。列表里没有该进程时返回空身份（不是失败）；列表本身读不到则抛错。
    func lookupIdentity(pid: Int32) throws -> Identity {
        let app = try reader.listApps().first { $0.pid == pid }
        return Identity(name: app?.name, bundleId: app?.bundleId)
    }

    /// 取出或重查记录的应用身份，并缓存到记录上。
    func identity(for record: Record) throws -> Identity {
        if let known = record.identity { return known }
        let identity = try lookupIdentity(pid: record.pid)
        record.identity = identity
        return identity
    }

    func invalidate(_ r: Record, to status: Status) {
        guard r.status == .current else { return }
        r.status = status
        r.snapshot = nil
        recordInvalidation()
    }

    /// 结构摘要：覆盖除位置与大小外的全部字段与子节点数。
    /// 值与启用状态的变化算结构变化（见 snapshot_lifecycle.md）。
    ///
    /// `depthBase` 用于比较子树：同一个窗口子树的读取根可能是应用根，也可能是窗口根本身，
    /// 深度会整体偏移；先把基准归零，才能比较同一棵树（见 `windowScopedDigest`）。
    static func structuralDigest(_ entries: [ElementTable.Entry], depthBase: Int = 0) -> Int {
        var h = Hasher()
        h.combine(entries.count)
        for e in entries {
            let n = e.node
            h.combine(e.depth - depthBase)
            h.combine(n.role)
            h.combine(n.subrole)
            h.combine(n.title)
            h.combine(n.identifier)
            h.combine(n.value)
            h.combine(n.roleDescription)
            h.combine(n.description)
            h.combine(n.enabled)
            h.combine(n.childCount)
        }
        return h.finalize()
    }
}
