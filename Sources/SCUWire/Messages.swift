import Foundation

/// 协议层 ↔ 原生层的协议版本。单调递增整数，两侧必须完全相等（ADR-0012）。
/// 编译期常量：不是运行时可变状态。
public let scuNativeProtocolVersion = 1

/// `dumpTree` 允许的最大深度。超出时原生层拒绝，不做静默截断。
public let scuMaxTreeDepth = 64

/// 线上错误。code 取自错误码表。
///
/// **P0 子集**：`error_taxonomy.md` 的 `ScuError` 还定义了 `details` 与 `candidates`，
/// P0 用不到，这里没有实现。补齐时需同步 `native_wire_protocol.md` 的错误一节。
// @project-doc docs/interfaces/error_taxonomy.md#error_structure
public struct WireError: Error, Codable, Sendable, Equatable {
    public var code: String
    public var layer: String
    public var retry: String
    public var message: String

    public init(code: String, layer: String, retry: String, message: String) {
        self.code = code
        self.layer = layer
        self.retry = retry
        self.message = message
    }

    public static func versionMismatch(client: Int, server: Int) -> WireError {
        WireError(
            code: "protocol_version_mismatch", layer: "boundary", retry: "no",
            message: "协议版本不一致：协议层 \(client)，原生层 \(server)")
    }

    public static func permissionMissing(_ what: String) -> WireError {
        WireError(
            code: "system_permission_missing", layer: "platform", retry: "after_user_action",
            message: "未授予系统权限：\(what)")
    }

    public static func targetMissing(pid: Int32) -> WireError {
        WireError(
            code: "target_missing", layer: "protocol", retry: "no",
            message: "进程 \(pid) 不存在或没有可读的无障碍树")
    }

    /// 原生进程不可达或已崩溃。
    public static func platformUnavailable(_ message: String) -> WireError {
        WireError(code: "platform_unavailable", layer: "platform", retry: "immediate", message: message)
    }

    public static func internalError(_ message: String) -> WireError {
        WireError(code: "internal_error", layer: "boundary", retry: "immediate", message: message)
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var bundleId: String?

    public init(pid: Int32, name: String, bundleId: String?) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
    }
}

public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 原生层如实返回的一个无障碍节点。
/// 原生层只返回平台事实，不判断“是不是同一个元素”（system_overview.md 职责边界）。
public struct AXNode: Codable, Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var roleDescription: String?
    public var enabled: Bool?
    public var frame: Rect?
    public var children: [AXNode]

    public init(
        role: String, subrole: String? = nil, title: String? = nil,
        identifier: String? = nil, value: String? = nil, roleDescription: String? = nil,
        enabled: Bool? = nil, frame: Rect? = nil, children: [AXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.value = value
        self.roleDescription = roleDescription
        self.enabled = enabled
        self.frame = frame
        self.children = children
    }
}

// MARK: - 消息

// 线上格式是**显式定义**的扁平对象，以 `type` 字段区分种类，见 native_wire_protocol.md。
// 刻意不使用 Swift 对带关联值 enum 的合成 Codable：它产生 `{"_0": …}` 形状，
// 既不可读，也会随重构静默改变线上格式。

// @project-doc docs/interfaces/native_wire_protocol.md#message_catalog
public enum Request: Sendable, Equatable {
    case hello(protocolVersion: Int)
    case checkPermissions
    case listApps
    case dumpTree(pid: Int32, maxDepth: Int)
}

public enum Response: Sendable, Equatable {
    case hello(protocolVersion: Int)
    case permissions(accessibility: Bool)
    case apps([AppInfo])
    case tree(AXNode)
    case failure(WireError)
}

extension Request: Codable {
    private enum Key: String, CodingKey { case type, protocolVersion, pid, maxDepth }
    private enum Kind: String, Codable { case hello, checkPermissions, listApps, dumpTree }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
        case .checkPermissions: self = .checkPermissions
        case .listApps: self = .listApps
        case .dumpTree:
            self = .dumpTree(
                pid: try c.decode(Int32.self, forKey: .pid), maxDepth: try c.decode(Int.self, forKey: .maxDepth))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .hello(let v):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(v, forKey: .protocolVersion)
        case .checkPermissions: try c.encode(Kind.checkPermissions, forKey: .type)
        case .listApps: try c.encode(Kind.listApps, forKey: .type)
        case .dumpTree(let pid, let depth):
            try c.encode(Kind.dumpTree, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(depth, forKey: .maxDepth)
        }
    }
}

extension Response: Codable {
    private enum Key: String, CodingKey { case type, protocolVersion, accessibility, apps, tree, error }
    private enum Kind: String, Codable { case hello, permissions, apps, tree, failure }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
        case .permissions: self = .permissions(accessibility: try c.decode(Bool.self, forKey: .accessibility))
        case .apps: self = .apps(try c.decode([AppInfo].self, forKey: .apps))
        case .tree: self = .tree(try c.decode(AXNode.self, forKey: .tree))
        case .failure: self = .failure(try c.decode(WireError.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .hello(let v):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(v, forKey: .protocolVersion)
        case .permissions(let ax):
            try c.encode(Kind.permissions, forKey: .type)
            try c.encode(ax, forKey: .accessibility)
        case .apps(let a):
            try c.encode(Kind.apps, forKey: .type)
            try c.encode(a, forKey: .apps)
        case .tree(let t):
            try c.encode(Kind.tree, forKey: .type)
            try c.encode(t, forKey: .tree)
        case .failure(let e):
            try c.encode(Kind.failure, forKey: .type)
            try c.encode(e, forKey: .error)
        }
    }
}

public struct RequestFrame: Codable, Sendable, Equatable {
    public var id: Int
    public var request: Request

    public init(id: Int, request: Request) {
        self.id = id
        self.request = request
    }
}

public struct ResponseFrame: Codable, Sendable, Equatable {
    public var id: Int
    public var response: Response

    public init(id: Int, response: Response) {
        self.id = id
        self.response = response
    }
}
