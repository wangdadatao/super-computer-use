import AppKit
import ApplicationServices
import Foundation
import SCUWire

// @project-doc docs/decisions/adr_0025_window_target.md#window_target

/// 把目标应用/窗口带到前台。坐标点击与截图前都需要：
/// 窗口在别的 Space/显示器时，ScreenCaptureKit 的 frame 与真实屏幕坐标可能不一致。
enum WindowActivation {
    /// 被激活的窗口。截图用它匹配同一个 SCWindow，避免“激活 A、截 B”。
    struct ActivatedWindow {
        var pid: Int32
        var windowID: UInt32?
        var title: String?
        var frame: Rect?
    }

    /// 激活目标窗口。`target.windowID` 优先，其次标题，最后是默认的“最大非最小化窗口”。
    /// 找不到显式指定的窗口时失败，不退回另一个窗口。
    ///
    /// 每次都完整执行 `activate` + `AXRaise`：只在前台标志上“已经是它”不够——窗口可能被
    /// 别的应用的窗口挡着，或还在另一个 Space 上；跳过抬升会让后续坐标点击落到遮挡它的
    /// 应用上。激活造成的 AX 变化不再污染基线：基线改在最后一次激活之后采（A2）。
    @discardableResult
    static func activate(target: Target) throws -> ActivatedWindow {
        guard let app = NSRunningApplication(processIdentifier: target.pid) else {
            throw WireError.targetMissing(pid: target.pid)
        }
        app.activate(options: [.activateIgnoringOtherApps])

        let windows = try AXBackend.nativeWindows(pid: target.pid)
        let chosen: AXBackend.NativeWindow?
        if let windowID = target.windowID {
            guard let match = windows.first(where: { $0.windowID == windowID }) else {
                throw WireError.windowNotFound(pid: target.pid, windowID: windowID)
            }
            chosen = match
        } else if let title = target.windowTitle {
            guard let match = windows.first(where: { $0.title == title }) else {
                throw WireError.windowNotFound(pid: target.pid, title: title)
            }
            chosen = match
        } else {
            let selectable = windows.filter { !$0.minimized }
            chosen = largestIndex(selectable.map(\.frame)).map { selectable[$0] }
        }
        if let chosen {
            AXUIElementPerformAction(chosen.element, kAXRaiseAction as CFString)
            // 只 raise 不会把 key 从同一应用的另一个窗口挪过来。key 窗口会影响标题栏与
            // 焦点类可观察属性，而前置基线是在激活之后采的，所以要先把激活做完整。
            AXUIElementSetAttributeValue(
                chosen.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                chosen.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
            if front, chosen.map({ isKeyWindow($0.element, pid: target.pid) }) ?? true { break }
            usleep(50_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw WireError.actionFailed("目标应用未能到前台，取消操作（避免作用到别的应用）")
        }
        // 给 WindowServer 一点时间把窗口放到当前 Space/显示器。
        usleep(150_000)
        return ActivatedWindow(
            pid: target.pid, windowID: chosen?.windowID, title: chosen?.title, frame: chosen?.frame)
    }

    /// 该窗口是否已是应用的 key 窗口（`AXFocusedWindow`）。读不到就当作不是。
    private static func isKeyWindow(_ element: AXUIElement, pid: Int32) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXBackend.messagingTimeout)
        guard let focused = AXBackend.copy(app, kAXFocusedWindowAttribute),
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return false
        }
        return CFEqual(focused as! AXUIElement, element)
    }

    /// 与截图相同的选择规则：面积最大的窗口。没有 frame 的窗口按 0 处理，
    /// 全部失败时回退到第一个窗口。
    static func largestIndex(_ frames: [Rect?]) -> Int? {
        guard !frames.isEmpty else { return nil }
        var best = 0
        var bestArea = area(frames[0])
        for i in 1..<frames.count {
            let a = area(frames[i])
            if a > bestArea {
                best = i
                bestArea = a
            }
        }
        return best
    }

    private static func area(_ frame: Rect?) -> Double {
        guard let frame, frame.width > 0, frame.height > 0 else { return 0 }
        return frame.width * frame.height
    }

}
