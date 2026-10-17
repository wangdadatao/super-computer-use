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
            RequestFrame(id: 2, request: .dumpTree(pid: 1, maxDepth: scuMaxTreeDepth + 1, budgetMs: 1000)), to: r.fd)
        try Self.expectFailure(r, code: "internal_error")
        // 越界参数是单次请求的错误，连接仍可用。
        try Frame.write(RequestFrame(id: 3, request: .checkPermissions), to: r.fd)
        let reply = try Frame.read(ResponseFrame.self, from: r.fd)
        guard case .permissions = reply.response else { Issue.record("连接应仍可用"); return }
    }

    @Test func budgetOutsideRangeIsRejected() throws {
        let r = try Self.startServer()
        defer { r.finish() }
        try Self.handshake(r)
        for bad in [0, scuTreeBudgetMsRange.upperBound + 1] {
            try Frame.write(RequestFrame(id: 2, request: .dumpTree(pid: 1, maxDepth: 1, budgetMs: bad)), to: r.fd)
            try Self.expectFailure(r, code: "internal_error")
        }
    }

    @Test func traversalBudgetExpires() {
        let b = AXBackend.TraversalBudget(milliseconds: 20)
        #expect(!b.expired)
        #expect(!b.truncated)
        Thread.sleep(forTimeInterval: 0.05)
        #expect(b.expired)
        #expect(b.truncated)
    }

    /// 需要辅助功能权限与运行中的访达；缺一则跳过。
    /// 预算取 1 毫秒：根节点读完后必然已过期，因此截断是确定的，不依赖访达当时有多大、机器有多快
    /// （批量读取之后，访达的树在 100 毫秒内就能读完，曾经的"预算 100 毫秒必然截断"不再成立）。
    @Test(.enabled(if: AXBackend.isAccessibilityTrusted()))
    func tinyBudgetTruncatesRealTree() throws {
        guard let finder = AXBackend.listApps().first(where: { $0.bundleId == "com.apple.finder" }) else { return }
        let started = Date()
        let r = try AXBackend.dumpTree(pid: finder.pid, maxDepth: 24, budgetMs: 1)
        #expect(r.truncated)
        #expect(r.root.role == "AXApplication")  // 根总是存在
        #expect(Date().timeIntervalSince(started) < 10)
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

/// 遍历顺序与截断语义：不依赖真实应用。
@Suite struct TraversalTests {
    /// 假节点：`kids` 是子节点下标。
    struct Fake {
        var name: String
        var kids: [Int]
    }

    /// 根 → [A（含 3 个子节点，其中第一个又有 100 个孙节点）, B, C]。
    static func fixture() -> [Fake] {
        var nodes: [Fake] = [Fake(name: "root", kids: [1, 2, 3])]  // 0
        nodes.append(Fake(name: "A", kids: [4, 5, 6]))  // 1
        nodes.append(Fake(name: "B", kids: []))  // 2
        nodes.append(Fake(name: "C", kids: []))  // 3
        nodes.append(Fake(name: "A0", kids: Array(7..<107)))  // 4：带 100 个孙节点
        nodes.append(Fake(name: "A1", kids: []))  // 5
        nodes.append(Fake(name: "A2", kids: []))  // 6
        for i in 0..<100 { nodes.append(Fake(name: "leaf\(i)", kids: [])) }  // 7...106
        return nodes
    }

    static func run(maxDepth: Int, expireAfterReads: Int?) -> (root: AXNode, truncated: Bool, reads: [String]) {
        let nodes = fixture()
        var reads: [String] = []
        let r = AXBackend.traverse(
            root: 0, maxDepth: maxDepth,
            isExpired: { expireAfterReads.map { reads.count >= $0 } ?? false },
            read: { i, wantChildren in
                reads.append(nodes[i].name)
                return (AXNode(role: nodes[i].name), wantChildren ? nodes[i].kids : [])
            })
        return (r.root, r.truncated, reads)
    }

    static func names(_ n: AXNode) -> [String] { [n.role] + n.children.flatMap(names) }

    @Test func fullTraversalKeepsSiblingOrderAndIsNotTruncated() {
        let r = Self.run(maxDepth: 10, expireAfterReads: nil)
        #expect(!r.truncated)
        #expect(Self.names(r.root).count == 107)
        #expect(r.root.children.map(\.role) == ["A", "B", "C"])
        #expect(r.root.children[0].children.map(\.role) == ["A0", "A1", "A2"])
    }

    @Test func readsAreBreadthFirst() {
        let r = Self.run(maxDepth: 10, expireAfterReads: nil)
        #expect(Array(r.reads.prefix(7)) == ["root", "A", "B", "C", "A0", "A1", "A2"])
    }

    @Test func expiryDropsTheDeepestNodesNotTheLaterSiblings() {
        // 先序遍历在这里会把预算花在 A0 的 100 个孙节点上，读不到 B 与 C。
        let r = Self.run(maxDepth: 10, expireAfterReads: 12)
        #expect(r.truncated)
        let all = Self.names(r.root)
        for s in ["root", "A", "B", "C", "A0", "A1", "A2"] { #expect(all.contains(s), "缺少 \(s)") }
        #expect(all.count == 12)  // 前 7 个结构节点 + 5 个孙节点
    }

    @Test func expiringAfterTheLastReadIsNotTruncation() {
        // 预算恰好在读完最后一个节点时到期：没有丢弃任何东西，不应标为截断。
        let r = Self.run(maxDepth: 10, expireAfterReads: 107)
        #expect(!r.truncated)
        #expect(Self.names(r.root).count == 107)
    }

    @Test func rootIsAlwaysReadEvenIfTheBudgetIsAlreadyExpired() {
        let r = Self.run(maxDepth: 10, expireAfterReads: 0)
        #expect(r.reads == ["root"])
        #expect(r.root.role == "root" && r.root.children.isEmpty)
        #expect(r.truncated)  // 根有 3 个子节点被丢弃
    }

    @Test func depthLimitIsNotTruncation() {
        let r = Self.run(maxDepth: 1, expireAfterReads: nil)
        #expect(!r.truncated)
        #expect(Self.names(r.root) == ["root", "A", "B", "C"])
    }
}
