import Foundation
import Testing

@testable import SCUWire

@Suite struct FrameTests {
    @Test func requestRoundTrip() throws {
        let frame = RequestFrame(id: 7, request: .dumpTree(pid: 123, maxDepth: 4, budgetMs: 5000))
        let data = try Frame.encode(frame)
        // 前 4 字节是大端长度
        let len = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        #expect(len == data.count - 4)
        let back = try Frame.decode(RequestFrame.self, body: data.dropFirst(4))
        #expect(back == frame)
    }

    @Test func responseWithTreeRoundTrip() throws {
        let tree = AXNode(
            role: "AXWindow", title: "t",
            children: [AXNode(role: "AXButton", identifier: "ok", description: "确定", enabled: true,
                                actions: ["AXPress"])])
        let frame = ResponseFrame(id: 1, response: .tree(tree, truncated: true))
        let data = try Frame.encode(frame)
        #expect(try Frame.decode(ResponseFrame.self, body: data.dropFirst(4)) == frame)
    }

    @Test func windowCaptureRequestAndResponseRoundTrip() throws {
        let requestFrame = try WireFormatTests.json(RequestFrame(id: 8, request: .captureWindow(pid: 42)))
        let request = requestFrame["request"] as! [String: Any]
        #expect(request["type"] as? String == "captureWindow")
        #expect(request["pid"] as? Int == 42)

        let capture = WindowCapture(
            png: Data([0x89, 0x50, 0x4E, 0x47]), width: 1600, height: 1138, scale: 1.514,
            windowFrame: Rect(x: -1769, y: 36, width: 1057, height: 752), windowTitle: "窗口")
        let frame = ResponseFrame(id: 8, response: .windowCapture(capture))
        let data = try Frame.encode(frame)
        let back = try Frame.decode(ResponseFrame.self, body: data.dropFirst(4))
        #expect(back == frame)
    }

    @Test func failureCarriesStructuredError() throws {
        let err = WireError.versionMismatch(client: 2, server: 1)
        let data = try Frame.encode(ResponseFrame(id: 1, response: .failure(err)))
        let back = try Frame.decode(ResponseFrame.self, body: data.dropFirst(4))
        guard case .failure(let e) = back.response else { Issue.record("应为 failure"); return }
        #expect(e.code == "protocol_version_mismatch")
        #expect(e.layer == "boundary")
        #expect(e.retry == "no")
    }

    @Test func socketCarriesFramesBothWays() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        try Frame.write(RequestFrame(id: 3, request: .listApps), to: fds[0])
        let got = try Frame.read(RequestFrame.self, from: fds[1])
        #expect(got == RequestFrame(id: 3, request: .listApps))
    }

    @Test func peerCloseIsReportedAsClosed() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        close(fds[0])
        defer { close(fds[1]) }
        #expect(throws: TransportError.closed) {
            try Frame.read(RequestFrame.self, from: fds[1])
        }
    }

    /// 回归：对端关闭后写入不得让进程死于 SIGPIPE（曾经退出码 141）。
    /// 若此测试失败，表现为整个测试进程被信号杀死，而不是断言失败。
    @Test func writeAfterPeerCloseThrowsInsteadOfKillingProcess() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        UnixSocket.suppressSigPipe(fds[0])
        close(fds[1])
        defer { close(fds[0]) }
        #expect(throws: TransportError.closed) {
            try Frame.write(RequestFrame(id: 1, request: .listApps), to: fds[0])
        }
    }

    @Test func waitReadableTimesOutWhenPeerIsSilent() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(throws: TransportError.timeout) { try UnixSocket.waitReadable(fds[0], timeoutMs: 50) }
    }

    @Test func oversizedHeaderIsRejectedWithoutAllocating() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        try Frame.writeAll(fds[0], Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: TransportError.frameTooLarge(Int(UInt32.max))) {
            try Frame.read(RequestFrame.self, from: fds[1])
        }
    }
}

