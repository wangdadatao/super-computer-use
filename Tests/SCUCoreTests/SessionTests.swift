import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// 可编排的假读取器：每次读树返回当前的 `tree`，动作返回当前的 `action`。
final class ScriptedReader: DesktopReader {
    var tree = TreeReading(root: SessionTests.sampleTree(), truncated: false)
    var action: Result<ActionOutcome, WireError> = .success(.acted)
    private(set) var actionCalls: [(pid: Int32, locator: ElementLocator, action: ActionKind)] = []

    func checkPermissions() throws -> Bool { true }
    func listApps() throws -> [AppInfo] { [] }
    func readTree(pid: Int32, maxDepth: Int, budgetMs: Int) throws -> TreeReading { tree }
    func performAction(pid: Int32, locator: ElementLocator, action kind: ActionKind) throws -> ActionOutcome {
        actionCalls.append((pid, locator, kind))
        return try action.get()
    }
}

/// 令牌签发、复用与失效分类；句柄到定位器的翻译（ADR-0015）。
@Suite struct SessionTests {
    /// app → 窗口(主) → [确定, 取消]；窗口(副)。先序句柄：app=1 主=2 确定=3 取消=4 副=5。
    static func sampleTree(okTitle: String = "确定", frameX: Double = 0) -> AXNode {
        let frame = Rect(x: frameX, y: 0, width: 80, height: 20)
        let ok = AXNode(role: "AXButton", title: okTitle, frame: frame)
        let cancel = AXNode(role: "AXButton", title: "取消", frame: frame)
        let main = AXNode(role: "AXWindow", title: "主", childCount: 2, children: [ok, cancel])
        let aux = AXNode(role: "AXWindow", title: "副", childCount: 0)
        return AXNode(role: "AXApplication", childCount: 2, children: [main, aux])
    }

    func session(_ r: ScriptedReader = ScriptedReader()) -> (DesktopSession, ScriptedReader) {
        (DesktopSession(reader: r), r)
    }

    func read(_ s: DesktopSession, pid: Int32 = 10) throws -> SessionState {
        try s.readState(pid: pid, maxDepth: 12, budgetMs: 1000)
    }

