import AppKit
import CoreGraphics
import Foundation
import SCUWire

/// 坐标点击。目标点由协议层从截图换算为全局屏幕坐标。
///
/// 走真实鼠标事件并先把目标应用带到前台：网页/CEF 的自绘控件经常忽略
/// `CGEvent.postToPid` 的鼠标事件，而 AXPress 也可能对它们是空操作。
/// 这会移动真实光标并切换前台应用，代价是可见的，但这是坐标点击的语义。
enum Mouse {
    static func clickAt(pid: Int32, x: Double, y: Double) throws {
        try WindowActivation.activate(pid: pid)

        let point = CGPoint(x: x, y: y)
        guard let source = CGEventSource(stateID: .hidSystemState),
            let move = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left),
            let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)
        else {
            throw WireError.actionFailed("无法创建鼠标事件")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }
}
