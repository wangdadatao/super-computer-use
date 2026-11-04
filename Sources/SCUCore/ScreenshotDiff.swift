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

    /// 落点所在行附近是否出现了**插入光标形态**的像素变化。
    ///
    /// 判据是一串可核对的形态事实，不是"点中了"的结论：只看落点上下 `lineTolerance` 点以内的行，
    /// 在其中找变化的连通区域，要求它窄（≤ `maxWidthPt` 点）而高（`minHeightPt`...`maxHeightPt` 点），
    /// 且纵向覆盖落点所在行。文本插入光标正好是这个形状；按钮高亮、悬停、窗口外观变化都远宽于它。
    ///
    /// 返回 nil 表示图像不能比较（解码失败或尺寸不一致）——**未知**，不是"没有光标"。
    public static func caretAppeared(
        before: Data, after: Data, at point: (x: Double, y: Double), scale: Double,
        lineTolerance: Double = 12, maxWidthPt: Double = 3, minHeightPt: Double = 6,
        maxHeightPt: Double = 60, threshold: UInt8 = 24
    ) -> Bool? {
        guard let a = rgba(before), let b = rgba(after),
            a.width == b.width, a.height == b.height, a.width > 0, a.height > 0
        else {
            return nil
        }
        let s = max(scale, 1)
        let rowMargin = Int((lineTolerance * s).rounded())
        let maxWidth = max(2, Int((maxWidthPt * s).rounded()))
        let minHeight = max(3, Int((minHeightPt * s).rounded()))
        let maxHeight = max(minHeight, Int((maxHeightPt * s).rounded()))
        let y0 = max(0, Int(point.y.rounded()) - rowMargin)
        let y1 = min(a.height - 1, Int(point.y.rounded()) + rowMargin)
        guard y0 <= y1 else { return nil }

        /// 变化行的掩码：每行记录变化的 x 区间。只关心 y0...y1 这一段。
        var mask = [Bool](repeating: false, count: (y1 - y0 + 1) * a.width)
        func changed(_ i: Int) -> Bool {
            let j = i * 4
            let dr = abs(Int(a.bytes[j]) - Int(b.bytes[j]))
            let dg = abs(Int(a.bytes[j + 1]) - Int(b.bytes[j + 1]))
            let db = abs(Int(a.bytes[j + 2]) - Int(b.bytes[j + 2]))
            return max(dr, max(dg, db)) > Int(threshold)
        }
        for y in y0...y1 {
            let row = (y - y0) * a.width
            for x in 0..<a.width where changed(y * a.width + x) {
                mask[row + x] = true
            }
        }

        // 连通区域（8 邻接）。只保留宽度上限内的候选，再检查高度与纵向覆盖落点。
        var seen = [Bool](repeating: false, count: mask.count)
        let width = a.width
        let height = y1 - y0 + 1
        for start in 0..<mask.count where mask[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minX = Int.max
            var maxX = Int.min
            var minY = Int.max
            var maxY = Int.min
            while let i = stack.popLast() {
                let x = i % width
                let y = i / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let ni = ny * width + nx
                        if mask[ni] && !seen[ni] {
                            seen[ni] = true
                            stack.append(ni)
                        }
                    }
                }
            }
            let w = maxX - minX + 1
            let h = maxY - minY + 1
            guard w <= maxWidth, h >= minHeight, h <= maxHeight else { continue }
            // 光标要离落点所在行够近。文本点击落点可能换算到相邻行的字符位置
            // （实测差 2 点），所以允许一个行距量级的纵向容差，而不是要求覆盖落点。
            let top = y0 + minY
            let bottom = y0 + maxY
            if Double(top) <= point.y + lineTolerance * s,
                Double(bottom) >= point.y - lineTolerance * s
            {
                return true
            }
        }
        return false
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
