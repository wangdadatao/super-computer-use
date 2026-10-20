import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SCUCore
import SCUWire

/// 把快照标签画到窗口截图上。图像是辅助，文本元素表才是权威：
/// 徽标太小、重叠或被裁掉时，模型仍应按 `get_ax_state` 的标签选择。
///
/// 用 CoreGraphics + CoreText 而不是 NSImage：`scu mcp` 是纯命令行进程，
/// NSImage 的 TIFF 中转在无 GUI 会话里会失败（CGImageDestinationFinalize）。
enum ScreenshotOverlay {
    static func render(capture: WindowCapture, labels: [ElementTable.Label]) -> Data? {
        guard let source = CGImageSourceCreateWithData(capture.png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let imageSize = CGSize(width: width, height: height)
        for label in labels {
            drawBadge(label.text, frame: label.frame, capture: capture, imageSize: imageSize, in: context)
        }

        guard let output = context.makeImage() else { return nil }
        return encodePNG(output)
    }

    /// 全局屏幕点 → 窗口截图内的像素矩形（左上角原点）。
    static func imageRect(_ frame: Rect, windowFrame: Rect, scale: Double) -> CGRect {
        CGRect(
            x: (frame.x - windowFrame.x) * scale,
            y: (frame.y - windowFrame.y) * scale,
            width: frame.width * scale,
            height: frame.height * scale)
    }

    static func drawBadge(
        _ text: String, frame: Rect, capture: WindowCapture, imageSize: CGSize, in context: CGContext
    ) {
        let rect = imageRect(frame, windowFrame: capture.windowFrame, scale: capture.scale)
        guard rect.width > 0, rect.height > 0,
            rect.maxX > 0, rect.maxY > 0,
            rect.minX < imageSize.width, rect.minY < imageSize.height
        else {
            return
        }

        let fontSize = max(10, 11 * capture.scale)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padding: CGFloat = 2
        let badgeWidth = textWidth + padding * 2
        let badgeHeight = ascent + descent + padding * 2
        let x = max(0, rect.minX)
        let top = max(0, rect.minY)
        // CoreGraphics 的位图上下文原点在左下角；imageRect 用左上角。
        let y = imageSize.height - top - badgeHeight
        let badge = CGRect(x: x, y: y, width: badgeWidth, height: badgeHeight)
        guard badge.minY >= 0, badge.maxX <= imageSize.width, badge.maxY <= imageSize.height else { return }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: badge.minX + padding, y: badge.minY + padding + descent)
        CTLineDraw(line, context)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }
}
