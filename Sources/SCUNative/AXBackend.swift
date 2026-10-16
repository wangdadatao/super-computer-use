import AppKit
import ApplicationServices
import SCUWire

/// 平台后端：把 macOS 无障碍 API 归一化为协议层需要的事实。
/// 只读取、不判断；不缓存跨调用状态。
// @project-doc docs/architecture/system_overview.md#responsibility_boundary
public enum AXBackend {
    /// 对每个 AX 调用设置的消息超时。跨进程 AX 调用可能挂起（崩溃隔离的理由之一）。
    static let messagingTimeout: Float = 2.0

    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func listApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "?", bundleId: $0.bundleIdentifier) }
            .sorted { $0.pid < $1.pid }
    }

    /// 读取某个进程的无障碍树。
    public static func dumpTree(pid: Int32, maxDepth: Int) throws -> AXNode {
        guard isAccessibilityTrusted() else {
            throw WireError.permissionMissing("辅助功能")
        }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw WireError.targetMissing(pid: pid)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        // 探测：连 role 都读不到，说明应用不暴露无障碍树。
        guard string(app, kAXRoleAttribute) != nil else {
            throw WireError.targetMissing(pid: pid)
        }
        return node(app, depth: 0, maxDepth: maxDepth)
    }

    static func node(_ el: AXUIElement, depth: Int, maxDepth: Int) -> AXNode {
        var children: [AXNode] = []
        if depth < maxDepth, let kids = elements(el, kAXChildrenAttribute) {
            children = kids.map { kid in
                AXUIElementSetMessagingTimeout(kid, messagingTimeout)
                return node(kid, depth: depth + 1, maxDepth: maxDepth)
            }
        }
        return AXNode(
            role: string(el, kAXRoleAttribute) ?? "AXUnknown",
            subrole: string(el, kAXSubroleAttribute),
            title: string(el, kAXTitleAttribute),
            identifier: string(el, "AXIdentifier"),
            value: valueText(el),
            roleDescription: string(el, kAXRoleDescriptionAttribute),
            enabled: bool(el, kAXEnabledAttribute),
            frame: frame(el),
            children: children)
    }

    // MARK: - 属性读取

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success else { return nil }
        return out
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = copy(el, attr), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        let s = v as! String
        return s.isEmpty ? nil : s
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = copy(el, attr), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
        guard let v = copy(el, attr), CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        return v as? [AXUIElement]
    }

    /// AXValue 可能是字符串、数字或布尔；统一成文本。其余类型（点、区间等）忽略。
    static func valueText(_ el: AXUIElement) -> String? {
        guard let v = copy(el, kAXValueAttribute) else { return nil }
        let type = CFGetTypeID(v)
        if type == CFStringGetTypeID() { return (v as! String).isEmpty ? nil : (v as! String) }
        if type == CFNumberGetTypeID() { return "\(v as! NSNumber)" }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) ? "true" : "false" }
        return nil
    }

    static func frame(_ el: AXUIElement) -> Rect? {
        guard let p = copy(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
            let s = copy(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
    }
}
