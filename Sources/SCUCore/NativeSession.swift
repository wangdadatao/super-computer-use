import Foundation
import SCUWire

/// 一次树读取的结果。
public struct TreeReading: Equatable, Sendable {
    public var root: AXNode
    /// 时间预算耗尽，树不完整。
    public var truncated: Bool

    public init(root: AXNode, truncated: Bool) {
        self.root = root
        self.truncated = truncated
    }
}

/// 接入层需要的只读桌面能力。把它抽成协议，是为了让接入层（MCP）的测试
/// 不必拉起真实的原生进程，也不依赖本机权限。
public protocol DesktopReader {
    func checkPermissions() throws -> Bool
    func listApps() throws -> [AppInfo]
    func listWindows(pid: Int32) throws -> [WindowInfo]
    func readTree(
        pid: Int32, windowTitle: String?, maxDepth: Int, budgetMs: Int
    ) throws -> TreeReading
    func performAction(
        pid: Int32, windowTitle: String?, locator: ElementLocator, action: ActionKind
    ) throws -> ActionOutcome
    func typeText(
        pid: Int32, windowTitle: String?, locator: ElementLocator, text: String
    ) throws -> ActionOutcome
    func pressKey(
        pid: Int32, windowTitle: String?, locator: ElementLocator, key: String
    ) throws -> ActionOutcome
    func setValue(
        pid: Int32, windowTitle: String?, locator: ElementLocator, value: String
    ) throws -> ActionOutcome
    func captureWindow(pid: Int32, windowTitle: String?) throws -> WindowCapture
    func clickAt(pid: Int32, windowTitle: String?, x: Double, y: Double) throws -> ActionOutcome
    func scrollAt(
        pid: Int32, windowTitle: String?, x: Double, y: Double, dx: Double, dy: Double
    ) throws -> ActionOutcome
    func dragAt(
        pid: Int32, windowTitle: String?, fromX: Double, fromY: Double, toX: Double, toY: Double,
        durationMs: Int
    ) throws -> ActionOutcome
}

extension DesktopReader {
    /// 测试替身默认不支持窗口列表；真实读取器实现它。
    public func listWindows(pid: Int32) throws -> [WindowInfo] {
        throw WireError.unsupportedOperation("这个读取器不支持窗口列表")
    }

    /// 测试替身默认不支持输入；真实读取器实现它。
    public func typeText(
        pid: Int32, windowTitle: String?, locator: ElementLocator, text: String
    ) throws -> ActionOutcome {
        throw WireError.unsupportedOperation("这个读取器不支持逐字输入")
    }

    public func pressKey(
        pid: Int32, windowTitle: String?, locator: ElementLocator, key: String
    ) throws -> ActionOutcome {
        throw WireError.unsupportedOperation("这个读取器不支持按键")
    }

    public func setValue(
        pid: Int32, windowTitle: String?, locator: ElementLocator, value: String
    ) throws -> ActionOutcome {
        throw WireError.unsupportedOperation("这个读取器不支持设值")
    }

    public func captureWindow(pid: Int32, windowTitle: String?) throws -> WindowCapture {
        throw WireError.unsupportedOperation("这个读取器不支持窗口截图")
    }

    public func clickAt(pid: Int32, windowTitle: String?, x: Double, y: Double) throws -> ActionOutcome {
        throw WireError.unsupportedOperation("这个读取器不支持坐标点击")
    }

    public func scrollAt(
        pid: Int32, windowTitle: String?, x: Double, y: Double, dx: Double, dy: Double
    ) throws -> ActionOutcome {
        throw WireError.unsupportedOperation("这个读取器不支持滚动")
    }

    public func dragAt(
        pid: Int32, windowTitle: String?, fromX: Double, fromY: Double, toX: Double, toY: Double,
        durationMs: Int
    ) throws -> ActionOutcome {
        throw WireError.unsupportedOperation("这个读取器不支持拖拽")
    }
}

/// 一次动作请求的结果。定位器与界面不符时**没有执行任何动作**。
public enum ActionOutcome: Equatable, Sendable {
    /// 动作已投递给平台（平台未报错），不代表界面已经变化。
    case acted
    /// `verify` 通过。
    case located
    case stale(StaleDetail)
}

/// 长驻服务用的原生进程会话：**首次使用时才启动** sidecar，连接断开后下次调用自动重建。
///
/// - 懒启动：`initialize` 与 `tools/list` 不需要原生进程，宿主只是列出工具时不应拉起子进程。
/// - 自动重建：原生进程崩溃或超时被终止后（`platform_unavailable`），丢弃旧连接，
///   下一次调用重新拉起。长驻服务不能因为一次读树失败就永久不可用。
/// - 所有失败统一为 `WireError`，调用方只需按 `code` 分支。
///
/// 非线程安全：动作在会话内串行（session_and_lease.md），接入层单线程顺序调用。
// @project-doc docs/architecture/system_overview.md#process_boundary
public final class NativeSession: DesktopReader {
    private let nativeExecutable: URL
    private var client: NativeClient?

    public init(nativeExecutable: URL) {
        self.nativeExecutable = nativeExecutable
    }

