import Foundation
import Testing

@testable import SCUWire

/// `WireError.details` 的线格式与协议版本（T-019 第二批 §3.4、§3.6 U1/U4）。
@Suite struct WireErrorDetailsTests {
    @Test func legacyErrorEncodesExactlyFourKeys() throws {
        let error = WireError.windowNotFound(pid: 7, title: "收件箱")
        let data = try JSONEncoder().encode(error)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Set(object.keys) == ["code", "layer", "retry", "message"])
        #expect(error.details == nil)
    }

    @Test func detailsRoundTrip() throws {
        let error = WireError.staleGeometry(
            "窗口变了", reason: "frame_changed", expected: "0,0,800,600", actual: "20,0,800,600")
        let back = try JSONDecoder().decode(WireError.self, from: JSONEncoder().encode(error))
        #expect(back == error)
        #expect(back.details?["reason"] == "frame_changed")
        #expect(back.details?["expected"] == "0,0,800,600")
        #expect(back.details?["actual"] == "20,0,800,600")
    }

    @Test func protocolVersionIsFourteen() {
        // 13 → 14：`failure.error` 新增可选 `details`。两侧必须成对替换。
        #expect(scuNativeProtocolVersion == 14)
    }

    @Test func ambiguousReferenceCarriesReasonAndCount() {
        let error = WireError.ambiguousReference(
            title: "未命名", count: 2,
            candidates: [
                .init(windowID: 171, frame: Rect(x: 0, y: 0, width: 800, height: 600)),
                .init(windowID: 172, frame: Rect(x: 900, y: 0, width: 800, height: 600)),
            ])
        #expect(error.code == "ambiguous_reference")
        #expect(error.layer == "protocol")
        #expect(error.retry == "after_disambiguation")
        #expect(error.details?["reason"] == "title_ambiguous")
        #expect(error.details?["candidate_count"] == "2")
        #expect(error.message.contains("#171 (0,0,800,600)"))
        #expect(error.message.contains("#172 (900,0,800,600)"))
        #expect(error.message.contains("window_id"))
    }

    @Test func ambiguousReferenceWithoutCandidatesStillNamesTheCount() {
        let error = WireError.ambiguousReference(title: "未命名", count: 3, candidates: [])
        #expect(error.message.contains("匹配 3 个窗口"))
        #expect(error.message.contains("读不到它们的窗口号与位置"))
        #expect(error.details?["candidate_count"] == "3")
    }

    @Test func focusNotEstablishedSaysZeroKeys() {
        let error = WireError.focusNotEstablished(
            reason: "focused_element_elsewhere", observedRole: "AXSheet", appActive: false,
            message: "目标窗口已被抬到前台并尝试聚焦，但焦点没有落到目标元素。未发送任何按键。")
        #expect(error.code == "focus_not_established")
        #expect(error.layer == "platform")
        #expect(error.retry == "after_user_action")
        #expect(error.details?["reason"] == "focused_element_elsewhere")
        #expect(error.details?["observed_role"] == "AXSheet")
        #expect(error.details?["app_active"] == "false")
        #expect(error.details?["keys_posted"] == "0")
    }

    @Test func detailsTextPutsReasonFirst() {
        let error = WireError.staleGeometry(
            "窗口变了", reason: "frame_changed", expected: "0,0,800,600", actual: "20,0,800,600",
            boundBy: "window_id")
        #expect(
            error.detailsText
                == "reason=frame_changed actual=20,0,800,600 bound_by=window_id expected=0,0,800,600")
        #expect(WireError.windowNotFound(pid: 1, title: "x").detailsText == nil)
    }
}
