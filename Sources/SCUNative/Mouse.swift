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
    static func scrollAt(pid: Int32, x: Double, y: Double, dx: Double, dy: Double) throws {
        try WindowActivation.activate(pid: pid)
        let point = CGPoint(x: x, y: y)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw WireError.actionFailed("无法创建滚轮事件源")
        }
        // wheel1 的正方向是向上；对外约定 dy > 0 表示向下滚。
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0)
        else {
            throw WireError.actionFailed("无法创建滚轮事件")
        }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    static func dragAt(
        pid: Int32, fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int
    ) throws {
        try WindowActivation.activate(pid: pid)
        let start = CGPoint(x: fromX, y: fromY)
        let end = CGPoint(x: toX, y: toY)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw WireError.actionFailed("无法创建拖拽事件源")
        }
        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        }
        guard let move = event(.mouseMoved, start),
            let down = event(.leftMouseDown, start),
            let up = event(.leftMouseUp, end)
        else {
            throw WireError.actionFailed("无法创建拖拽事件")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        down.post(tap: .cghidEventTap)

        let steps = 12
        let duration = max(100, min(2_000, durationMs))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            guard let dragged = event(.leftMouseDragged, point) else { continue }
            dragged.post(tap: .cghidEventTap)
            usleep(useconds_t(duration * 1_000 / steps))
        }
        up.post(tap: .cghidEventTap)
    }

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
