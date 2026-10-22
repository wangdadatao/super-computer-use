import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// 集成测试：真的拉起 scu-native 进程。`swift test` 会先构建全部产物。
@Suite struct HandshakeTests {
    struct NativeNotFound: Error, CustomStringConvertible {
        var description: String { "找不到 scu-native：测试 bundle 所在目录下没有该可执行文件，请先 swift build" }
    }

    /// 测试 bundle（.xctest）与可执行产物在同一产物目录下；该推断对 debug / release /
    /// 自定义 --scratch-path 都成立。找不到时明确失败，不回退到猜测的路径。
    final class BundleToken {}

    static func nativeURL() throws -> URL {
        // Swift Testing 运行器下 Bundle.allBundles 不一定含 .xctest，
        // 用本测试模块自己的 class 定位其所在 bundle。
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("scu-native")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw NativeNotFound() }
        return url
    }

    @Test func matchingVersionsHandshake() throws {
        let client = try NativeClient(nativeExecutable: try Self.nativeURL())
        defer { client.close() }
        let reply = try client.call(.checkPermissions)
        guard case .permissions = reply else {
            Issue.record("应返回权限状态")
            return
        }
    }

    @Test func versionMismatchFailsExplicitlyWithBothVersions() throws {
        let url = try Self.nativeURL()
        let error = #expect(throws: WireError.self) {
            _ = try NativeClient(
                nativeExecutable: url, protocolVersion: scuNativeProtocolVersion,
                nativeProtocolVersionOverride: scuNativeProtocolVersion + 1)
        }
        #expect(error?.code == "protocol_version_mismatch")
        #expect(error?.message.contains("\(scuNativeProtocolVersion + 1)") == true)
    }

    /// 回归：原生进程中途死亡时必须得到 platform_unavailable，而不是调用方进程被 SIGPIPE 杀死。
    /// 连续调用两次：第一次在读到 EOF 时失败，第二次直接写向已关闭的连接（SIGPIPE 的触发路径）。
    @Test func nativeDeathSurfacesAsPlatformUnavailable() throws {
        let client = try NativeClient(nativeExecutable: try Self.nativeURL())
        defer { client.close() }
        client.process.terminate()
        client.process.waitUntilExit()
        for _ in 0..<2 {
            let error = #expect(throws: WireError.self) { try client.call(.checkPermissions) }
            #expect(error?.code == "platform_unavailable")
            #expect(error?.layer == "platform")
        }
    }

    @Test func closeIsIdempotentAndRemovesSocketDirectory() throws {
        let client = try NativeClient(nativeExecutable: try Self.nativeURL())
        client.close()
        client.close()  // 不得崩溃或重复清理
        #expect(!client.process.isRunning)
    }

    @Test func coverageCountsFields() {
        let tree = AXNode(
            role: "AXWindow", title: "w",
            children: [AXNode(role: "AXButton", identifier: "a"), AXNode(role: "AXGroup")])
        let c = FieldCoverage(tree)
        #expect(c.total == 3)
        #expect(c.withIdentifier == 1)
        #expect(c.withTitle == 1)
    }
}
