import Foundation

// @project-doc docs/decisions/adr_0024_app_authorization.md#app_authorization

/// 连接级的应用允许列表。
///
/// 一个 `scu mcp` 进程就是一条连接；列表在进程启动时确定，进程退出即失效。
/// 不引入 session id、TTL 或跨进程状态：宿主各自启动自己的 `scu mcp`，
/// 互不继承授权（ADR-0024）。
///
/// 默认 `.allowAll` 保持原有行为；显式配置允许列表后，列表外的应用
/// 在读取和动作之前就会被拒绝（`app_not_authorized`）。
public struct AppAuthorization: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case allowAll
        case allowlist
    }

    public let mode: Mode
    public let allowedBundleIds: Set<String>

    public init(mode: Mode = .allowAll, bundleIds: Set<String> = []) {
        self.mode = mode
        self.allowedBundleIds = Set(bundleIds.map(Self.normalize))
    }

    public static let allowAll = AppAuthorization(mode: .allowAll)

    /// 是否配置了允许列表。读取路径只在受限时提前查询应用身份。
    public var isRestricted: Bool { mode == .allowlist }

    /// bundle id 去空白并转小写；空值不匹配任何允许项。
    public static func normalize(_ bundleId: String) -> String {
        bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func permits(bundleId: String?) -> Bool {
        switch mode {
        case .allowAll:
            return true
        case .allowlist:
            guard let bundleId else { return false }
            let normalized = Self.normalize(bundleId)
            return !normalized.isEmpty && allowedBundleIds.contains(normalized)
        }
    }
}
