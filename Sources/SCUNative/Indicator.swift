import AppKit
import Foundation

// @project-doc docs/decisions/adr_0023_indicator.md#indicator_decision

/// 坐标动作前的可见提示。窗口不接收鼠标事件、不参与截图（sharingType = .none），
/// 只让用户看到"AI 准备点这里"。
///
/// sidecar 的主循环是同步的，不能依赖 RunLoop 定时器；调用方按
/// show → 短暂等待 → 动作 → hide 的顺序使用。
enum Indicator {
    private final class Store: @unchecked Sendable { var windows: [NSWindow] = [] }
    private static let store = Store()

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SCU_INDICATOR"] != "0"
    }

    static func show(points: [CGPoint]) {
        guard isEnabled, !points.isEmpty, let main = NSScreen.screens.first else { return }
        AppKitBootstrap.ensureApplication()
        // sidecar 的同步主循环就在主线程上；AppKit 的窗口属性是 MainActor 隔离的，
        // 这里沿用 AppKitBootstrap 的显式断言，而不是让每个属性访问各自跨 actor。
        MainActor.assumeIsolated {
            hideWindows()
            let size: CGFloat = 48
            for point in points {
                // 全局点击坐标以主屏左上角为原点；AppKit 窗口坐标以左下角为原点。
                let y = main.frame.height - point.y
                let rect = NSRect(
                    x: point.x - size / 2, y: y - size / 2, width: size, height: size)
                let window = NSWindow(
                    contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.level = .floating
                window.ignoresMouseEvents = true
                window.hasShadow = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.sharingType = .none
                let view = RingView(frame: NSRect(x: 0, y: 0, width: size, height: size))
                window.contentView = view
                window.orderFrontRegardless()
                view.display()
                store.windows.append(window)
            }
        }
    }

    static func hide() {
        MainActor.assumeIsolated { hideWindows() }
    }

    /// 必须在主线程调用；show/hide 已各自做了断言。
    @MainActor private static func hideWindows() {
        for window in store.windows { window.close() }
        store.windows.removeAll()
    }
}

final class RingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6))
        NSColor.systemBlue.withAlphaComponent(0.25).setFill()
        ring.fill()
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        ring.lineWidth = 3
        ring.stroke()
    }
}
