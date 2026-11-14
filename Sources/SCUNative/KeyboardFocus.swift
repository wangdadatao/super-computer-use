import AppKit
import ApplicationServices
import Foundation
import SCUWire

/// 键盘动作投递前的焦点门禁（T-019 第二批 §1）。
///
/// 判据只看应用级 `AXFocusedUIElement`：它必须就是目标元素（`type_text`），
/// 或在目标窗口内且目标窗口就是 `AXFocusedWindow`（`press_key`）。
/// **不用元素自身的 `AXFocused`**（TextEdit 等应用会谎报），也不拿 `isActive` 当门禁
/// （事件走 `CGEvent.postToPid`，不要求前台）。失败时一个按键都不发。
enum KeyboardFocus {
    enum Action: String {
        case typeText = "type_text"
        case pressKey = "press_key"
    }

    enum Reason: String, CaseIterable {
        case focusedElementElsewhere = "focused_element_elsewhere"
        case focusedElementUnreadable = "focused_element_unreadable"
        case windowNotKey = "window_not_key"
    }

    /// 判定输入。`focusedWithinTargetWindow` 由调用方沿 `AXParent` 向上读出来；
    /// 目标没有窗口祖先时 `targetWindow` 为 nil，`press_key` 退化为必须与目标元素相等。
    struct Evidence {
        var focusedElement: AXUIElement?
        var focusedWindow: AXUIElement?
        var targetElement: AXUIElement
        var targetWindow: AXUIElement?
        var focusedWithinTargetWindow: Bool
    }

    /// 纯判定：nil 表示放行，否则是拒绝原因。表驱动单测见 `KeyboardFocusTests`。
    static func verdict(
        action: Action, _ evidence: Evidence,
        equals: (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) }
    ) -> Reason? {
        guard let focused = evidence.focusedElement else { return .focusedElementUnreadable }
        let onTarget =
            equals(focused, evidence.targetElement)
            || (evidence.targetWindow != nil && evidence.focusedWithinTargetWindow)
        guard onTarget else { return .focusedElementElsewhere }
        // 没有窗口祖先（菜单项等）时跳过 key window 判据。
        guard action == .pressKey, let targetWindow = evidence.targetWindow else { return nil }
        guard let focusedWindow = evidence.focusedWindow,
            equals(focusedWindow, targetWindow)
        else { return .windowNotKey }
        return nil
    }

    /// 投递前的门禁：读应用级焦点，判定失败时抛 `focus_not_established`。
    /// 调用点必须在字符/按键循环之前调用它。
    static func requireEstablished(
        action: Action, element: AXUIElement, pid: Int32
    ) throws {
        let focused = AXBackend.focusedElement(pid: pid)
        let targetWindow = AXBackend.enclosingWindow(of: element)
        let focusedWindow = AXBackend.focusedWindow(pid: pid)
        var within = false
        if action == .pressKey, let focused, let targetWindow {
            within = AXBackend.withinWindow(focused, window: targetWindow)
        }
        let evidence = Evidence(
            focusedElement: focused, focusedWindow: focusedWindow, targetElement: element,
            targetWindow: targetWindow, focusedWithinTargetWindow: within)
        guard let reason = verdict(action: action, evidence) else { return }
        throw error(
            reason: reason, observed: focused, pid: pid, raisedWindow: targetWindow != nil)
    }

    /// 三种原因的文案分开：读不到焦点 ≠ 焦点在别处 ≠ 窗口不是 key。
    /// 每条都写明已经发生的副作用（窗口已被抬到前台并尝试聚焦）与 `keys_posted=0`。
    static func error(
        reason: Reason, observed: AXUIElement?, pid: Int32, raisedWindow: Bool
    ) -> WireError {
        let role = observed.flatMap { AXBackend.string($0, kAXRoleAttribute) }
        let active = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        // 已经发生的副作用：有窗口祖先时先 raise 了窗口；没有时只尝试激活应用。
        let prefix = raisedWindow ? "目标窗口已被抬到前台并尝试聚焦，但" : "已尝试激活应用并聚焦目标，但"
        let suffix = "未发送任何按键。"
        let message: String
        switch reason {
        case .focusedElementElsewhere:
            let focusNote = role.map { "当前焦点在 \($0)" } ?? "焦点不在目标元素上"
            message =
                prefix + "焦点没有落到目标元素（\(focusNote)）。" + suffix
                + "请先处理挡住目标的窗口/sheet，或改用 set_value。"
        case .focusedElementUnreadable:
            message =
                prefix + "读不到应用的焦点元素，无法确认焦点已落到目标上。" + suffix
                + "请稍后重试，或改用 set_value。"
        case .windowNotKey:
            let focusNote = role.map { "当前焦点在 \($0)" } ?? "读不到当前焦点"
            message =
                prefix + "目标窗口不是 key window（\(focusNote)）。" + suffix
                + "请先处理挡住目标的窗口，或改用 set_value。"
        }
        return .focusNotEstablished(
            reason: reason.rawValue, observedRole: role, appActive: active, message: message)
    }
}
