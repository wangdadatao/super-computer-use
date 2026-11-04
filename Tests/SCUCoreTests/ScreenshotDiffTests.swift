import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SCUCore

@Suite struct ScreenshotDiffTests {
    static func png(_ color: (CGFloat, CGFloat, CGFloat), width: Int = 20, height: Int = 20) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func identicalImagesHaveNoChange() {
        let image = Self.png((1, 1, 1))
        #expect(ScreenshotDiff.changedRatio(before: image, after: image) == 0)
    }

    @Test func differentImagesHaveFullChange() {
        let ratio = ScreenshotDiff.changedRatio(
            before: Self.png((1, 1, 1)), after: Self.png((0, 0, 0)))
        #expect(ratio == 1)
    }

    /// 白底图；`caret` 给 (x, top, bottom) 时画一条 1 像素宽的竖线（图像左上角为原点）。
    static func withCaret(
        _ caret: (x: Int, top: Int, bottom: Int, width: Int)?, width: Int = 120, height: Int = 40
    ) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        if let caret {
            context.fill(
                CGRect(
                    x: caret.x, y: height - caret.bottom, width: caret.width,
                    height: caret.bottom - caret.top))
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func narrowVerticalChangeOnTheClickedLineIsACaretCandidate() {
        let before = Self.withCaret(nil)
        let after = Self.withCaret((x: 60, top: 10, bottom: 28, width: 1))
        #expect(
            ScreenshotDiff.caretAppeared(before: before, after: after, at: (x: 60, y: 20), scale: 1)
                == true)
        // 2 倍缩放：2 像素宽、36 像素高。
        let wide = Self.withCaret((x: 120, top: 20, bottom: 56, width: 2), width: 240, height: 80)
        #expect(
            ScreenshotDiff.caretAppeared(
                before: Self.withCaret(nil, width: 240, height: 80), after: wide,
                at: (x: 120, y: 40), scale: 2) == true)
    }

    @Test func caretOnTheNeighbouringLineIsStillACaretCandidate() {
        // 实测：点在第 3 行，TextEdit 把插入点放到第 3 行行首，光标底部比落点高 2 点。
        let before = Self.withCaret(nil)
        let after = Self.withCaret((x: 60, top: 8, bottom: 22, width: 1))
        #expect(
            ScreenshotDiff.caretAppeared(before: before, after: after, at: (x: 60, y: 24), scale: 1)
                == true)
    }

    @Test func wideOrShortChangesAreNotCarets() {
        let before = Self.withCaret(nil)
        // 宽块：按钮高亮/悬停的形态。
        let block = Self.withCaret((x: 40, top: 10, bottom: 30, width: 40))
        #expect(
            ScreenshotDiff.caretAppeared(before: before, after: block, at: (x: 60, y: 20), scale: 1)
                == false)
        // 太短：不是一根光标。
        let dot = Self.withCaret((x: 60, top: 18, bottom: 21, width: 1))
        #expect(
            ScreenshotDiff.caretAppeared(before: before, after: dot, at: (x: 60, y: 20), scale: 1)
                == false)
        // 不在落点所在行：另一行的变化不算。
        let elsewhere = Self.withCaret((x: 60, top: 33, bottom: 38, width: 1))
        #expect(
            ScreenshotDiff.caretAppeared(before: before, after: elsewhere, at: (x: 60, y: 2), scale: 1)
                == false)
    }

    @Test func mismatchSizesAreNotComparableForCaret() {
        #expect(
            ScreenshotDiff.caretAppeared(
                before: Self.withCaret(nil, width: 120, height: 40),
                after: Self.withCaret(nil, width: 100, height: 40),
                at: (x: 50, y: 20), scale: 1) == nil)
    }

    @Test func mismatchedSizesAreNotComparable() {
        #expect(
            ScreenshotDiff.changedRatio(
                before: Self.png((1, 1, 1), width: 10, height: 10),
                after: Self.png((1, 1, 1), width: 20, height: 20)) == nil)
    }
}
