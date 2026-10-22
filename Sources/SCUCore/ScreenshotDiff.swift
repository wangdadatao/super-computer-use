import CoreGraphics
import Foundation
import ImageIO

/// 两张窗口截图的像素差异。只做全图比例，不做区域定位：
/// 输出用于判断"树没变时，画面有没有变"，不声称具体改了什么。
public enum ScreenshotDiff {
    /// 返回发生变化像素的比例（0...1）。图像无法解码或尺寸不一致时返回 nil。
    public static func changedRatio(before: Data, after: Data, threshold: UInt8 = 12) -> Double? {
        guard let a = rgba(before), let b = rgba(after),
            a.width == b.width, a.height == b.height, a.width > 0, a.height > 0
        else {
            return nil
        }
        let count = a.width * a.height
        var changed = 0
        for i in 0..<count {
            let j = i * 4
            let dr = abs(Int(a.bytes[j]) - Int(b.bytes[j]))
            let dg = abs(Int(a.bytes[j + 1]) - Int(b.bytes[j + 1]))
            let db = abs(Int(a.bytes[j + 2]) - Int(b.bytes[j + 2]))
            if max(dr, max(dg, db)) > Int(threshold) { changed += 1 }
        }
        return Double(changed) / Double(count)
    }

    struct RGBA {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    static func rgba(_ data: Data) -> RGBA? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBA(width: width, height: height, bytes: bytes)
    }
}
