import Foundation
import SCUWire

/// 快照令牌：不透明字符串。每次读取签发，界面稳定时复用同一个。
public struct SnapshotToken: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { value }
}

/// 一次窗口截图，连同签发它的令牌。标签只包含落在截图窗口内的可交互元素。
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
    /// 与上一次同一窗口读取的差异；首次读取、切换目标、树被截断或读取参数变化时为 nil。
    public var diff: ElementTable.Diff?
}

/// 会话：保存快照与令牌状态，把"令牌 + 句柄"解析成动作定位器，并在失效时给出分类的错误。
///
/// 协议层保存快照，原生层保持无状态（ADR-0015）。非线程安全：动作在会话内串行。
// @project-doc docs/architecture/snapshot_lifecycle.md#p0_implementation
public final class DesktopSession {
    enum Status { case current, stale, switched }

    typealias Identity = TargetIdentity

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

    /// 差异基线：保留**上一次成功读取**的完整元素表，不随令牌失效而释放。
    /// 动作后令牌会失效、Record.snapshot 会被清掉；差异仍需要动作前的树。
    /// 只保留一份，切换目标或参数变化时自然失配，读取后替换。
    struct Baseline {
        var pid: Int32
        var windowTitle: String?
        var maxDepth: Int
        var budgetMs: Int
        var entries: [ElementTable.Entry]
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

    /// 按当前允许列表构造授权器。允许列表在运行期可能被测试替换，因此不缓存成存储属性。
    var authorizer: TargetAuthorizer {
        TargetAuthorizer(policy: policy, authorization: appAuthorization)
    }

    var screenshotBindings: [String: ScreenshotBinding] = [:]
    var screenshotOrder: [String] = []
    var screenshotCounter = 0
    let policy: PolicyGate
    let settle: Settle
    let retained: Int
    let nonce: String
    var counter = 0
    var records: [String: Record] = [:]
    var order: [String] = []
    var currentToken: String?
    var baseline: Baseline?

    /// 令牌从当前变为失效（含目标切换）的次数。同一令牌只迁移一次，重复使用不再增加。
    public private(set) var invalidations = 0

    /// 只允许会话内部（含同模块的扩展文件）记账，不把 setter 暴露给使用方。
    func recordInvalidation() { invalidations += 1 }

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
        try authorizer.denyIfForbidden(bundleId: resolved.bundleId, app: resolved.name)
        try authorizer.requireAuthorized(
            Identity(name: resolved.name, bundleId: resolved.bundleId),
            pid: resolved.pid)
        return try launcher.launch(identifier, activate: true)
    }

    // MARK: - 共享支持

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
            return "目标元素已不是读取时的那个"
                + (d.actual.map { "（现为 \($0.role)" + (label.isEmpty ? "）" : " \"\(label)\"）") } ?? "")
        }
    }
}
