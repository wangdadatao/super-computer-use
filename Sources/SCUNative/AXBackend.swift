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
            read: { el, wantChildren in
                let (node, kids) = readNode(el, wantChildren: wantChildren)
                for kid in kids { AXUIElementSetMessagingTimeout(kid, messagingTimeout) }
                return (node, kids)
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
    ///
    /// `read(元素, 是否需要子节点)` 一次返回节点自身的属性与（需要时）子节点：
    /// 在最大深度处不需要子节点，真实后端据此省掉那次读取。
    static func traverse<E>(
        root: E, maxDepth: Int, isExpired: () -> Bool,
        read: (E, Bool) -> (node: AXNode, children: [E])
    ) -> (root: AXNode, truncated: Bool) {
        var slots: [TraversalSlot] = []
        var queue: [(el: E, depth: Int, parent: Int)] = [(root, 0, -1)]
        var head = 0
        var truncated = false

        while head < queue.count {
            // 根节点总是会被读取：预算在读第一个节点前就到期，也要返回一棵只有根的树，
            // 而不是空树（空树无法构造根）。
            if !slots.isEmpty, isExpired() {
                truncated = true
                break
            }
            let (el, depth, parent) = queue[head]
            head += 1
            let index = slots.count
            let wantChildren = depth < maxDepth
            var (node, kids) = read(el, wantChildren)
            // 记录平台报告的真实子节点数：预算耗尽时 children 会短于它（ADR-0015）。
            node.childCount = wantChildren ? kids.count : nil
            slots.append(TraversalSlot(node: node))
            if parent >= 0 { slots[parent].kids.append(index) }
            if wantChildren {
                for kid in kids { queue.append((kid, depth + 1, index)) }
            }
        }

        func build(_ i: Int) -> AXNode {
            var n = slots[i].node
            n.children = slots[i].kids.map(build)
            return n
        }
        return (build(0), truncated)
    }

    static let nodeAttributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, "AXIdentifier", kAXValueAttribute,
        kAXRoleDescriptionAttribute, kAXDescriptionAttribute, kAXEnabledAttribute,
        kAXPositionAttribute, kAXSizeAttribute,
    ]

    /// 读取一个节点：**一次批量调用**取回全部属性（含子节点），而不是每个属性一次跨进程调用。
    /// 批量失败（返回非成功，或结果数量不符）时退回逐属性读取，结果语义相同。
    static func readNode(_ el: AXUIElement, wantChildren: Bool) -> (node: AXNode, children: [AXUIElement]) {
        var names = nodeAttributeNames
        if wantChildren { names.append(kAXChildrenAttribute) }
        var out: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard status == .success, let values = out as? [CFTypeRef], values.count == names.count else {
            return fallbackReadNode(el, wantChildren: wantChildren)
        }
        // 取不到的属性以 AXValue(.axError) 占位，视为缺失。
        func got(_ i: Int) -> CFTypeRef? {
            let v = values[i]
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
        let node = AXNode(
            role: asString(got(0)) ?? "AXUnknown",
            subrole: asString(got(1)),
            title: asString(got(2)),
            identifier: asString(got(3)),
            value: asValueText(got(4)),
            roleDescription: asString(got(5)),
            description: asString(got(6)),
            enabled: asBool(got(7)),
            frame: asFrame(position: got(8), size: got(9)),
            children: [])
        return (node, wantChildren ? asElements(got(10)) ?? [] : [])
    }

    static func fallbackReadNode(_ el: AXUIElement, wantChildren: Bool) -> (node: AXNode, children: [AXUIElement]) {
        let node = AXNode(
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
        return (node, wantChildren ? elements(el, kAXChildrenAttribute) ?? [] : [])
    }

    // MARK: - 属性读取

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success else { return nil }
        return out
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { asString(copy(el, attr)) }
    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? { asBool(copy(el, attr)) }
    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? { asElements(copy(el, attr)) }
    static func valueText(_ el: AXUIElement) -> String? { asValueText(copy(el, kAXValueAttribute)) }
    static func frame(_ el: AXUIElement) -> Rect? {
        asFrame(position: copy(el, kAXPositionAttribute), size: copy(el, kAXSizeAttribute))
    }

    // MARK: - 值转换（逐属性读取与批量读取共用，保证两条路径语义一致）

    static func asString(_ v: CFTypeRef?) -> String? {
        guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        let s = v as! String
        return s.isEmpty ? nil : s
    }

    static func asBool(_ v: CFTypeRef?) -> Bool? {
        guard let v, CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    static func asElements(_ v: CFTypeRef?) -> [AXUIElement]? {
        guard let v, CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        return v as? [AXUIElement]
    }

    /// AXValue 可能是字符串、数字或布尔；统一成文本。其余类型（点、区间等）忽略。
    static func asValueText(_ v: CFTypeRef?) -> String? {
        guard let v else { return nil }
        let type = CFGetTypeID(v)
        if type == CFStringGetTypeID() { return (v as! String).isEmpty ? nil : (v as! String) }
        if type == CFNumberGetTypeID() { return "\(v as! NSNumber)" }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) ? "true" : "false" }
        return nil
    }

    static func asFrame(position p: CFTypeRef?, size s: CFTypeRef?) -> Rect? {
        guard let p, CFGetTypeID(p) == AXValueGetTypeID(), let s, CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
    }
}
