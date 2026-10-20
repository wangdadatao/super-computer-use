import Foundation
import SCUWire

/// 快照令牌：不透明字符串。每次读取签发，界面稳定时复用同一个。
public struct SnapshotToken: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { value }
}

/// 一次窗口截图，连同签发它的令牌。标签是快照里的全部标签，截图时按窗口裁剪。
/// 坐标点击的观察结果。坐标点击没有元素身份，只能报告树是否变化；
/// 像素级变化要等截图 diff。
public struct CoordinateReport: Sendable {
    public var pid: Int32
    public var observed: Bool
    public var treeChanged: Bool?
    public var screenshotChanged: Bool?
    public var diffRatio: Double?
    public var geometryChanged: Bool
    public var tokenInvalidated: Bool
    public var noOpSuspected: Bool
    public var elapsed: TimeInterval

    public init(
        pid: Int32, observed: Bool, treeChanged: Bool?, screenshotChanged: Bool?,
        diffRatio: Double?, geometryChanged: Bool, tokenInvalidated: Bool,
        noOpSuspected: Bool, elapsed: TimeInterval
    ) {
        self.pid = pid
        self.observed = observed
        self.treeChanged = treeChanged
        self.screenshotChanged = screenshotChanged
        self.diffRatio = diffRatio
        self.geometryChanged = geometryChanged
        self.tokenInvalidated = tokenInvalidated
        self.noOpSuspected = noOpSuspected
        self.elapsed = elapsed
    }
}

public struct SessionScreenshot: Sendable {
    public var id: String
    public var capture: WindowCapture
    public var labels: [ElementTable.Label]

    public init(id: String, capture: WindowCapture, labels: [ElementTable.Label]) {
        self.id = id
        self.capture = capture
        self.labels = labels
    }
}

/// 一次读取的结果，附带令牌。
public struct SessionState: Sendable {
    public var token: SnapshotToken
    public var reading: TreeReading
    /// 界面结构与上次读取相同，沿用了原令牌（原有句柄仍然有效）。
    public var reused: Bool
    /// 读取的是哪个进程。
    public var pid: Int32
    /// 对该应用的动作是否会被策略拒绝。读取本身不受策略限制。
    public var policy: PolicyGate.Decision
    /// 应用显示名；身份查询失败或没有该进程时为 nil。
    public var appName: String?
    /// 绑定的窗口标题；nil 表示默认窗口（原生层选最大非最小化窗口）。
    public var windowTitle: String?
}

/// 会话：保存快照与令牌状态，把"令牌 + 句柄"解析成动作定位器，并在失效时给出分类的错误。
///
/// 协议层保存快照，原生层保持无状态（ADR-0015）。非线程安全：动作在会话内串行。
// @project-doc docs/architecture/snapshot_lifecycle.md#p0_implementation
public final class DesktopSession {
    enum Status { case current, stale, switched }

    struct Identity {
        var name: String?
        var bundleId: String?
    }

    final class Record {
        let pid: Int32
        /// nil 表示身份查询**失败**（不是"没有 bundle id"）；动作时必须重查，查不到就不执行。
        var identity: Identity?
        var status: Status
        /// 这个令牌绑定的窗口标题；nil 表示默认窗口。
        let windowTitle: String?
        /// 只有当前令牌保留整棵树；失效后释放，避免长期持有大树。
        var snapshot: Snapshot?
        init(pid: Int32, identity: Identity?, status: Status, windowTitle: String?, snapshot: Snapshot?) {
            self.pid = pid
            self.identity = identity
            self.status = status
            self.windowTitle = windowTitle
            self.snapshot = snapshot
        }
    }

    struct Snapshot {
        var entries: [ElementTable.Entry]
        var digest: Int
        var truncated: Bool
        /// 读取参数：动作之后重读用同样的深度与预算，才能与动作前的摘要比较。
        var maxDepth: Int
        var budgetMs: Int
    }

