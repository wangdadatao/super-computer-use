import AppKit
import ApplicationServices
import Foundation
import SCUWire

/// 把目标应用/窗口带到前台。坐标点击与截图前都需要：
/// 窗口在别的 Space/显示器时，ScreenCaptureKit 的 frame 与真实屏幕坐标可能不一致。
enum WindowActivation {
    static func activate(pid: Int32) throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw WireError.targetMissing(pid: pid)
        }
        app.activate(options: [.activateIgnoringOtherApps])

        let axApp = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
            let list = windows as? [AXUIElement], let first = list.first
        {
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }

        let deadline = Date().addingTimeInterval(1.0)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, Date() < deadline {
            usleep(50_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw WireError.actionFailed("目标应用未能到前台，取消操作（避免作用到别的应用）")
        }
        // 给 WindowServer 一点时间把窗口放到当前 Space/显示器。
        usleep(150_000)
    }
}
