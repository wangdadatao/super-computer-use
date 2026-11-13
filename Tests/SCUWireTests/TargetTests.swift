import Foundation
import Testing

@testable import SCUWire

/// 窗口目标：ID 寻址，标题只作诊断线索。
@Suite struct TargetTests {
    @Test func forWindowKeepsIDAndDemotesTitleToHint() {
        let target = Target.forWindow(pid: 7, windowID: 0xAB, titleHint: "收件箱")
        #expect(target.windowID == 0xAB)
        #expect(target.windowTitle == nil)
        #expect(target.titleHint == "收件箱")
    }

    /// 没有 ID 可寻址时退回标题寻址，和旧的 `init(pid:windowTitle:)` 一样。
    @Test func forWindowWithoutIDFallsBackToTitleAddressing() {
        let target = Target.forWindow(pid: 7, windowID: nil, titleHint: "收件箱")
        #expect(target.windowID == nil)
        #expect(target.windowTitle == "收件箱")
        #expect(target.titleHint == nil)
    }

    /// 线索只留在本进程：不上线，避免对端把它当身份判定。
    @Test func titleHintIsNotWired() throws {
        let target = Target.forWindow(pid: 7, windowID: 0xAB, titleHint: "收件箱")
        let data = try JSONEncoder().encode(target)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("收件箱"))
        #expect(!text.contains("titleHint"))
        #expect(text.contains("\"windowID\":171"))
        let decoded = try JSONDecoder().decode(Target.self, from: data)
        #expect(decoded.windowTitle == nil)
        #expect(decoded.titleHint == nil)
    }
}
