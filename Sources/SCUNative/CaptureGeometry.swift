import CoreGraphics

/// 截图的尺寸规划与比例上报（T-019）。
///
/// `SCStreamConfiguration` 只接受像素尺寸，且 `scalesToFit = false` 时**只缩不放**：
/// 请求 1600 像素宽、而窗口只有 880 点时，内容是 1:1 画进缓冲区的，右侧留黑；
/// 这时 `image.width / frame.width = 1.818` 并不是内容的真实比例，按它换算落点会只走到
/// 预期的 55%。这里把“请求多大”收敛成纯函数，比例则一律按**实际图像尺寸**上报。
struct CaptureGeometry: Equatable, Sendable {
    /// 请求的缓冲区宽高（像素）。
    var width: Int
    var height: Int
    /// 请求比例（图像像素 / 窗口点）；实际比例以 `reportedScale` 为准。
    var scale: Double

    /// 上限 1600 像素宽：足够读文字，也不会让 MCP 单帧过大。
    static let maxPixelWidth = 1600.0
    static let minScale = 0.5
    static let maxScale = 2.0

    /// 由窗口 frame 规划请求尺寸。宽高用**同一个**取整后的比例算，保持原始宽高比，
    /// 避免 `scalesToFit` 为了补足 1 像素的差异而留边。
    static func plan(frame: CGSize) -> CaptureGeometry {
        let frameWidth = max(1.0, frame.width)
        let frameHeight = max(1.0, frame.height)
        let scale = min(maxScale, max(minScale, maxPixelWidth / frameWidth))
        let width = max(1, Int((frameWidth * scale).rounded()))
        let actualScale = Double(width) / frameWidth
        let height = max(1, Int((frameHeight * actualScale).rounded()))
        return CaptureGeometry(width: width, height: height, scale: actualScale)
    }

    /// 上报给协议层的比例：必须由**实际图像**与窗口 frame 得出，不能用请求值。
    static func reportedScale(imageWidth: Int, frameWidth: Double) -> Double {
        Double(imageWidth) / max(1.0, frameWidth)
    }
}
