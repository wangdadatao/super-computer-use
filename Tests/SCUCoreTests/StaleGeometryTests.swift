import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// `stale_geometry` 的 `details.reason`：逐项判据与优先级（T-019 第二批 §3.2、§3.6 U2）。
@Suite struct StaleGeometryTests {
    private static func shot(
        windowID: UInt32? = nil, title: String? = "主",
        frame: Rect = Rect(x: 0, y: 0, width: 80, height: 20),
        scale: Double = 1, width: Int = 80, height: Int = 20
    ) -> WindowCapture {
        WindowCapture(
            png: Data([0x89, 0x50]), width: width, height: height, scale: scale,
            windowFrame: frame, windowID: windowID, windowTitle: title)
    }

    private func setup() throws -> (DesktopSession, ScriptedReader, SessionState, String) {
        let r = ScriptedReader()
        r.tree = TreeReading(root: SessionTests.sampleTree(), truncated: false)
        let s = DesktopSession(reader: r, settle: SessionTests.Clock().settle)
        let a = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.capture = .success(Self.shot())
        let image = try s.captureScreenshot(token: a.token.value)
        return (s, r, a, image.id)
    }

    /// 断言 stale_geometry、retry 与 reason，并返回错误供继续断言 details。
    @discardableResult
    private func expectStale(
        _ reason: String, _ body: () throws -> Void
    ) -> WireError? {
        do {
            try body()
            Issue.record("应抛出 stale_geometry/\(reason)")
            return nil
        } catch let error as WireError {
            #expect(error.code == "stale_geometry")
            #expect(error.layer == "protocol")
            #expect(error.retry == "after_refresh")
            #expect(error.details?["reason"] == reason)
            return error
        } catch {
            Issue.record("意外的错误 \(error)")
            return nil
        }
    }

    @Test func unknownScreenshotIsCaptureUnknown() throws {
        let (s, r, a, _) = try setup()
        expectStale("capture_unknown") {
            _ = try s.clickAt(token: a.token.value, screenshotID: "nope", x: 10, y: 10)
        }
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func screenshotFromAnotherTokenIsCaptureTokenMismatch() throws {
        let (s, r, _, id) = try setup()
        let b = try s.readState(pid: 20, maxDepth: 12, budgetMs: 1000)
        expectStale("capture_token_mismatch") {
            _ = try s.clickAt(token: b.token.value, screenshotID: id, x: 10, y: 10)
        }
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func closedWindowBoundByIDIsWindowGone() throws {
        let (s, r, a, _) = try setup()
        r.capture = .success(Self.shot(windowID: 77))
        let image = try s.captureScreenshot(token: a.token.value)
        r.capture = .failure(.windowNotFound(pid: 10, windowID: 77))
        let error = expectStale("window_gone") {
            _ = try s.clickAt(token: a.token.value, screenshotID: image.id, x: 10, y: 10)
        }
        #expect(error?.details?["bound_by"] == "window_id")
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func closedWindowBoundByTitleIsWindowGone() throws {
        let (s, r, a, id) = try setup()
        r.capture = .failure(.windowNotFound(pid: 10, title: "主"))
        let error = expectStale("window_gone") {
            _ = try s.clickAt(token: a.token.value, screenshotID: id, x: 10, y: 10)
        }
        #expect(error?.details?["bound_by"] == "window_title")
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func changedWindowIDIsWindowReplacedEvenWithSameGeometry() throws {
        let (s, r, a, _) = try setup()
        r.capture = .success(Self.shot(windowID: 77))
        let image = try s.captureScreenshot(token: a.token.value)
        r.capture = .success(Self.shot(windowID: 88))
        let error = expectStale("window_replaced") {
            _ = try s.clickAt(token: a.token.value, screenshotID: image.id, x: 10, y: 10)
        }
        #expect(error?.details?["expected"] == "#77")
        #expect(error?.details?["actual"] == "#88")
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func movedFrameIsFrameChangedWithExpectedAndActual() throws {
        let (s, r, a, id) = try setup()
        r.capture = .success(Self.shot(frame: Rect(x: 20, y: 0, width: 80, height: 20)))
        let error = expectStale("frame_changed") {
            _ = try s.clickAt(token: a.token.value, screenshotID: id, x: 10, y: 10)
        }
        #expect(error?.details?["expected"] == "0,0,80,20")
        #expect(error?.details?["actual"] == "20,0,80,20")
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func changedScaleIsScaleChanged() throws {
        let (s, r, a, id) = try setup()
        r.capture = .success(Self.shot(scale: 2))
        let error = expectStale("scale_changed") {
            _ = try s.clickAt(token: a.token.value, screenshotID: id, x: 10, y: 10)
        }
        #expect(error?.details?["expected"] == "1.000")
        #expect(error?.details?["actual"] == "2.000")
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func changedImageSizeIsSizeChanged() throws {
        let (s, r, a, id) = try setup()
        r.capture = .success(Self.shot(width: 160))
        let error = expectStale("size_changed") {
            _ = try s.clickAt(token: a.token.value, screenshotID: id, x: 10, y: 10)
        }
        #expect(error?.details?["expected"] == "80×20")
        #expect(error?.details?["actual"] == "160×20")
        #expect(r.coordinateClicks.isEmpty)
    }

    /// 优先级：frame 与 scale 同时变，只报 frame_changed。
    @Test func frameOutranksScale() throws {
        let (s, r, a, id) = try setup()
        r.capture = .success(
            Self.shot(frame: Rect(x: 20, y: 0, width: 80, height: 20), scale: 2))
        expectStale("frame_changed") {
            _ = try s.clickAt(token: a.token.value, screenshotID: id, x: 10, y: 10)
        }
        #expect(r.coordinateClicks.isEmpty)
    }

    /// 非 window_not_found 的原生错误不被翻译成 window_gone。
    @Test func otherCaptureErrorsAreNotTranslated() throws {
        let (s, r, a, id) = try setup()
        r.capture = .failure(.unsupportedOperation("没有配置截图"))
        do {
            _ = try s.clickAt(token: a.token.value, screenshotID: id, x: 10, y: 10)
            Issue.record("应抛出 unsupported_operation")
        } catch let error as WireError {
            #expect(error.code == "unsupported_operation")
            #expect(error.details == nil)
        }
        #expect(r.coordinateClicks.isEmpty)
    }
}
