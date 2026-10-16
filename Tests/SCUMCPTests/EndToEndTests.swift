import Foundation
import Testing

@testable import SCUMCP

/// 端到端：真的拉起 `scu mcp`，经管道说 MCP。不依赖辅助功能权限（只用握手、目录与应用列表）。
@Suite struct EndToEndTests {
    final class BundleToken {}

    struct BinaryNotFound: Error, CustomStringConvertible {
        var description: String { "找不到 scu：测试 bundle 所在目录下没有该可执行文件，请先 swift build" }
    }

    static func scuURL() throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("scu")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw BinaryNotFound() }
        return url
    }

    struct Run {
        var lines: [String]
        var status: Int32
        var stderr: String
    }

    /// 写入全部请求后关闭 stdin（EOF），等待进程退出。带看门狗：挂住时终止并让断言失败，而不是卡住测试。
    static func run(_ requests: [String], tmpdir: String? = nil, env extra: [String: String] = [:]) throws -> Run {
        let p = Process()
        p.executableURL = try scuURL()
        p.arguments = ["mcp"]
        var env = ProcessInfo.processInfo.environment
        if let tmpdir { env["TMPDIR"] = tmpdir }
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)

        stdin.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
        return Run(lines: lines, status: p.terminationStatus, stderr: String(decoding: err, as: UTF8.self))
    }

    @Test func handshakeListAndAppsOverRealPipes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scu-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = try Self.run([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#,
        ], tmpdir: tmp.path + "/")

        #expect(r.status == 0, "stderr：\(r.stderr)")
        // stdout 只允许协议消息：每一行都必须是合法 JSON-RPC 应答。
        #expect(r.lines.count == 3)
        for line in r.lines {
            let v = JSONValue.parse(line)
            #expect(v?["jsonrpc"]?.stringValue == "2.0", "非协议输出：\(line)")
        }
        #expect(JSONValue.parse(r.lines[0])?["result"]?["serverInfo"]?["name"]?.stringValue == "scu")
        #expect(r.lines[1].contains("get_ax_state"))
        let apps = JSONValue.parse(r.lines[2])
        #expect(apps?["result"]?["isError"] == .bool(false), "应答：\(r.lines[2])")

        // 正常退出（stdin EOF）后不遗留 socket 目录。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        #expect(leftovers.isEmpty, "泄漏：\(leftovers)")
    }

    @Test func protocolOnlyRequestsDoNotSpawnTheNativeProcess() throws {
        // initialize 与 tools/list 不需要原生进程：宿主只是列出工具时不应拉起子进程。
        // 用一个会留下标记文件的假原生进程来观察"是否被拉起"。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scu-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("spawned").path
        let fake = dir.appendingPathComponent("fake-native")
        try "#!/bin/sh\ntouch '\(marker)'\nsleep 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let r = try Self.run([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ], env: ["SCU_NATIVE": fake.path])
        #expect(r.status == 0)
        #expect(r.lines.count == 2)
        #expect(!FileManager.default.fileExists(atPath: marker), "只读协议请求不应拉起原生进程")
    }

    @Test func socketDirectoryHonorsTMPDIR() throws {
        // 正控制：没有它，"退出后临时目录为空"的断言在 TMPDIR 被忽略时也会通过（曾经就是这样）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scu-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = dir.appendingPathComponent("args").path
        let fake = dir.appendingPathComponent("fake-native")
        try "#!/bin/sh\necho \"$2\" > '\(record)'\nsleep 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let r = try Self.run([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_apps"}}"#,
        ], tmpdir: dir.path + "/", env: ["SCU_NATIVE": fake.path])
        #expect(r.status == 0)
        let socket = try String(contentsOfFile: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(socket.hasPrefix(dir.path + "/scu-"), "socket 路径：\(socket)")
        // 假原生进程不会真的监听，scu 应当以工具错误应答，而不是崩溃或挂住。
        #expect(JSONValue.parse(r.lines.first ?? "")?["result"]?["isError"] == .bool(true))
    }
}