/// 线上格式是显式定义的契约（native_wire_protocol.md）。这些断言固定了字节级形状，
/// 防止重构静默改变它——曾经的合成编码会产生 `{"_0":…}`。
@Suite struct WireFormatTests {
    static func json(_ v: some Encodable) throws -> [String: Any] {
        let enc = JSONEncoder()
        let data = try enc.encode(v)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func requestShapeIsFlatWithTypeDiscriminator() throws {
        let hello = try Self.json(RequestFrame(id: 1, request: .hello(protocolVersion: 1)))
        let req = hello["request"] as! [String: Any]
        #expect(hello["id"] as? Int == 1)
        #expect(req["type"] as? String == "hello")
        #expect(req["protocolVersion"] as? Int == 1)

        let dump = try Self.json(RequestFrame(id: 2, request: .dumpTree(pid: 9, maxDepth: 3, budgetMs: 700)))
        let d = dump["request"] as! [String: Any]
        #expect(d["type"] as? String == "dumpTree")
        #expect(d["pid"] as? Int == 9)
        #expect(d["maxDepth"] as? Int == 3)
        #expect(d["budgetMs"] as? Int == 700)
    }

    @Test func responseShapeIsFlatWithTypeDiscriminator() throws {
        let fail = try Self.json(
            ResponseFrame(id: 1, response: .failure(.internalError("x"))))
        let r = fail["response"] as! [String: Any]
        #expect(r["type"] as? String == "failure")
        let e = r["error"] as! [String: Any]
        #expect(e["code"] as? String == "internal_error")
        #expect(Set(e.keys) == ["code", "layer", "retry", "message"])

        let perm = try Self.json(ResponseFrame(id: 2, response: .permissions(accessibility: true)))
        let p = perm["response"] as! [String: Any]
        #expect(p["type"] as? String == "permissions")
        #expect(p["accessibility"] as? Bool == true)
    }

    @Test func treeResponseCarriesTruncatedFlag() throws {
        let t = try Self.json(ResponseFrame(id: 1, response: .tree(AXNode(role: "AXWindow", description: "d"), truncated: true)))
        let r = t["response"] as! [String: Any]
        #expect(r["type"] as? String == "tree")
        #expect(r["truncated"] as? Bool == true)
        #expect((r["tree"] as! [String: Any])["description"] as? String == "d")
    }

    @Test func noSynthesizedAssociatedValueKeysLeak() throws {
        let all: [Response] = [
            .hello(protocolVersion: 1), .permissions(accessibility: false), .apps([]),
            .tree(AXNode(role: "AXWindow"), truncated: false), .failure(.internalError("x")),
            .acted, .located, .stale(StaleDetail(reason: .target, actual: TargetKey(role: "AXButton"))),
        ]
        for r in all {
            let data = try JSONEncoder().encode(ResponseFrame(id: 1, response: r))
            #expect(!String(decoding: data, as: UTF8.self).contains("\"_0\""))
        }
    }

    static let locator = ElementLocator(
        path: [PathStep(index: 2, siblings: 5, role: "AXWindow"), PathStep(index: 0, siblings: 1, role: "AXButton")],
        target: TargetKey(role: "AXButton", title: "好"))

    @Test func performActionShape() throws {
        let f = try Self.json(
            RequestFrame(id: 3, request: .performAction(pid: 7, locator: Self.locator, action: .press)))
        let r = f["request"] as! [String: Any]
        #expect(r["type"] as? String == "performAction")
        #expect(r["pid"] as? Int == 7)
        #expect(r["action"] as? String == "press")
        let l = r["locator"] as! [String: Any]
        let path = l["path"] as! [[String: Any]]
        #expect(path.count == 2)
        #expect(Set(path[0].keys) == ["index", "siblings", "role"])
        #expect(path[0]["siblings"] as? Int == 5)
        #expect((l["target"] as! [String: Any])["title"] as? String == "好")
    }

    @Test func inputRequestShapes() throws {
        let typed = try Self.json(
            RequestFrame(id: 4, request: .typeText(pid: 7, locator: Self.locator, text: "hello")))
        let t = typed["request"] as! [String: Any]
        #expect(t["type"] as? String == "typeText")
        #expect(t["pid"] as? Int == 7)
        #expect(t["text"] as? String == "hello")

        let pressed = try Self.json(
            RequestFrame(id: 5, request: .pressKey(pid: 7, locator: Self.locator, key: "cmd+t")))
        let p = pressed["request"] as! [String: Any]
        #expect(p["type"] as? String == "pressKey")
        #expect(p["key"] as? String == "cmd+t")

        let written = try Self.json(
            RequestFrame(id: 6, request: .setValue(pid: 7, locator: Self.locator, value: "名称")))
        let w = written["request"] as! [String: Any]
        #expect(w["type"] as? String == "setValue")
        #expect(w["value"] as? String == "名称")

        for request in [
            Request.typeText(pid: 7, locator: Self.locator, text: "多行\n文本"),
            Request.pressKey(pid: 7, locator: Self.locator, key: "shift+tab"),
            Request.setValue(pid: 7, locator: Self.locator, value: ""),
        ] {
            let body = try JSONEncoder().encode(RequestFrame(id: 1, request: request))
            #expect(try Frame.decode(RequestFrame.self, body: body).request == request)
        }
    }

    @Test func actionResponsesShapeAndRoundTrip() throws {
        let stale = StaleDetail(reason: .childCount, step: 1, actualCount: 4)
        let cases: [Response] = [.acted, .located, .stale(stale)]
        for c in cases {
            let body = try JSONEncoder().encode(ResponseFrame(id: 1, response: c))
            #expect(try Frame.decode(ResponseFrame.self, body: body).response == c)
        }
        let j = try Self.json(ResponseFrame(id: 1, response: .stale(stale)))
        let r = j["response"] as! [String: Any]
        #expect(r["type"] as? String == "stale")
        let d = r["stale"] as! [String: Any]
        #expect(d["reason"] as? String == "childCount")
        #expect(d["step"] as? Int == 1)
        #expect(d["actualCount"] as? Int == 4)
        let acted = try Self.json(ResponseFrame(id: 1, response: .acted))["response"] as! [String: Any]
        #expect(acted["type"] as? String == "acted")
    }

    @Test func childCountIsOptionalOnTheWire() throws {
        let withCount = try Self.json(AXNode(role: "AXList", childCount: 12))
        #expect(withCount["childCount"] as? Int == 12)
        // 旧形状（没有该字段）仍可解码为 nil：深度上限处的节点就是这样。
        let node = try JSONDecoder().decode(AXNode.self, from: Data(#"{"role":"AXList","children":[]}"#.utf8))
        #expect(node.childCount == nil)
    }

    @Test func unknownActionKindFailsToDecode() {
        let body = Data(
            #"{"id":1,"request":{"type":"performAction","pid":1,"action":"explode","locator":{"path":[],"target":{"role":"AXApplication"}}}}"#
                .utf8)
        #expect(throws: DecodingError.self) { try Frame.decode(RequestFrame.self, body: body) }
    }

    @Test func unknownMessageTypeFailsToDecode() {
        let body = Data(#"{"id":1,"request":{"type":"nope"}}"#.utf8)
        #expect(throws: DecodingError.self) { try Frame.decode(RequestFrame.self, body: body) }
    }

    @Test func missingRequiredFieldFailsToDecode() {
        let body = Data(#"{"id":1,"request":{"type":"dumpTree","pid":1,"maxDepth":3}}"#.utf8)
        #expect(throws: DecodingError.self) { try Frame.decode(RequestFrame.self, body: body) }
    }
}
