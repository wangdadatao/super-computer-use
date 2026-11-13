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

    /// ID 与标题同时给：两种身份判定，拒绝，不让 ID 静默胜出。
    @Test func conflictingWindowTargetIsRejected() {
        let target = Target(pid: 7, windowID: 12, windowTitle: "收件箱")
        let error = #expect(throws: WireError.self) { try AXBackend.validateTarget(target) }
        #expect(error?.code == "conflicting_target")
        #expect(error?.retry == "no")
    }

    /// 合法的三种写法各自过关：只有 ID、只有标题、ID + 线索。
    @Test func nonConflictingWindowTargetsPass() throws {
        try AXBackend.validateTarget(Target(pid: 7, windowID: 12))
        try AXBackend.validateTarget(Target(pid: 7, windowTitle: "收件箱"))
        try AXBackend.validateTarget(Target.forWindow(pid: 7, windowID: 12, titleHint: "收件箱"))
    }
}