    /// 截图的坐标绑定：窗口位置/缩放变化后，旧截图不能用于坐标动作。
    struct ScreenshotBinding {
        var token: String
        var windowTitle: String?
        var windowFrame: Rect
        var scale: Double
        var width: Int
        var height: Int
        var png: Data
    }

    /// 动作之后等待界面稳定的参数。启发式初值，见 ADR-0011 的追加记录。
    public struct Settle {
        public var interval: TimeInterval
        public var cap: TimeInterval
        public var sleep: (TimeInterval) -> Void
        public var now: () -> Date

        public init(
            interval: TimeInterval = 0.2, cap: TimeInterval = 3.0,
            sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
            now: @escaping () -> Date = { Date() }
        ) {
            self.interval = interval
            self.cap = cap
            self.sleep = sleep
            self.now = now
        }
    }

    public let reader: DesktopReader
    public let launcher: AppLauncher
    /// 连接级应用允许列表；默认允许全部（硬拒绝类目仍单独生效）。
    public internal(set) var appAuthorization: AppAuthorization

    private var screenshotBindings: [String: ScreenshotBinding] = [:]
    private var screenshotOrder: [String] = []
    private var screenshotCounter = 0
    private let policy: PolicyGate
    private let settle: Settle
    private let retained: Int
    private let nonce: String
    private var counter = 0
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var currentToken: String?

    /// 令牌从当前变为失效（含目标切换）的次数。同一令牌只迁移一次，重复使用不再增加。
    public private(set) var invalidations = 0

    public init(
        reader: DesktopReader, launcher: AppLauncher = WorkspaceAppLauncher(),
        appAuthorization: AppAuthorization = .allowAll,
        policy: PolicyGate = PolicyGate(), retainedTokens: Int = 16,
        settle: Settle = Settle()
    ) {
        self.reader = reader
        self.launcher = launcher
        self.appAuthorization = appAuthorization
        self.policy = policy
        self.settle = settle
        self.retained = max(2, retainedTokens)
        self.nonce = String(UInt32.random(in: 0..<0x1000_0000), radix: 36)
    }

    /// 启动（或激活）应用。先解析 bundle id 并做拒绝类目检查，再真正启动。
    public func launchApp(identifier: String) throws -> AppInfo {
        guard let resolved = try launcher.resolve(identifier) else {
            throw WireError.appNotFound(identifier)
        }
        if case .deny(let category) = policy.evaluate(bundleId: resolved.bundleId) {
            throw WireError.policyDenied(category: category, app: resolved.name)
        }
        try authorizeApp(
            Identity(name: resolved.name, bundleId: resolved.bundleId),
            pid: resolved.pid)
        return try launcher.launch(identifier, activate: true)
    }

