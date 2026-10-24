import Testing

@testable import SCUNative
@testable import SCUWire

/// 多窗口选择：截图与激活共用同一个“面积最大”的窗口规则。
@Suite struct WindowTests {
    @Test func largestIndexPicksTheLargestArea() {
        let frames: [Rect?] = [
            Rect(x: 0, y: 0, width: 100, height: 100),
            Rect(x: 0, y: 0, width: 300, height: 300),
            Rect(x: 0, y: 0, width: 200, height: 500),
        ]
        #expect(WindowActivation.largestIndex(frames) == 2)
    }

    @Test func largestIndexKeepsTheFirstOnTies() {
        let frames: [Rect?] = [
            Rect(x: 0, y: 0, width: 200, height: 200),
            Rect(x: 10, y: 10, width: 200, height: 200),
        ]
        #expect(WindowActivation.largestIndex(frames) == 0)
    }

    @Test func windowIDMatchingPrefersFrameAndTitle() {
        let candidates: [AXBackend.CGWindowEntry] = [
            AXBackend.CGWindowEntry(
                windowID: 1, title: "同名",
                frame: Rect(x: 0, y: 0, width: 100, height: 100)),
            AXBackend.CGWindowEntry(
                windowID: 2, title: "同名",
                frame: Rect(x: 200, y: 0, width: 100, height: 100)),
        ]
        #expect(
            AXBackend.matchWindowID(
                title: "同名", frame: Rect(x: 201, y: 1, width: 100, height: 100),
                candidates: candidates) == 2)
        #expect(
            AXBackend.matchWindowID(
                title: "同名", frame: Rect(x: 400, y: 0, width: 100, height: 100),
                candidates: candidates) == nil)
    }

    @Test func windowIDMatchingRefusesAmbiguousCandidates() {
        let candidates: [AXBackend.CGWindowEntry] = [
            AXBackend.CGWindowEntry(
                windowID: 1, title: "同名",
                frame: Rect(x: 0, y: 0, width: 100, height: 100)),
            AXBackend.CGWindowEntry(
                windowID: 2, title: "同名",
                frame: Rect(x: 0, y: 0, width: 100, height: 100)),
        ]
        #expect(
            AXBackend.matchWindowID(
                title: "同名", frame: Rect(x: 0, y: 0, width: 100, height: 100),
                candidates: candidates) == nil)
    }

    @Test func largestIndexTreatsMissingFramesAsZeroAndFallsBackToFirst() {
        #expect(WindowActivation.largestIndex([]) == nil)
        #expect(WindowActivation.largestIndex([nil, nil]) == 0)
        #expect(
            WindowActivation.largestIndex([
                nil,
                Rect(x: 0, y: 0, width: 1, height: 1),
            ]) == 1)
    }
}
