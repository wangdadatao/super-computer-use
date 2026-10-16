import Foundation
import Testing

@testable import SCUWire

@Suite struct FrameTests {
    @Test func requestRoundTrip() throws {
        let frame = RequestFrame(id: 7, request: .dumpTree(pid: 123, maxDepth: 4))
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
            children: [AXNode(role: "AXButton", identifier: "ok", enabled: true)])
        let frame = ResponseFrame(id: 1, response: .tree(tree))
        let data = try Frame.encode(frame)
        #expect(try Frame.decode(ResponseFrame.self, body: data.dropFirst(4)) == frame)
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

        let dump = try Self.json(RequestFrame(id: 2, request: .dumpTree(pid: 9, maxDepth: 3)))
        let d = dump["request"] as! [String: Any]
        #expect(d["type"] as? String == "dumpTree")
        #expect(d["pid"] as? Int == 9)
        #expect(d["maxDepth"] as? Int == 3)
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

    @Test func noSynthesizedAssociatedValueKeysLeak() throws {
        let all: [Response] = [
            .hello(protocolVersion: 1), .permissions(accessibility: false), .apps([]),
            .tree(AXNode(role: "AXWindow")), .failure(.internalError("x")),
        ]
        for r in all {
            let data = try JSONEncoder().encode(ResponseFrame(id: 1, response: r))
            #expect(!String(decoding: data, as: UTF8.self).contains("\"_0\""))
        }
    }

    @Test func unknownMessageTypeFailsToDecode() {
        let body = Data(#"{"id":1,"request":{"type":"nope"}}"#.utf8)
        #expect(throws: DecodingError.self) { try Frame.decode(RequestFrame.self, body: body) }
    }

    @Test func missingRequiredFieldFailsToDecode() {
        let body = Data(#"{"id":1,"request":{"type":"dumpTree","pid":1}}"#.utf8)
        #expect(throws: DecodingError.self) { try Frame.decode(RequestFrame.self, body: body) }
    }
}