    // MARK: - 读取与签发

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
            try authorizeApp(identity, pid: pid)
            knownIdentity = identity
        } else {
            knownIdentity = nil
        }

        let reading = try reader.readTree(pid: pid, maxDepth: maxDepth, budgetMs: budgetMs)
        let entries = ElementTable.flatten(reading.root)
        let digest = Self.structuralDigest(entries)

        if let t = currentToken, let r = records[t], r.pid == pid,
            r.windowTitle == windowTitle, let snap = r.snapshot,
            snap.digest == digest, snap.truncated == reading.truncated
        {
            // 结构没有变化：沿用令牌。几何不进摘要，窗口移动不会让令牌失效。
            r.snapshot = Snapshot(
                entries: entries, digest: digest, truncated: reading.truncated, maxDepth: maxDepth, budgetMs: budgetMs)
            return state(token: t, record: r, reading: reading, reused: true)
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
        return state(token: token, record: record, reading: reading, reused: false)
    }

    private func state(token: String, record: Record, reading: TreeReading, reused: Bool) -> SessionState {
        SessionState(
            token: SnapshotToken(token), reading: reading, reused: reused, pid: record.pid,
            policy: policy.evaluate(pid: record.pid, bundleId: record.identity?.bundleId),
            appName: record.identity?.name, windowTitle: record.windowTitle)
    }

    /// 查进程的 bundle id 与名称。列表里没有该进程时返回空身份（不是失败）；列表本身读不到则抛错。
    private func lookupIdentity(pid: Int32) throws -> Identity {
        let app = try reader.listApps().first { $0.pid == pid }
        return Identity(name: app?.name, bundleId: app?.bundleId)
    }

    /// 取出或重查记录的应用身份，并缓存到记录上。
    private func identity(for record: Record) throws -> Identity {
        if let known = record.identity { return known }
        let identity = try lookupIdentity(pid: record.pid)
        record.identity = identity
        return identity
    }

    /// 连接级允许列表检查。硬拒绝类目由 `policy` 单独负责，且先于这里。
    private func authorizeApp(_ identity: Identity, pid: Int32) throws {
        guard appAuthorization.permits(bundleId: identity.bundleId) else {
            throw WireError.appNotAuthorized(
                app: identity.name ?? identity.bundleId ?? "pid \(pid)",
                bundleId: identity.bundleId,
                allowed: appAuthorization.allowedBundleIds)
        }
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

    /// 对当前令牌的目标窗口截图。返回图像、元数据与快照里的全部标签。
    ///
    /// 截图不改变令牌；但截图绑定窗口位置/缩放，供后续坐标动作判断是否过期。
    public func captureScreenshot(token: String) throws -> SessionScreenshot {
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
        try authorizeApp(try identity(for: r), pid: r.pid)
        let capture = try reader.captureWindow(pid: r.pid, windowTitle: r.windowTitle)
        let labels = snap.entries.enumerated().compactMap { index, entry -> ElementTable.Label? in
            guard let text = entry.label, let frame = entry.node.frame else { return nil }
            if r.windowTitle != nil {
                let window = capture.windowFrame
                let intersects = frame.x < window.x + window.width
                    && frame.x + frame.width > window.x
                    && frame.y < window.y + window.height
                    && frame.y + frame.height > window.y
                guard intersects else { return nil }
            }
            return ElementTable.Label(
                text: text, handle: index + 1, role: entry.node.role,
                title: entry.node.title, frame: frame)
        }
        screenshotCounter += 1
        let id = "g\(nonce).\(screenshotCounter)"
        screenshotBindings[id] = ScreenshotBinding(
            token: token, windowTitle: r.windowTitle, windowFrame: capture.windowFrame,
            scale: capture.scale, width: capture.width, height: capture.height, png: capture.png)
        screenshotOrder.append(id)
        while screenshotOrder.count > 16 {
            screenshotBindings[screenshotOrder.removeFirst()] = nil
        }
        return SessionScreenshot(id: id, capture: capture, labels: labels)
    }

    /// 在截图坐标 (x, y) 点击。坐标以截图左上角为原点，单位是图像像素。
    ///
    /// 截图必须属于当前令牌，且窗口位置/缩放未变；否则拒绝。
    /// 点击后只观察 AX 树是否变化；坐标点击的像素级变化留给截图 diff。
    private func coordinateContext(
        token: String, screenshotID: String
    ) throws -> (Record, Snapshot, ScreenshotBinding) {
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
        guard let binding = screenshotBindings[screenshotID], binding.token == token else {
            throw WireError.staleGeometry("截图 \(screenshotID) 不存在、已过期或不属于令牌 \(token)，请重新 get_screenshot。")
        }

        let identity = try identity(for: r)
        if case .deny(let category) = policy.evaluate(pid: r.pid, bundleId: identity.bundleId) {
            throw WireError.policyDenied(category: category, app: identity.name ?? "pid \(r.pid)")
        }
        try authorizeApp(identity, pid: r.pid)
        return (r, snap, binding)
    }

    private func checkPoint(_ x: Double, _ y: Double, in binding: ScreenshotBinding) throws {
        guard x >= 0, y >= 0, x < Double(binding.width), y < Double(binding.height) else {
            throw WireError.invalidCoordinates(
                "坐标 (\(x), \(y)) 不在截图 \(binding.width)×\(binding.height) 范围内。")
        }
    }

    private func globalPoint(x: Double, y: Double, binding: ScreenshotBinding) -> (x: Double, y: Double) {
        (binding.windowFrame.x + x / binding.scale, binding.windowFrame.y + y / binding.scale)
    }

    private func observeCoordinate(
        token: String, r: Record, snap: Snapshot, binding: ScreenshotBinding, start: Date
    ) -> CoordinateReport {
        settle.sleep(settle.interval)
        var observed = false
        var changed: Bool?
        var invalidated = false
        do {
            let after = try readState(
                pid: r.pid, maxDepth: snap.maxDepth, budgetMs: snap.budgetMs,
                windowTitle: r.windowTitle)
            observed = true
            changed = after.token != SnapshotToken(token)
            invalidated = changed == true
        } catch {
            observed = false
        }

        var screenshotChanged: Bool?
        var diffRatio: Double?
        var geometryChanged = false
        if let after = try? reader.captureWindow(pid: r.pid, windowTitle: binding.windowTitle) {
            if after.width != binding.width || after.height != binding.height
                || after.windowFrame != binding.windowFrame || after.scale != binding.scale
            {
                geometryChanged = true
            } else if let ratio = ScreenshotDiff.changedRatio(before: binding.png, after: after.png) {
                diffRatio = ratio
                screenshotChanged = ratio > 0.001
            }
        }

        let noOp = observed && changed == false && (screenshotChanged == false || screenshotChanged == nil)
        return CoordinateReport(
            pid: r.pid, observed: observed, treeChanged: changed,
            screenshotChanged: screenshotChanged, diffRatio: diffRatio,
            geometryChanged: geometryChanged, tokenInvalidated: invalidated,
            noOpSuspected: noOp, elapsed: Date().timeIntervalSince(start))
    }

    /// 在截图坐标 (x, y) 点击。坐标以截图左上角为原点，单位是图像像素。
    public func clickAt(token: String, screenshotID: String, x: Double, y: Double) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(x, y, in: binding)
        let start = Date()
        let point = globalPoint(x: x, y: y, binding: binding)
        _ = try reader.clickAt(pid: r.pid, windowTitle: binding.windowTitle, x: point.x, y: point.y)
        return observeCoordinate(token: token, r: r, snap: snap, binding: binding, start: start)
    }

    /// 在截图坐标 (x, y) 滚动。dy > 0 表示向下，dx > 0 表示向右。
    public func scrollAt(
        token: String, screenshotID: String, x: Double, y: Double, dx: Double, dy: Double
    ) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(x, y, in: binding)
        guard abs(dx) + abs(dy) > 0 else {
            throw WireError.invalidCoordinates("滚动增量不能为 0。")
        }
        let start = Date()
        let point = globalPoint(x: x, y: y, binding: binding)
        _ = try reader.scrollAt(
            pid: r.pid, windowTitle: binding.windowTitle, x: point.x, y: point.y, dx: dx, dy: dy)
        return observeCoordinate(token: token, r: r, snap: snap, binding: binding, start: start)
    }

    /// 从截图坐标 (fromX, fromY) 拖到 (toX, toY)。
    public func drag(
        token: String, screenshotID: String,
        fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int
    ) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(fromX, fromY, in: binding)
        try checkPoint(toX, toY, in: binding)
        guard fromX != toX || fromY != toY else {
            throw WireError.invalidCoordinates("拖拽的起点与终点相同。")
        }
        let start = Date()
        let from = globalPoint(x: fromX, y: fromY, binding: binding)
        let to = globalPoint(x: toX, y: toY, binding: binding)
        _ = try reader.dragAt(
            pid: r.pid, windowTitle: binding.windowTitle,
            fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
            durationMs: max(100, min(2_000, durationMs)))
        return observeCoordinate(token: token, r: r, snap: snap, binding: binding, start: start)
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
    private func authorizedTarget(token: String, handle: Int) throws -> (pid: Int32, locator: ElementLocator) {
        if let r = records[token] {
            // 读取时身份查询失败：这里重查；仍然失败就不执行（无法确认策略，不放行）。
            let identity = try identity(for: r)
            if case .deny(let category) = policy.evaluate(pid: r.pid, bundleId: identity.bundleId) {
                throw WireError.policyDenied(category: category, app: identity.name ?? "pid \(r.pid)")
            }
            try authorizeApp(identity, pid: r.pid)
        }
        return try resolve(token: token, handle: handle)
    }

    /// 对令牌里的句柄执行动作。会话已知失效的令牌不会联系原生层。
    public func act(token: String, handle: Int, action: ActionKind) throws -> ActionOutcome {
        let (pid, locator) = try authorizedTarget(token: token, handle: handle)
        let outcome = try reader.performAction(pid: pid, locator: locator, action: action)
        if case .stale(let d) = outcome, let r = records[token] {
            invalidate(r, to: .stale)
            throw WireError.staleSnapshot("句柄 #\(handle) 已失效：\(Self.describe(d))。请重新读取界面。")
        }
        return outcome
    }

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
        try perform(token: token, handle: handle) { pid, locator in
            try reader.performAction(pid: pid, locator: locator, action: .press)
        }
    }

    /// 逐字输入到目标元素（先聚焦），再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func typeText(token: String, handle: Int, text: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, locator in
            try reader.typeText(pid: pid, locator: locator, text: text)
        }
    }

    /// 向目标元素发送按键（先聚焦），再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func pressKey(token: String, handle: Int, key: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, locator in
            try reader.pressKey(pid: pid, locator: locator, key: key)
        }
    }

    /// 通过无障碍接口直接写元素的值，再观察效果。
    // @project-doc docs/interfaces/mcp_surface.md#input_tools
    public func setValue(token: String, handle: Int, value: String) throws -> ClickReport {
        try perform(token: token, handle: handle) { pid, locator in
            try reader.setValue(pid: pid, locator: locator, value: value)
        }
    }

    /// 动作的统一路径：策略 → 令牌 → 原生层核对 → 投递 → 事后观察。
    /// 点击、输入、按键共用同一套效果摘要与令牌作废规则。
    private func perform(
        token: String, handle: Int, action: (Int32, ElementLocator) throws -> ActionOutcome
    ) throws -> ClickReport {
        // 先于动作取走动作前的快照信息：动作中途令牌可能被作废并释放快照。
        let pre = records[token]?.snapshot
        let (pid, locator) = try authorizedTarget(token: token, handle: handle)
        let outcome = try action(pid, locator)
        if case .stale(let d) = outcome, let r = records[token] {
            invalidate(r, to: .stale)
            throw WireError.staleSnapshot("句柄 #\(handle) 已失效：\(Self.describe(d))。请重新读取界面。")
        }
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
                let reading = try reader.readTree(pid: record.pid, maxDepth: pre.maxDepth, budgetMs: pre.budgetMs)
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

    /// 在树里沿定位器的路径找目标，并核对其核对键。路径对不上视为目标已不是原来那个。
    static func targetPresent(_ locator: ElementLocator, in root: AXNode) -> Bool {
        var current = root
        for step in locator.path {
            guard (current.childCount ?? current.children.count) == step.siblings,
                current.children.indices.contains(step.index)
            else { return false }
            let next = current.children[step.index]
            guard next.role == step.role else { return false }
            current = next
        }
        return TargetKey(current) == locator.target
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
