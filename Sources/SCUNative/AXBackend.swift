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

    /// 遍历的时间预算。超出后停止展开更多节点，并标记截断（而不是无限等待）。
    final class TraversalBudget {
        let deadline: Date
        private(set) var truncated = false
        init(milliseconds: Int) { deadline = Date().addingTimeInterval(Double(milliseconds) / 1000) }
        /// 是否已超时。一旦超时即记录截断。
        var expired: Bool {
            if truncated { return true }
            if Date() >= deadline { truncated = true }
            return truncated
        }
    }

    public struct TreeResult: Sendable {
        public var root: AXNode
        /// 因时间预算耗尽而未读完。深度上限造成的未展开不算截断（那是调用方的选择）。
        public var truncated: Bool
    }

    /// 读取某个进程的无障碍树。`budgetMs` 是整棵树的总时限；单次 AX 调用另有 `messagingTimeout`。
    public static func dumpTree(pid: Int32, maxDepth: Int, budgetMs: Int) throws -> TreeResult {
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
        let budget = TraversalBudget(milliseconds: budgetMs)
        let (root, truncated) = traverse(
            root: app, maxDepth: maxDepth,
            isExpired: { budget.expired },
            read: { el in nodeAttributes(el) },
            children: { el in
                let kids = elements(el, kAXChildrenAttribute) ?? []
                for kid in kids { AXUIElementSetMessagingTimeout(kid, messagingTimeout) }
                return kids
            })
        return TreeResult(root: root, truncated: truncated)
    }

    struct TraversalSlot {
        var node: AXNode
        var kids: [Int] = []
    }

    /// **按层级（广度优先）遍历**，时间预算耗尽时丢弃尚未读取的节点。
    ///
    /// 不用深度优先：先序遍历在预算耗尽时会丢掉"后面的兄弟"，而一棵巨大的早期子树
    /// （访达的文件列表、Electron 的网页内容）会吃掉全部预算，工具栏、侧边栏等结构性元素读不到。
    /// 广度优先保证被丢弃的永远是最深、最晚发现的节点，整体结构先完整。
    ///
    /// `truncated` 只在**确实丢弃了待读节点**时为真：预算在最后一个节点读完后才到期，不算截断。
    /// 泛型 + 注入的读取函数，是为了不依赖真实应用就能测遍历顺序与截断语义。
    static func traverse<E>(
        root: E, maxDepth: Int, isExpired: () -> Bool,
        read: (E) -> AXNode, children: (E) -> [E]
    ) -> (root: AXNode, truncated: Bool) {
        var slots: [TraversalSlot] = []
        var queue: [(el: E, depth: Int, parent: Int)] = [(root, 0, -1)]
        var head = 0
        var truncated = false

        while head < queue.count {
            if isExpired() {
                truncated = true
                break
            }
            let (el, depth, parent) = queue[head]
            head += 1
            let index = slots.count
            slots.append(TraversalSlot(node: read(el)))
            if parent >= 0 { slots[parent].kids.append(index) }
            if depth < maxDepth {
                for kid in children(el) { queue.append((kid, depth + 1, index)) }
            }
        }

        func build(_ i: Int) -> AXNode {
            var n = slots[i].node
            n.children = slots[i].kids.map(build)
            return n
        }
        return (build(0), truncated)
    }

    static func nodeAttributes(_ el: AXUIElement) -> AXNode {
        AXNode(
            role: string(el, kAXRoleAttribute) ?? "AXUnknown",
            subrole: string(el, kAXSubroleAttribute),
            title: string(el, kAXTitleAttribute),
            identifier: string(el, "AXIdentifier"),
            value: valueText(el),
            roleDescription: string(el, kAXRoleDescriptionAttribute),
            description: string(el, kAXDescriptionAttribute),
            enabled: bool(el, kAXEnabledAttribute),
            frame: frame(el),
            children: [])
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
