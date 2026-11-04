import CoreGraphics
import Testing

@testable import SCUNative

/// T-019：截图比例。三档比例对应三种窗口宽度：
/// 1.0（1600 点宽）、1.818（880 点宽的 1x 屏——黑边 bug 的现场）、2.0（800 点宽）。
@Suite struct CaptureGeometryTests {
    @Test(
        arguments: [
            (1600.0, 1000.0, 1.0),
            (880.0, 640.0, 1600.0 / 880.0),
            (800.0, 600.0, 2.0),
        ])
    func planRequestsTheFullWidthAtTheExpectedScale(width: Double, height: Double, scale: Double) {
        let geometry = CaptureGeometry.plan(frame: CGSize(width: width, height: height))
        #expect(geometry.width == 1600)
        #expect(abs(geometry.scale - scale) < 1e-9)
        #expect(geometry.height == Int((height * scale).rounded()))
        // 宽高比与窗口一致：`scalesToFit` 铺满时不会为了补差而留边。
        let planned = Double(geometry.width) / Double(geometry.height)
        #expect(abs(planned - width / height) < 0.002)
        // 上报比例必须等于请求比例（两者只差像素取整），落点换算才不会被缩放骗。
        let reported = CaptureGeometry.reportedScale(
            imageWidth: geometry.width, frameWidth: width)
        #expect(abs(reported - scale) < 1e-9)
    }

    /// 上报比例来自**实际图像**：图像比请求窄时必须跟着图像走，不能用请求值。
    @Test func reportedScaleFollowsTheActualImage() {
        #expect(abs(CaptureGeometry.reportedScale(imageWidth: 1440, frameWidth: 880) - 1.6363) < 0.001)
        #expect(CaptureGeometry.reportedScale(imageWidth: 1312, frameWidth: 656) == 2.0)
    }

    /// 小窗口不会被放大超过 2.0：它本来就只有那么点像素，放大只是把底噪变大。
    @Test func planDoesNotUpscaleBeyondTwo() {
        let small = CaptureGeometry.plan(frame: CGSize(width: 200, height: 100))
        #expect(small.scale == 2.0)
        #expect(small.width == 400)
        #expect(small.height == 200)
    }
}