    func expectError(_ code: String, retry: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("应抛出 \(code)")
        } catch let e as WireError {
            #expect(e.code == code)
            #expect(e.retry == retry)
        } catch {
            Issue.record("意外的错误 \(error)")
        }
    }

    // MARK: - 签发与复用

    @Test func unchangedStructureReusesTheToken() throws {
        let (s, _) = session()
        let a = try read(s)
        let b = try read(s)
        #expect(!a.reused && b.reused)
        #expect(a.token == b.token)
        #expect(s.invalidations == 0)
    }

    @Test func geometryChangeDoesNotInvalidate() throws {
        // 窗口移动、控件位置变化不是结构变化。
        let (s, r) = session()
        let a = try read(s)
        r.tree = TreeReading(root: Self.sampleTree(frameX: 300), truncated: false)
        let b = try read(s)
        #expect(a.token == b.token)
    }

    @Test func valueOrTitleChangeIssuesANewTokenAndInvalidatesTheOld() throws {
        let (s, r) = session()
        let a = try read(s)
        r.tree = TreeReading(root: Self.sampleTree(okTitle: "好"), truncated: false)
        let b = try read(s)
        #expect(a.token != b.token && !b.reused)
        #expect(s.invalidations == 1)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.resolve(token: a.token.value, handle: 3)
        }
        _ = try s.resolve(token: b.token.value, handle: 3)
    }

    @Test func truncationDifferenceIsNotTheSameSnapshot() throws {
        let (s, r) = session()
        let a = try read(s)
        r.tree = TreeReading(root: Self.sampleTree(), truncated: true)
        let b = try read(s)
        #expect(a.token != b.token)
    }

    @Test func switchingTargetMarksOldTokensSwitchedNotStale() throws {
        let (s, _) = session()
        let a = try read(s, pid: 10)
        let b = try read(s, pid: 20)
        #expect(a.token != b.token)
        expectError("target_switched", retry: "after_rebind") {
            _ = try s.resolve(token: a.token.value, handle: 1)
        }
        let (pid, _) = try s.resolve(token: b.token.value, handle: 1)
        #expect(pid == 20)
    }

    @Test func switchingBackIssuesAFreshTokenEvenIfTheTreeIsIdentical() throws {
        let (s, _) = session()
        let a1 = try read(s, pid: 10)
        _ = try read(s, pid: 20)
        let a2 = try read(s, pid: 10)
        #expect(a1.token != a2.token)
    }

    // MARK: - 令牌未知

    @Test func unknownOrGarbledTokenIsStaleAndNeverReachesNative() throws {
        let (s, r) = session()
        _ = try read(s)
        for bad in ["", "garbage", "s0.1", "s999.999"] {
            expectError("stale_snapshot", retry: "after_refresh") {
                _ = try s.act(token: bad, handle: 1, action: .press)
            }
        }
        #expect(r.actionCalls.isEmpty)
    }

    @Test func tokenFromAnotherSessionIsNotAccepted() throws {
        // 重启服务后，旧令牌哪怕编号相同也不能落到新会话的快照上。
        let (s1, _) = session()
        let (s2, _) = session()
        let old = try read(s1)
        _ = try read(s2)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s2.resolve(token: old.token.value, handle: 1)
        }
    }

    @Test func tokensBeyondTheRetentionWindowAreDropped() throws {
        let r = ScriptedReader()
        let s = DesktopSession(reader: r, retainedTokens: 3)
        var tokens: [SnapshotToken] = []
        for i in 0..<5 {
            r.tree = TreeReading(root: Self.sampleTree(okTitle: "t\(i)"), truncated: false)
            tokens.append(try read(s).token)
        }
        // 最旧的两个已被丢弃，仍按"失效"处理，对调用方含义相同：重读。
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.resolve(token: tokens[0].value, handle: 1)
        }
        _ = try s.resolve(token: tokens[4].value, handle: 1)
    }

    // MARK: - 句柄

    @Test func handleOutsideTheSnapshotIsElementGone() throws {
        let (s, r) = session()
        let t = try read(s)
        for bad in [0, -1, 6, 1000] {
            expectError("element_gone", retry: "after_refresh") {
                _ = try s.act(token: t.token.value, handle: bad, action: .press)
            }
        }
        #expect(r.actionCalls.isEmpty)
        // 边界值有效。
        _ = try s.resolve(token: t.token.value, handle: 1)
        _ = try s.resolve(token: t.token.value, handle: 5)
    }

    @Test func locatorCarriesPathIndexSiblingCountAndTargetKey() throws {
        let (s, _) = session()
        let t = try read(s)
        let (pid, loc) = try s.resolve(token: t.token.value, handle: 4)  // 取消
        #expect(pid == 10)
        #expect(
            loc.path == [
                PathStep(index: 0, siblings: 2, role: "AXWindow"),
                PathStep(index: 1, siblings: 2, role: "AXButton"),
            ])
        #expect(loc.target == TargetKey(role: "AXButton", title: "取消"))
        let (_, root) = try s.resolve(token: t.token.value, handle: 1)
        #expect(root.path.isEmpty && root.target.role == "AXApplication")
        let (_, aux) = try s.resolve(token: t.token.value, handle: 5)
        #expect(aux.path == [PathStep(index: 1, siblings: 2, role: "AXWindow")])
    }

    @Test func siblingCountComesFromTheTrueCountNotTheTruncatedList() throws {
        // 预算耗尽时快照里的列表比真实子节点少：定位器必须用真实数量，否则动作时永远对不上。
        let r = ScriptedReader()
        let ok = AXNode(role: "AXButton", title: "确定")
        let window = AXNode(role: "AXWindow", childCount: 40, children: [ok])  // 只读到 1 个，真实 40 个
        r.tree = TreeReading(root: AXNode(role: "AXApplication", childCount: 1, children: [window]), truncated: true)
        let s = DesktopSession(reader: r)
        let t = try read(s)
        let (_, loc) = try s.resolve(token: t.token.value, handle: 3)
        #expect(loc.path.last == PathStep(index: 0, siblings: 40, role: "AXButton"))
    }

    // MARK: - 动作与失效

    @Test func actionPassesTheLocatorToNativeAndReturnsItsOutcome() throws {
        let (s, r) = session()
        let t = try read(s)
        #expect(try s.act(token: t.token.value, handle: 3, action: .press) == .acted)
        #expect(r.actionCalls.count == 1)
        #expect(r.actionCalls[0].pid == 10 && r.actionCalls[0].action == .press)
        #expect(r.actionCalls[0].locator.target.title == "确定")
        #expect(try s.act(token: t.token.value, handle: 3, action: .verify) == .acted)  // 假读取器固定返回值
    }

    @Test func nativeStaleBecomesStaleSnapshotAndInvalidatesTheTokenOnce() throws {
        let (s, r) = session()
        let t = try read(s)
        r.action = .success(.stale(StaleDetail(reason: .childCount, step: 0, actualCount: 3)))
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.act(token: t.token.value, handle: 3, action: .press)
        }
        #expect(s.invalidations == 1)
        #expect(r.actionCalls.count == 1)
    }

    @Test func reusingAStaleTokenIsRejectedEveryTimeButCountedOnce() throws {
        // ADR-0015 §4：每次使用都拒绝，失效迁移只记一次，且不再联系原生层。
        let (s, r) = session()
        let t = try read(s)
        r.action = .success(.stale(StaleDetail(reason: .target)))
        for _ in 0..<4 {
            expectError("stale_snapshot", retry: "after_refresh") {
                _ = try s.act(token: t.token.value, handle: 3, action: .press)
            }
        }
        #expect(s.invalidations == 1)
        #expect(r.actionCalls.count == 1)
    }

    @Test func staleDetailReachesTheMessageWithoutParsingBeingRequired() throws {
        let (s, r) = session()
        let t = try read(s)
        r.action = .success(.stale(StaleDetail(reason: .target, actual: TargetKey(role: "AXButton", title: "删除"))))
        do {
            _ = try s.act(token: t.token.value, handle: 3, action: .press)
            Issue.record("应失效")
        } catch let e as WireError {
            #expect(e.message.contains("删除"))
            #expect(e.message.contains("#3"))
        }
    }

    @Test func nativeErrorsPassThroughAndKeepTheTokenValid() throws {
        let (s, r) = session()
        let t = try read(s)
        r.action = .failure(.unsupportedOperation("不支持"))
        expectError("unsupported_operation", retry: "no") {
            _ = try s.act(token: t.token.value, handle: 3, action: .press)
        }
        #expect(s.invalidations == 0)
        _ = try s.resolve(token: t.token.value, handle: 3)  // 仍然有效
    }

    @Test func staleTokenAfterReadDoesNotLeakTheOldTreeToTheNewOne() throws {
        // 旧令牌的句柄编号在新树里指向别的元素：必须按令牌分开，不能因为"句柄数字还在范围内"就放行。
        let (s, r) = session()
        let a = try read(s)
        r.tree = TreeReading(root: Self.sampleTree(okTitle: "好"), truncated: false)
        _ = try read(s)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.act(token: a.token.value, handle: 3, action: .press)
        }
        #expect(r.actionCalls.isEmpty)
    }
}

