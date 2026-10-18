import Foundation
import SCUWire

/// 快照令牌：不透明字符串。每次读取签发，界面稳定时复用同一个。
public struct SnapshotToken: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { value }
}

/// 一次读取的结果，附带令牌。
public struct SessionState: Sendable {
    public var token: SnapshotToken
    public var reading: TreeReading
    /// 界面结构与上次读取相同，沿用了原令牌（原有句柄仍然有效）。
    public var reused: Bool
    /// 读取的是哪个进程。
    public var pid: Int32
}

/// 会话：保存快照与令牌状态，把"令牌 + 句柄"解析成动作定位器，并在失效时给出分类的错误。
///
/// 协议层保存快照，原生层保持无状态（ADR-0015）。非线程安全：动作在会话内串行。
// @project-doc docs/architecture/snapshot_lifecycle.md#p0_implementation
public final class DesktopSession {
    enum Status { case current, stale, switched }

    final class Record {
        let pid: Int32
        var status: Status
        /// 只有当前令牌保留整棵树；失效后释放，避免长期持有大树。
        var snapshot: Snapshot?
        init(pid: Int32, status: Status, snapshot: Snapshot?) {
            self.pid = pid
            self.status = status
            self.snapshot = snapshot
        }
    }

    struct Snapshot {
        var entries: [ElementTable.Entry]
        var digest: Int
        var truncated: Bool
    }

    public let reader: DesktopReader
    private let retained: Int
    private let nonce: String
    private var counter = 0
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var currentToken: String?

    /// 令牌从当前变为失效（含目标切换）的次数。同一令牌只迁移一次，重复使用不再增加。
    public private(set) var invalidations = 0

    public init(reader: DesktopReader, retainedTokens: Int = 16) {
        self.reader = reader
        self.retained = max(2, retainedTokens)
        self.nonce = String(UInt32.random(in: 0..<0x1000_0000), radix: 36)
    }

    // MARK: - 读取与签发

    public func readState(pid: Int32, maxDepth: Int, budgetMs: Int) throws -> SessionState {
        let reading = try reader.readTree(pid: pid, maxDepth: maxDepth, budgetMs: budgetMs)
        let entries = ElementTable.flatten(reading.root)
        let digest = Self.structuralDigest(entries)

        if let t = currentToken, let r = records[t], r.pid == pid, let snap = r.snapshot,
            snap.digest == digest, snap.truncated == reading.truncated
        {
            // 结构没有变化：沿用令牌。几何不进摘要，窗口移动不会让令牌失效。
            r.snapshot = Snapshot(entries: entries, digest: digest, truncated: reading.truncated)
            return SessionState(token: SnapshotToken(t), reading: reading, reused: true, pid: pid)
        }

        if let t = currentToken, let old = records[t] {
            invalidate(old, to: old.pid == pid ? .stale : .switched)
        }
        counter += 1
        let token = "s\(nonce).\(counter)"
        records[token] = Record(
            pid: pid, status: .current,
            snapshot: Snapshot(entries: entries, digest: digest, truncated: reading.truncated))
        order.append(token)
        while order.count > retained {
            records[order.removeFirst()] = nil
        }
        currentToken = token
        return SessionState(token: SnapshotToken(token), reading: reading, reused: false, pid: pid)
    }

    private func invalidate(_ r: Record, to status: Status) {
        guard r.status == .current else { return }
        r.status = status
        r.snapshot = nil
        invalidations += 1
    }

    /// 结构摘要：覆盖除位置与大小外的全部字段与子节点数。
    /// 值与启用状态的变化算结构变化（见 snapshot_lifecycle.md）。
    static func structuralDigest(_ entries: [ElementTable.Entry]) -> Int {
        var h = Hasher()
        h.combine(entries.count)
        for e in entries {
            let n = e.node
            h.combine(e.depth)
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

    /// 对令牌里的句柄执行动作。会话已知失效的令牌不会联系原生层。
    public func act(token: String, handle: Int, action: ActionKind) throws -> ActionOutcome {
        let (pid, locator) = try resolve(token: token, handle: handle)
        let outcome = try reader.performAction(pid: pid, locator: locator, action: action)
        if case .stale(let d) = outcome, let r = records[token] {
            invalidate(r, to: .stale)
            throw WireError.staleSnapshot("句柄 #\(handle) 已失效：\(Self.describe(d))。请重新读取界面。")
        }
        return outcome
    }

    static func describe(_ d: StaleDetail) -> String {
        switch d.reason {
        case .childCount:
            return "路径第 \(d.step ?? 0) 层的子节点数现在是 \(d.actualCount ?? 0)，读取时不同"
        case .role:
            return "路径第 \(d.step ?? 0) 层的节点已不是读取时的角色" + (d.actual.map { "（现为 \($0.role)）" } ?? "")
        case .target:
            let label = d.actual.map { [$0.title, $0.description].compactMap { $0 }.first ?? "" } ?? ""
            return "目标元素已不是读取时的那个" + (d.actual.map { "（现为 \($0.role)" + (label.isEmpty ? "）" : " \"\(label)\"）") } ?? "")
        }
    }
}
