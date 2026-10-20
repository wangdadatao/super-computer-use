import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SCUWire

/// 目标窗口的截图。只截一个窗口，不截整屏：
/// - 坐标以窗口左上角为原点，模型只需要处理一张图；
/// - 图像像素尺寸受上限约束，避免 MCP 返回过大的 base64；
/// - `scale` 是图像像素 / 窗口点，覆盖 Retina 与缩放。
enum ScreenCapture {
    /// 屏幕录制权限按宿主进程归属，不是整台机器。
    static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func captureWindow(pid: Int32) throws -> WindowCapture {
        guard isAuthorized() else { throw WireError.screenRecordingMissing() }

        // ScreenCaptureKit 依赖 WindowServer/CoreGraphics 的进程级初始化。
        // sidecar 是纯命令行进程；显式建立 NSApplication 共享实例，避免
        // CGS_REQUIRE_INIT 断言（真实崩溃，不是可捕获的错误）。
        _ = NSApplication.shared

        // 截图前把窗口带到当前 Space/显示器：否则 SCWindow.frame 可能与
        // AX/CGWindowList 的屏幕坐标不一致，模型拿到的坐标会点空。
        try WindowActivation.activate(pid: pid)

        let box = CaptureBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.value = try await capture(pid: pid)
            } catch {
                box.error = error
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            throw WireError.platformUnavailable("截图在 30 秒内没有完成")
        }
        if let error = box.error { throw error }
        guard let value = box.value else {
            throw WireError.platformUnavailable("截图没有返回结果")
        }
        return value
    }

    private final class CaptureBox: @unchecked Sendable {
        var value: WindowCapture?
        var error: Error?
    }

    private static func capture(pid: Int32) async throws -> WindowCapture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw WireError.platformUnavailable("无法枚举窗口：\(error)")
        }

        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID == pid else { return false }
            guard window.windowLayer == 0, window.isOnScreen else { return false }
            return window.frame.width >= 80 && window.frame.height >= 60
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            throw WireError.targetMissing(pid: pid)
        }

        let frame = window.frame
        // 上限 1600 像素宽：足够读文字，也不会让 MCP 单帧过大。
        let scale = min(2.0, max(0.5, 1600.0 / max(1.0, frame.width)))
        let width = max(1, Int((frame.width * scale).rounded()))
        let height = max(1, Int((frame.height * scale).rounded()))

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw WireError.platformUnavailable("截图失败：\(error)")
        }

        let png = try encodePNG(image)
        return WindowCapture(
            png: png,
            width: image.width,
            height: image.height,
            scale: Double(image.width) / max(1.0, frame.width),
            windowFrame: Rect(
                x: Double(frame.origin.x), y: Double(frame.origin.y),
                width: Double(frame.width), height: Double(frame.height)),
            windowTitle: window.title)
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else {
            throw WireError.platformUnavailable("无法创建 PNG 编码器")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WireError.platformUnavailable("PNG 编码失败")
        }
        return data as Data
    }
}
