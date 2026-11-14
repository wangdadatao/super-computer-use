import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// 同名窗口：读树入口、坐标入口与观测摘要（T-019 第二批 §2.3 U2/U3/U4）。
@Suite struct AmbiguousReferenceTests {
    private func ambiguous() -> WireError {
        WireError.ambiguousReference(
            title: "同名", count: 2,
            candidates: [
                .init(windowID: 171, frame: Rect(x: 0, y: 0, width: 80, height: 20)),
                .init(windowID: 172, frame: Rect(x: 100, y: 0, width: 80, height: 20)),
            ])
    }

    private static func twoSameTitleWindows() -> AXNode {
        let first = AXNode(
            role: "AXWindow", title: "同名", frame: Rect(x: 0, y: 0, width: 80, height: 20),
            childCount: 0)
        let second = AXNode(
            role: "AXWindow", title: "同名", frame: Rect(x: 100, y: 0, width: 80, height: 20),
            childCount: 0)
        return AXNode(role: "AXApplication", childCount: 2, children: [first, second])
    }

    private func session(_ r: ScriptedReader = ScriptedReader()) -> DesktopSession {
        DesktopSession(reader: r, settle: SessionTests.Clock().settle)
    }

    /// U2：读树入口收到歧义时原样上抛，不签发令牌、不覆盖当前令牌。
    @Test func readStatePropagatesAmbiguityWithoutIssuingAToken() throws {
        let r = ScriptedReader()
        r.script = [.failure(ambiguous())]
        let s = session(r)
        do {
            _ = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000, windowTitle: "同名")
            Issue.record("应抛出 ambiguous_reference")
        } catch let error as WireError {
            #expect(error.code == "ambiguous_reference")
            #expect(error.retry == "after_disambiguation")
        }
        #expect(s.currentToken == nil)
        #expect(s.records.isEmpty)
    }

    /// U3：坐标路径的标题解析歧义时拒绝，截图绑定不被静默换掉。
    @Test func coordinatePathRejectsAmbiguityAndKeepsTheBinding() throws {
        let r = ScriptedReader()
        r.tree = TreeReading(root: SessionTests.sampleTree(), truncated: false)
        let s = session(r)
        let a = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "同名"))
        let image = try s.captureScreenshot(token: a.token.value)
        r.capture = .failure(ambiguous())

        do {
            _ = try s.clickAt(token: a.token.value, screenshotID: image.id, x: 10, y: 10)
            Issue.record("应抛出 ambiguous_reference")
        } catch let error as WireError {
            #expect(error.code == "ambiguous_reference")
            #expect(error.retry == "after_disambiguation")
        }
        #expect(r.coordinateClicks.isEmpty)
        #expect(s.screenshotBindings[image.id] != nil)
    }

    /// U4：标题回退遇到两个同名窗口时摘要为 nil，不抛错。
    @Test func digestTitleFallbackIsNilWhenTheTitleIsAmbiguous() {
        let entries = ElementTable.flatten(Self.twoSameTitleWindows())
        let binding = DesktopSession.ScreenshotBinding(
            token: "t", windowID: nil, windowTitle: "同名",
            windowFrame: Rect(x: 200, y: 0, width: 80, height: 20), scale: 1,
            width: 80, height: 20, png: Data())
        #expect(DesktopSession.windowScopedDigest(entries, binding: binding) == nil)
    }

    /// 只有一个同名窗口时，标题回退仍然可用。
    @Test func digestTitleFallbackWorksForOneWindow() {
        let root = AXNode(
            role: "AXApplication", childCount: 1,
            children: [
                AXNode(
                    role: "AXWindow", title: "同名",
                    frame: Rect(x: 0, y: 0, width: 80, height: 20), childCount: 0)
            ])
        let entries = ElementTable.flatten(root)
        let binding = DesktopSession.ScreenshotBinding(
            token: "t", windowID: nil, windowTitle: "同名",
            windowFrame: Rect(x: 200, y: 0, width: 80, height: 20), scale: 1,
            width: 80, height: 20, png: Data())
        #expect(DesktopSession.windowScopedDigest(entries, binding: binding) != nil)
    }

    /// U4：动作已投递，摘要歧义只让 treeChanged 变 unknown，不抛错、不算空操作。
    @Test func ambiguousDigestLeavesTreeChangeUnknownWithoutThrowing() throws {
        let r = ScriptedReader()
        r.tree = TreeReading(root: Self.twoSameTitleWindows(), truncated: false)
        let s = session(r)
        let a = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 200, y: 0, width: 80, height: 20), windowTitle: "同名"))
        let image = try s.captureScreenshot(token: a.token.value)

        let report = try s.clickAt(token: a.token.value, screenshotID: image.id, x: 10, y: 10)
        #expect(report.delivered)
        #expect(report.treeChanged == nil)
        #expect(report.noOpSuspected == false)
        #expect(r.coordinateClicks.count == 1)
    }
}
