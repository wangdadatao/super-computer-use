import Foundation

/// 协议层 ↔ 原生层的协议版本。单调递增整数，两侧必须完全相等（ADR-0012）。
/// 编译期常量：不是运行时可变状态。
public let scuNativeProtocolVersion = 9

/// `dumpTree` 允许的最大深度。超出时原生层拒绝，不做静默截断。
public let scuMaxTreeDepth = 64
/// `get_ax_state` 与 `scu dump` 共用的默认读取深度。
public let scuDefaultTreeDepth = 12

/// `dumpTree` 总时间预算的允许范围（毫秒）。超出范围被拒绝。
public let scuTreeBudgetMsRange = 100...120_000
public let scuDefaultTreeBudgetMs = 15_000

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

    /// 截图需要屏幕录制权限；它与辅助功能是两项独立授权，按宿主进程归属。
    public static func screenRecordingMissing() -> WireError {
        WireError(
            code: "system_permission_missing", layer: "platform", retry: "after_user_action",
            message: "未授予屏幕录制权限：请在 系统设置 > 隐私与安全性 > 屏幕录制 中授权启动本服务的宿主应用，然后重启该宿主。")
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

    /// 令牌已失效，或从未签发。树已变化，需要重读。
    public static func staleSnapshot(_ message: String) -> WireError {
        WireError(code: "stale_snapshot", layer: "protocol", retry: "after_refresh", message: message)
    }

    /// 令牌属于已被切换走的目标。
    public static func targetSwitched(_ message: String) -> WireError {
        WireError(code: "target_switched", layer: "protocol", retry: "after_rebind", message: message)
    }

    /// 句柄在该令牌的快照里不存在。
    public static func elementGone(_ message: String) -> WireError {
        WireError(code: "element_gone", layer: "protocol", retry: "after_refresh", message: message)
    }

    /// 平台拒绝了动作（目标仍在、定位器核对通过）。
    public static func actionFailed(_ message: String) -> WireError {
        WireError(code: "action_failed", layer: "platform", retry: "immediate", message: message)
    }

    /// 目标不支持所请求的动作。
    public static func unsupportedOperation(_ message: String) -> WireError {
        WireError(code: "unsupported_operation", layer: "protocol", retry: "no", message: message)
    }

    /// 截图/坐标令牌的窗口几何已变化。
    public static func staleGeometry(_ message: String) -> WireError {
        WireError(code: "stale_geometry", layer: "protocol", retry: "after_refresh", message: message)
    }

    /// 找不到要启动/解析的应用。
    public static func appNotFound(_ identifier: String) -> WireError {
        WireError(
            code: "app_not_found", layer: "protocol", retry: "no",
            message: "找不到应用 \(identifier)；请给 bundle id、显示名或 .app 路径。")
    }

    /// 坐标不在截图范围内。
    public static func invalidCoordinates(_ message: String) -> WireError {
        WireError(code: "invalid_coordinates", layer: "protocol", retry: "no", message: message)
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

/// 一次窗口截图：PNG 与把元素 frame 映射到图像像素所需的元数据。
/// `windowFrame` 是窗口在全局屏幕坐标（点）中的位置，可能是负值（副屏在左侧）。
public struct WindowCapture: Codable, Sendable, Equatable {
    public var png: Data
    /// 图像像素宽高。
    public var width: Int
    public var height: Int
    /// 图像像素 / 窗口点；Retina 或缩放后不一定等于 1。
    public var scale: Double
    public var windowFrame: Rect
    public var windowTitle: String?

    public init(
        png: Data, width: Int, height: Int, scale: Double, windowFrame: Rect, windowTitle: String? = nil
    ) {
        self.png = png
        self.width = width
        self.height = height
        self.scale = scale
        self.windowFrame = windowFrame
        self.windowTitle = windowTitle
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
    /// `AXDescription`。许多控件（如工具栏按钮）用它而不是 `title` 作标签。
    public var description: String?
    public var enabled: Bool?
    /// 平台声明的动作名（`AXUIElementCopyActionNames`）；空数组省略。
    /// 用于识别"角色不是按钮、但支持 AXPress"的行/分组（如网页侧边栏）。
    public var actions: [String]?
    public var frame: Rect?
    /// 平台报告的**真实**子节点数；只在读取过该节点的子节点时有值（深度上限处为 nil）。
    /// 广度优先读树预算耗尽时 `children` 可能短于它，动作定位器的"子节点总数"取自这里（ADR-0015）。
    public var childCount: Int?
    public var children: [AXNode]

    public init(
        role: String, subrole: String? = nil, title: String? = nil,
        identifier: String? = nil, value: String? = nil, roleDescription: String? = nil,
        description: String? = nil, enabled: Bool? = nil, actions: [String]? = nil,
        frame: Rect? = nil, childCount: Int? = nil, children: [AXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.value = value
        self.roleDescription = roleDescription
        self.description = description
        self.enabled = enabled
        self.actions = actions
        self.frame = frame
        self.childCount = childCount
        self.children = children
    }
}

// MARK: - 动作定位

/// 动作目标的核对键：动作时原生层读到的目标必须与它逐项相等（ADR-0015）。
public struct TargetKey: Codable, Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    public var description: String?

    public init(
        role: String, subrole: String? = nil, title: String? = nil, identifier: String? = nil,
        description: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.description = description
    }

    public init(_ node: AXNode) {
        self.init(
            role: node.role, subrole: node.subrole, title: node.title, identifier: node.identifier,
            description: node.description)
    }
}

/// 路径的一步：从父节点进入第 `index` 个子节点。
public struct PathStep: Codable, Sendable, Equatable {
    /// 在父节点子列表中的下标。
    public var index: Int
    /// 读取时父节点的子节点总数（不是快照里列表的长度）。
    public var siblings: Int
    /// 该节点读取时的角色。
    public var role: String

    public init(index: Int, siblings: Int, role: String) {
        self.index = index
        self.siblings = siblings
        self.role = role
    }
}

/// 从应用根节点到目标的路径，加上目标的核对键。空路径表示应用根节点本身。
// @project-doc docs/architecture/snapshot_lifecycle.md#p0_implementation
public struct ElementLocator: Codable, Sendable, Equatable {
    public var path: [PathStep]
    public var target: TargetKey

    public init(path: [PathStep], target: TargetKey) {
        self.path = path
        self.target = target
    }
}

public enum ActionKind: String, Codable, Sendable, Equatable {
    /// `AXPress`。
    case press
    /// 只做定位与核对，不执行任何动作。
    case verify
}

public enum StaleReason: String, Codable, Sendable, Equatable {
    /// 路径上某一层的子节点总数与读取时不同。
    case childCount
    /// 路径上某一层的节点角色与读取时不同，或下标越界。
    case role
    /// 到达目标，但核对键不一致。
    case target
}

/// 定位器与界面现状不符的事实。原生层只报告不符之处，不判断"是不是同一个元素"。
public struct StaleDetail: Codable, Sendable, Equatable {
    public var reason: StaleReason
    /// 不符发生在路径的第几步（从 0 起）；`target` 类为 nil。
    public var step: Int?
    /// 读到的实际子节点数（`childCount` 类）。
    public var actualCount: Int?
    /// 读到的实际核对键（`role`、`target` 类）。
    public var actual: TargetKey?

    public init(reason: StaleReason, step: Int? = nil, actualCount: Int? = nil, actual: TargetKey? = nil) {
        self.reason = reason
        self.step = step
        self.actualCount = actualCount
        self.actual = actual
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
    case dumpTree(pid: Int32, maxDepth: Int, budgetMs: Int)
    case performAction(pid: Int32, locator: ElementLocator, action: ActionKind)
    /// 把文本逐字输入到目标元素（先聚焦）。
    case typeText(pid: Int32, locator: ElementLocator, text: String)
    /// 向目标元素发送一个按键或组合键（先聚焦）。
    case pressKey(pid: Int32, locator: ElementLocator, key: String)
    /// 通过无障碍接口直接写元素的值（要求元素声明 AXValue 可写）。
    case setValue(pid: Int32, locator: ElementLocator, value: String)
    /// 截取目标应用的一个窗口，返回 PNG 与坐标映射元数据。
    case captureWindow(pid: Int32)
    /// 在全局屏幕坐标 (x, y) 投递一次鼠标左键点击。坐标由协议层从截图换算。
    case clickAt(pid: Int32, x: Double, y: Double)
    /// 在全局坐标 (x, y) 投递滚轮事件，dx/dy 为像素增量。
    case scrollAt(pid: Int32, x: Double, y: Double, dx: Double, dy: Double)
    /// 从全局坐标 (fromX, fromY) 拖到 (toX, toY)，持续 durationMs。
    case dragAt(pid: Int32, fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int)
}

public enum Response: Sendable, Equatable {
    case hello(protocolVersion: Int)
    case permissions(accessibility: Bool)
    case apps([AppInfo])
    case tree(AXNode, truncated: Bool)
    /// 动作已投递给平台（平台未报错）。不代表界面已经变化。
    case acted
    /// `verify` 通过：定位器与界面现状一致。
    case located
    /// 定位器与界面现状不符，**没有执行动作**。
    case stale(StaleDetail)
    /// 窗口截图。
    case windowCapture(WindowCapture)
    case failure(WireError)
}

extension Request: Codable {
    private enum Key: String, CodingKey {
        case type, protocolVersion, pid, maxDepth, budgetMs, locator, action, text, key, value, x, y,
            dx, dy, fromX, fromY, toX, toY, durationMs
    }
    private enum Kind: String, Codable {
        case hello, checkPermissions, listApps, dumpTree, performAction, typeText, pressKey, setValue
        case captureWindow, clickAt, scrollAt, dragAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
        case .checkPermissions: self = .checkPermissions
        case .listApps: self = .listApps
        case .dumpTree:
            self = .dumpTree(
                pid: try c.decode(Int32.self, forKey: .pid), maxDepth: try c.decode(Int.self, forKey: .maxDepth),
                budgetMs: try c.decode(Int.self, forKey: .budgetMs))
        case .performAction:
            self = .performAction(
                pid: try c.decode(Int32.self, forKey: .pid),
                locator: try c.decode(ElementLocator.self, forKey: .locator),
                action: try c.decode(ActionKind.self, forKey: .action))
        case .typeText:
            self = .typeText(
                pid: try c.decode(Int32.self, forKey: .pid),
                locator: try c.decode(ElementLocator.self, forKey: .locator),
                text: try c.decode(String.self, forKey: .text))
        case .pressKey:
            self = .pressKey(
                pid: try c.decode(Int32.self, forKey: .pid),
                locator: try c.decode(ElementLocator.self, forKey: .locator),
                key: try c.decode(String.self, forKey: .key))
        case .setValue:
            self = .setValue(
                pid: try c.decode(Int32.self, forKey: .pid),
                locator: try c.decode(ElementLocator.self, forKey: .locator),
                value: try c.decode(String.self, forKey: .value))
        case .captureWindow:
            self = .captureWindow(pid: try c.decode(Int32.self, forKey: .pid))
        case .clickAt:
            self = .clickAt(
                pid: try c.decode(Int32.self, forKey: .pid),
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y))
        case .scrollAt:
            self = .scrollAt(
                pid: try c.decode(Int32.self, forKey: .pid),
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                dx: try c.decode(Double.self, forKey: .dx),
                dy: try c.decode(Double.self, forKey: .dy))
        case .dragAt:
            self = .dragAt(
                pid: try c.decode(Int32.self, forKey: .pid),
                fromX: try c.decode(Double.self, forKey: .fromX),
                fromY: try c.decode(Double.self, forKey: .fromY),
                toX: try c.decode(Double.self, forKey: .toX),
                toY: try c.decode(Double.self, forKey: .toY),
                durationMs: try c.decode(Int.self, forKey: .durationMs))
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
        case .dumpTree(let pid, let depth, let budget):
            try c.encode(Kind.dumpTree, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(depth, forKey: .maxDepth)
            try c.encode(budget, forKey: .budgetMs)
        case .performAction(let pid, let locator, let action):
            try c.encode(Kind.performAction, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(locator, forKey: .locator)
            try c.encode(action, forKey: .action)
        case .typeText(let pid, let locator, let text):
            try c.encode(Kind.typeText, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(locator, forKey: .locator)
            try c.encode(text, forKey: .text)
        case .pressKey(let pid, let locator, let key):
            try c.encode(Kind.pressKey, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(locator, forKey: .locator)
            try c.encode(key, forKey: .key)
        case .setValue(let pid, let locator, let value):
            try c.encode(Kind.setValue, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(locator, forKey: .locator)
            try c.encode(value, forKey: .value)
        case .captureWindow(let pid):
            try c.encode(Kind.captureWindow, forKey: .type)
            try c.encode(pid, forKey: .pid)
        case .clickAt(let pid, let x, let y):
            try c.encode(Kind.clickAt, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .scrollAt(let pid, let x, let y, let dx, let dy):
            try c.encode(Kind.scrollAt, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case .dragAt(let pid, let fromX, let fromY, let toX, let toY, let durationMs):
            try c.encode(Kind.dragAt, forKey: .type)
            try c.encode(pid, forKey: .pid)
            try c.encode(fromX, forKey: .fromX)
            try c.encode(fromY, forKey: .fromY)
            try c.encode(toX, forKey: .toX)
            try c.encode(toY, forKey: .toY)
            try c.encode(durationMs, forKey: .durationMs)
        }
    }
}

extension Response: Codable {
    private enum Key: String, CodingKey {
        case type, protocolVersion, accessibility, apps, tree, truncated, error, stale, capture
    }
    private enum Kind: String, Codable {
        case hello, permissions, apps, tree, acted, located, stale, windowCapture, failure
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(protocolVersion: try c.decode(Int.self, forKey: .protocolVersion))
        case .permissions: self = .permissions(accessibility: try c.decode(Bool.self, forKey: .accessibility))
        case .apps: self = .apps(try c.decode([AppInfo].self, forKey: .apps))
        case .tree:
            self = .tree(
                try c.decode(AXNode.self, forKey: .tree), truncated: try c.decode(Bool.self, forKey: .truncated))
        case .acted: self = .acted
        case .located: self = .located
        case .stale: self = .stale(try c.decode(StaleDetail.self, forKey: .stale))
        case .windowCapture: self = .windowCapture(try c.decode(WindowCapture.self, forKey: .capture))
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
        case .tree(let t, let truncated):
            try c.encode(Kind.tree, forKey: .type)
            try c.encode(t, forKey: .tree)
            try c.encode(truncated, forKey: .truncated)
        case .acted: try c.encode(Kind.acted, forKey: .type)
        case .located: try c.encode(Kind.located, forKey: .type)
        case .stale(let d):
            try c.encode(Kind.stale, forKey: .type)
            try c.encode(d, forKey: .stale)
        case .windowCapture(let capture):
            try c.encode(Kind.windowCapture, forKey: .type)
            try c.encode(capture, forKey: .capture)
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
