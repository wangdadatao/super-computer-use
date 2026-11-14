import Testing

@testable import SCUMCP
@testable import SCUWire

/// 错误文本：第一行不变，`details` 单独一行（T-019 第二批 §3.5、§3.6 U3）。
@Suite struct ErrorTextTests {
    private func ambiguous() -> WireError {
        WireError.ambiguousReference(
            title: "同名", count: 2,
            candidates: [
                .init(windowID: 171, frame: Rect(x: 0, y: 0, width: 800, height: 600)),
                .init(windowID: 172, frame: Rect(x: 900, y: 0, width: 800, height: 600)),
            ])
    }

    @Test func ambiguousReferenceNamesRetryAndDetails() {
        let text = ScuTool.describe(ambiguous())
        #expect(text.hasPrefix("[ambiguous_reference]"))
        #expect(text.contains("retry=after_disambiguation"))
        #expect(text.contains("details: reason=title_ambiguous candidate_count=2"))
        #expect(text.contains("window_id"))
    }

    @Test func staleGeometryDetailsAreRenderedInAFixedOrder() {
        let error = WireError.staleGeometry(
            "截图后窗口位置/尺寸已变化，请重新 get_screenshot。", reason: "frame_changed",
            expected: "0,0,800,600", actual: "20,0,800,600")
        let text = ScuTool.describe(error)
        #expect(text.hasPrefix("[stale_geometry]"))
        #expect(text.contains("retry=after_refresh"))
        #expect(
            text.contains(
                "details: reason=frame_changed actual=20,0,800,600 expected=0,0,800,600"))
    }

    @Test func errorsWithoutDetailsKeepTheOldText() {
        let text = ScuTool.describe(WireError.windowNotFound(pid: 7, title: "收件箱"))
        #expect(text.contains("details:") == false)
        #expect(text.hasPrefix("[window_not_found]"))
    }
}
