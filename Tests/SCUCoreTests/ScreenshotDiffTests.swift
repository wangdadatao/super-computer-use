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

    @Test func mismatchedSizesAreNotComparable() {
        #expect(ScreenshotDiff.changedRatio(
            before: Self.png((1, 1, 1), width: 10, height: 10),
            after: Self.png((1, 1, 1), width: 20, height: 20)) == nil)
    }
}
