import ApplicationServices
import Foundation
import SCUWire

/// 坐标点击的落点探针（T-016 的 `selection_changed` 判据）。
///
/// 点击前在落点 hit-test 一次，记下元素与它的 `AXSelectedTextRange`；点击后**只读同一个
/// AXUIElement**。点击可能让 AppKit/Electron 重建元素，重测会绑定到另一个元素，把别人的
/// 选区变化算成这次点击的效果，所以这里刻意不做第二次 hit-test。
/// 探针只在一次 `clickAt` 调用内存活，不保存跨调用状态（ADR-0015）。
struct SelectionProbe {
    /// hit-test 到的元素；拿不到时 nil。
    private let element: AXUIElement?
    private let role: String?
    private let inTarget: Bool
    /// 点击前的选区快照；nil 表示“不进选区判据”（非文本元素或读不到该属性）。
    private let rangeBefore: String?
    private let note: String?
    private let clickCount: Int

    init(point: CGPoint, pid: Int32, clickCount: Int) {
        self.clickCount = clickCount
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        guard status == .success, let element = hit else {
            self.element = nil
            self.role = nil
            self.inTarget = false
            self.rangeBefore = nil
            self.note =
                "点击前无法在落点定位无障碍元素（\(AXBackend.axErrorName(status))），没有选区快照。"
            return
        }
        AXUIElementSetMessagingTimeout(element, AXBackend.messagingTimeout)
        let landedRole = AXBackend.string(element, kAXRoleAttribute)

        var owner: pid_t = 0
        let ownerStatus = AXUIElementGetPid(element, &owner)
        guard ownerStatus == .success, owner == pid else {
            self.element = nil
            self.role = landedRole
            self.inTarget = false
            self.rangeBefore = nil
            self.note =
                ownerStatus == .success
                ? "落点元素属于进程 \(owner)，不是目标进程 \(pid)。"
                : "无法确认落点元素属于哪个进程（\(AXBackend.axErrorName(ownerStatus))）。"
            return
        }

        // 按落点类型分流：只有文本控件才读选区；非文本角色一律不进选区判据，
        // 免得把“某个恰好带选区的非文本控件”当成文本落点。
        // 落点常常是文本控件内部的子节点（AXStaticText 等），所以沿祖先链找最近的那个
        // 文本控件——它在点击前记录，点击后仍只读这一个引用。
        guard let textElement = Self.textAncestor(of: element) else {
            self.element = nil
            self.role = landedRole
            self.inTarget = true
            self.rangeBefore = nil
            self.note = "落点元素 role=\(landedRole ?? "未知")，不在文本控件内，没走选区判据。"
            return
        }

        self.element = textElement
        self.role = AXBackend.string(textElement, kAXRoleAttribute) ?? landedRole
        self.inTarget = true
        let snapshot = Self.selectedRange(textElement)
        self.rangeBefore = snapshot.range
        self.note =
            snapshot.problem.map { "落点元素的 AXSelectedTextRange 读不到（\($0)），不进选区判据。" }
    }

    /// 点击后只读同一个 AX 引用。引用失效是“未知”，不是“没变化”。
    func afterClick() -> ClickProbe {
        guard let element else {
            return ClickProbe(
                role: role, inTarget: inTarget, rangeBefore: nil, rangeAfter: nil,
                elementValid: false, clickCount: clickCount, note: note)
        }
        let (status, _) = Self.copy(element, kAXRoleAttribute)
        guard status == .success else {
            return ClickProbe(
                role: role, inTarget: inTarget, rangeBefore: rangeBefore, rangeAfter: nil,
                elementValid: false, clickCount: clickCount,
                note: "落点元素的 AX 引用在点击后失效（\(AXBackend.axErrorName(status))），"
                    + "可能已被重建；不回退到全窗口或像素判据。")
        }
        // 没进选区判据的落点不读这个属性：读了也不用于判定。
        guard rangeBefore != nil else {
            return ClickProbe(
                role: role, inTarget: inTarget, rangeBefore: nil, rangeAfter: nil,
                elementValid: true, clickCount: clickCount, note: note)
        }
        var after = Self.selectedRange(element).range
        if after == nil {
            // 读不到不等于没变；偶发的 cannotComplete 值得重试一次。
            usleep(120_000)
            after = Self.selectedRange(element).range
        }
        return ClickProbe(
            role: role, inTarget: inTarget, rangeBefore: rangeBefore, rangeAfter: after,
            elementValid: true, clickCount: clickCount,
            note: after == nil ? "点击后读不到同一元素的 AXSelectedTextRange，无法确认选区变化。" : nil)
    }

    /// 与协议层同一份（原生层与协议层不能各自维护一份）。
    static let textRoles = scuSelectionTextRoles

    /// 从落点元素沿 AXParent 向上找最近的文本控件（最多 7 层）。
    /// 只用来确定“落点所在的文本元素”；引用在点击前记录，点击后不再重新 hit-test。
    private static func textAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<7 {
            guard let element = current else { return nil }
            if textRoles.contains(AXBackend.string(element, kAXRoleAttribute) ?? "") {
                return element
            }
            guard let parent = AXBackend.copy(element, kAXParentAttribute),
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            let next = parent as! AXUIElement
            AXUIElementSetMessagingTimeout(next, AXBackend.messagingTimeout)
            current = next
        }
        return nil
    }

    private static func selectedRange(_ element: AXUIElement) -> (range: String?, problem: String?) {
        let (status, value) = copy(element, kAXSelectedTextRangeAttribute)
        guard status == .success, let value else {
            return (nil, AXBackend.axErrorName(status))
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return (nil, "属性类型不是 AXValue")
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return (nil, "AXValue 不是 CFRange")
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return (nil, "AXValueGetValue 失败")
        }
        return ("\(range.location),\(range.length)", nil)
    }

    /// 与 `AXBackend.copy` 相同，但保留 AXError，用来区分“读不到”和“元素已失效”。
    private static func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (status, value)
    }
}
