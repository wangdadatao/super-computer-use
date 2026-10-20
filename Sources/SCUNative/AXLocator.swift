import ApplicationServices
import AppKit
import SCUWire

/// 动作定位：沿协议层给出的路径下行，逐层核对，到达目标后核对其核对键。
/// 原生层只比较事实，不判断"是不是同一个元素"，也不保存跨调用状态（ADR-0015）。
// @project-doc docs/architecture/snapshot_lifecycle.md#p0_implementation
extension AXBackend {
    enum LocateResult<E> {
        case found(E)
        case stale(StaleDetail)
    }

    /// 泛型 + 注入的读取函数，用来在不依赖真实应用的情况下测各种失效情形。
    static func locate<E>(
        root: E, locator: ElementLocator,
        children: (E) -> [E]?, key: (E) -> TargetKey
    ) -> LocateResult<E> {
        var current = root
        for (i, step) in locator.path.enumerated() {
            let kids = children(current) ?? []
            guard kids.count == step.siblings else {
                return .stale(StaleDetail(reason: .childCount, step: i, actualCount: kids.count))
            }
            guard kids.indices.contains(step.index) else {
                return .stale(StaleDetail(reason: .role, step: i, actualCount: kids.count))
            }
            let next = kids[step.index]
            let actual = key(next)
            guard actual.role == step.role else {
                return .stale(StaleDetail(reason: .role, step: i, actual: actual))
            }
            current = next
        }
        let actual = key(current)
        guard actual == locator.target else {
            return .stale(StaleDetail(reason: .target, actual: actual))
        }
        return .found(current)
    }

    public enum ActionResult: Sendable, Equatable {
        case acted
        case located
        case stale(StaleDetail)
    }

    public static func performAction(
        pid: Int32, windowTitle: String? = nil, locator: ElementLocator, action: ActionKind
    ) throws -> ActionResult {
        let root = try rootElement(pid: pid, windowTitle: windowTitle)

        let result = locate(
            root: root, locator: locator,
            children: { el in
                let kids = elements(el, kAXChildrenAttribute)
                for kid in kids ?? [] { AXUIElementSetMessagingTimeout(kid, messagingTimeout) }
                return kids
            },
            key: { el in TargetKey(readNode(el, wantChildren: false).node) })
        switch result {
        case .stale(let detail):
            return .stale(detail)
        case .found(let el):
            switch action {
            case .verify:
                return .located
            case .press:
                let status = AXUIElementPerformAction(el, kAXPressAction as CFString)
                switch status {
                case .success:
                    return .acted
                case .actionUnsupported, .attributeUnsupported, .notImplemented:
                    throw WireError.unsupportedOperation("目标不支持 AXPress（\(axErrorName(status))）")
                default:
                    throw WireError.actionFailed("AXPress 失败：\(axErrorName(status))")
                }
            }
        }
    }

    static func axErrorName(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(\(e.rawValue))"
        }
    }
}
