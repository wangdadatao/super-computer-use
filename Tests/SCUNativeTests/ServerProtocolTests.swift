import Foundation
import Testing

@testable import SCUNative
@testable import SCUWire

/// 在进程内运行 NativeServer，用裸 socket 驱动它，覆盖否定路径：
/// 握手前请求、超长帧、半帧、畸形 JSON、越界参数、无人连接。
@Suite struct ServerProtocolTests {
    final class Outcome: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _error: Error?
        var error: Error? {
            get { lock.lock(); defer { lock.unlock() }; return _error }
            set { lock.lock(); defer { lock.unlock() }; _error = newValue }
        }
    }

    struct Running {
        let fd: Int32
        let outcome: Outcome
        let dir: URL
        func finish() {
            close(fd)
            try? FileManager.default.removeItem(at: dir)
        }
        /// 服务端在限定时间内退出（不挂起）。
        func exited(within seconds: Double = 5) -> Bool {
            outcome.done.wait(timeout: .now() + seconds) == .success
        }
    }

    static func startServer(acceptTimeoutMs: Int32 = 10_000) throws -> Running {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scut-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("n.sock").path
        let server = NativeServer(socketPath: path, acceptTimeoutMs: acceptTimeoutMs)
        let outcome = Outcome()
        Thread.detachNewThread {
            do { try server.run() } catch { outcome.error = error }
            outcome.done.signal()
        }
        var fd: Int32?
        for _ in 0..<100 {
            if let c = try? UnixSocket.connect(to: path) { fd = c; break }
            usleep(20_000)
        }
        guard let fd else { throw TransportError.timeout }
        return Running(fd: fd, outcome: outcome, dir: dir)
    }

    static func handshake(_ r: Running) throws {
        try Frame.write(RequestFrame(id: 1, request: .hello(protocolVersion: scuNativeProtocolVersion)), to: r.fd)
        let reply = try Frame.read(ResponseFrame.self, from: r.fd)
        #expect(reply.response == .hello(protocolVersion: scuNativeProtocolVersion))
    }

    static func expectFailure(_ r: Running, code: String) throws {
        let reply = try Frame.read(ResponseFrame.self, from: r.fd)
        guard case .failure(let e) = reply.response else {
            Issue.record("应为 failure，实际 \(reply.response)")
            return
        }
        #expect(e.code == code)
    }

    @Test func requestBeforeHandshakeIsRejectedAndConnectionClosed() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Frame.write(RequestFrame(id: 1, request: .checkPermissions), to: r.fd)
        try Self.expectFailure(r, code: "internal_error")
        #expect(r.exited())
        #expect(throws: TransportError.closed) { try Frame.read(ResponseFrame.self, from: r.fd) }
    }

    @Test func oversizedFrameIsRejectedAndConnectionClosed() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Self.handshake(r)
        try Frame.writeAll(r.fd, Data([0xFF, 0xFF, 0xFF, 0xFF]))
        try Self.expectFailure(r, code: "internal_error")
        #expect(r.exited())
    }

    @Test func partialFrameThenCloseEndsServerCleanly() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Self.handshake(r)
        // 声明 100 字节主体，只发 10 字节，然后关闭。
        try Frame.writeAll(r.fd, Data([0, 0, 0, 100]) + Data(repeating: 0x7B, count: 10))
        shutdown(r.fd, SHUT_WR)
        #expect(r.exited())
        #expect(r.outcome.error == nil)
    }

    @Test func malformedJSONIsRejected() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Self.handshake(r)
        let junk = Data("not json".utf8)
        try Frame.writeAll(r.fd, Data([0, 0, 0, UInt8(junk.count)]) + junk)
        try Self.expectFailure(r, code: "internal_error")
        #expect(r.exited())
    }

    @Test func unknownMessageTypeIsRejected() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Self.handshake(r)
        let body = Data(#"{"id":2,"request":{"type":"nope"}}"#.utf8)
        try Frame.writeAll(r.fd, Data([0, 0, 0, UInt8(body.count)]) + body)
        try Self.expectFailure(r, code: "internal_error")
        #expect(r.exited())
    }

    @Test func depthBeyondLimitIsRejectedWithoutClosing() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Self.handshake(r)
        try Frame.write(
            RequestFrame(id: 2, request: .dumpTree(pid: 1, maxDepth: scuMaxTreeDepth + 1)), to: r.fd)
        try Self.expectFailure(r, code: "internal_error")
        // 越界参数是单次请求的错误，连接仍可用。
        try Frame.write(RequestFrame(id: 3, request: .checkPermissions), to: r.fd)
        let reply = try Frame.read(ResponseFrame.self, from: r.fd)
        guard case .permissions = reply.response else { Issue.record("连接应仍可用"); return }
    }

    @Test func serverGivesUpWhenNobodyConnects() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scut-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = NativeServer(socketPath: dir.appendingPathComponent("n.sock").path, acceptTimeoutMs: 150)
        #expect(throws: TransportError.timeout) { try server.run() }
    }
}