    private func withClient<T>(_ body: (NativeClient) throws -> T) throws -> T {
        if client == nil {
            do {
                client = try NativeClient(nativeExecutable: nativeExecutable)
            } catch let e as WireError {
                throw e
            } catch {
                throw WireError.platformUnavailable("无法启动原生进程：\(error)")
            }
        }
        guard let c = client else { throw WireError.internalError("原生连接丢失") }
        do {
            return try body(c)
        } catch let e as WireError {
            // 超时会让 NativeClient 关闭连接；动作超时还会返回 action_outcome_unknown。
            // 这两种情况都必须丢弃旧连接，下一次调用重新拉起 sidecar。
            if e.code == "platform_unavailable" || e.code == "action_outcome_unknown" {
                c.close()
                client = nil
            }
            throw e
        } catch let e as NativeClient.ClientError {
            // 应答 id 对不上说明帧流已经错位，不能再复用这条连接。
            if case .unexpectedResponse = e {
                c.close()
                client = nil
            }
            throw e
        }
    }

    public func checkPermissions() throws -> Bool {
        try withClient { c in
            guard case .permissions(let ax) = try c.call(.checkPermissions) else {
                throw WireError.internalError("权限检测的应答类型错误")
            }
            return ax
        }
    }

    public func listApps() throws -> [AppInfo] {
        try withClient { c in
            guard case .apps(let apps) = try c.call(.listApps) else {
                throw WireError.internalError("应用列表的应答类型错误")
            }
            return apps
        }
    }

    public func listWindows(pid: Int32) throws -> [WindowInfo] {
        try withClient { c in
            guard case .windows(let windows) = try c.call(.listWindows(pid: pid)) else {
                throw WireError.internalError("窗口列表的应答类型错误")
            }
            return windows
        }
    }

    public func readTree(
        pid: Int32, windowTitle: String?, maxDepth: Int, budgetMs: Int
    ) throws -> TreeReading {
        try withClient { c in
            // 客户端等待上限 = 时间预算 + 余量（单次 AX 调用最多再耗 2 秒，加上编码与传输）。
            guard
                case .tree(let root, let truncated) = try c.call(
                    .dumpTree(pid: pid, windowTitle: windowTitle, maxDepth: maxDepth, budgetMs: budgetMs),
                    timeoutMs: Int32(budgetMs + 10_000))
            else {
                throw WireError.internalError("读树的应答类型错误")
            }
            return TreeReading(root: root, truncated: truncated)
        }
    }

    public func performAction(
        pid: Int32, windowTitle: String?, locator: ElementLocator, action: ActionKind
    ) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .performAction(pid: pid, windowTitle: windowTitle, locator: locator, action: action),
                timeoutMs: 30_000, actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .located: return .located
            case .stale(let d): return .stale(d)
            default: throw WireError.internalError("动作的应答类型错误")
            }
        }
    }

    public func typeText(
        pid: Int32, windowTitle: String?, locator: ElementLocator, text: String
    ) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .typeText(pid: pid, windowTitle: windowTitle, locator: locator, text: text),
                timeoutMs: scuTypeTextTimeoutMs(characterCount: text.count),
                actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .stale(let d): return .stale(d)
            default: throw WireError.internalError("输入应答类型错误")
            }
        }
    }

    public func pressKey(
        pid: Int32, windowTitle: String?, locator: ElementLocator, key: String
    ) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .pressKey(pid: pid, windowTitle: windowTitle, locator: locator, key: key),
                timeoutMs: 30_000, actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .stale(let d): return .stale(d)
            default: throw WireError.internalError("按键应答类型错误")
            }
        }
    }

    public func setValue(
        pid: Int32, windowTitle: String?, locator: ElementLocator, value: String
    ) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .setValue(pid: pid, windowTitle: windowTitle, locator: locator, value: value),
                timeoutMs: 30_000, actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .stale(let d): return .stale(d)
            default: throw WireError.internalError("设值应答类型错误")
            }
        }
    }

    public func captureWindow(pid: Int32, windowTitle: String?) throws -> WindowCapture {
        try withClient { c in
            guard
                case .windowCapture(let capture) = try c.call(
                    .captureWindow(pid: pid, windowTitle: windowTitle), timeoutMs: 35_000)
            else {
                throw WireError.internalError("截图的应答类型错误")
            }
            return capture
        }
    }

    public func clickAt(pid: Int32, windowTitle: String?, x: Double, y: Double) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .clickAt(pid: pid, windowTitle: windowTitle, x: x, y: y), timeoutMs: 10_000,
                actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .failure(let e): throw e
            default: throw WireError.internalError("坐标点击的应答类型错误")
            }
        }
    }

    public func scrollAt(
        pid: Int32, windowTitle: String?, x: Double, y: Double, dx: Double, dy: Double
    ) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .scrollAt(pid: pid, windowTitle: windowTitle, x: x, y: y, dx: dx, dy: dy),
                timeoutMs: 10_000, actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .failure(let e): throw e
            default: throw WireError.internalError("滚动的应答类型错误")
            }
        }
    }

    public func dragAt(
        pid: Int32, windowTitle: String?, fromX: Double, fromY: Double, toX: Double, toY: Double,
        durationMs: Int
    ) throws -> ActionOutcome {
        try withClient { c in
            switch try c.call(
                .dragAt(
                    pid: pid, windowTitle: windowTitle, fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                    durationMs: durationMs),
                timeoutMs: 15_000, actionMayHaveStarted: true)
            {
            case .acted: return .acted
            case .failure(let e): throw e
            default: throw WireError.internalError("拖拽的应答类型错误")
            }
        }
    }

    public func close() {
        client?.close()
        client = nil
    }

    deinit {
        close()
    }
}