/// 真实链路：真实原生进程读树，会话翻译定位器，原生层沿路径核对。
/// 度量"界面稳定时的误拒"：读完立刻对大量句柄做 `verify`，一个都不应被判失效。
@Suite struct SessionIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCU_SKIP_LIVE"] == nil))
    func everySampledHandleVerifiesAgainstTheLiveTreeWhenNothingChanged() throws {
        let native = NativeSession(nativeExecutable: try HandshakeTests.nativeURL())
        defer { native.close() }
        guard try native.checkPermissions() else { return }
        guard let finder = try native.listApps().first(where: { $0.bundleId == "com.apple.finder" }) else { return }

        let session = DesktopSession(reader: native)
        let state = try session.readState(pid: finder.pid, maxDepth: 12, budgetMs: 20_000)
        let total = ElementTable.flatten(state.reading.root).count
        #expect(total > 1)

        let stride = max(1, total / 150)
        var checked = 0
        var stale: [String] = []
        for handle in Swift.stride(from: 1, through: total, by: stride) {
            do {
                _ = try session.act(token: state.token.value, handle: handle, action: .verify)
                checked += 1
            } catch let e as WireError where e.code == "stale_snapshot" {
                stale.append("#\(handle)：\(e.message)")
                break  // 令牌已失效，继续用同一令牌没有意义
            }
        }
        #expect(stale.isEmpty, "界面未变却判失效：\(stale)")
        #expect(checked > 1)
    }
}
