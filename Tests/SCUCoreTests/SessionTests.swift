import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// 可编排的假读取器：每次读树返回当前的 `tree`，动作返回当前的 `action`。
final class ScriptedReader: DesktopReader {
    var tree = TreeReading(root: SessionTests.sampleTree(), truncated: false)
    /// 非空时，每次读树按顺序取一项，取完后一直返回最后一项；`Error` 项让那次读取失败。
    var script: [Result<TreeReading, WireError>] = []
    private(set) var readCount = 0
    func readCountReset() { readCount = 0 }
    var apps: Result<[AppInfo], WireError> = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
    private(set) var listAppsCalls = 0
    var action: Result<ActionOutcome, WireError> = .success(.acted)
    private(set) var actionCalls: [(pid: Int32, locator: ElementLocator, action: ActionKind)] = []

    func checkPermissions() throws -> Bool { true }
    func listApps() throws -> [AppInfo] {
        listAppsCalls += 1
        return try apps.get()
    }
    func readTree(pid: Int32, maxDepth: Int, budgetMs: Int) throws -> TreeReading {
        defer { readCount += 1 }
        guard !script.isEmpty else { return tree }
        return try script[min(readCount, script.count - 1)].get()
    }
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

    /// 虚拟时钟：`sleep` 只推进时间，测试不真的等待。
    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
        var settle: DesktopSession.Settle {
            DesktopSession.Settle(interval: 0.2, cap: 3.0, sleep: { self.now += $0 }, now: { self.now })
        }
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

/// 点击之后的效果摘要与收敛判定。时间用虚拟时钟，不真的等待。
@Suite struct ClickEffectTests {
    typealias R = Result<TreeReading, WireError>

    static func tree(okTitle: String = "确定", extra: Bool = false) -> TreeReading {
        var root = SessionTests.sampleTree(okTitle: okTitle)
        if extra {
            root.children[1].children = [AXNode(role: "AXStaticText", title: "已完成")]
            root.children[1].childCount = 1
        }
        return TreeReading(root: root, truncated: false)
    }

    func make(_ script: [R], preTruncated: Bool = false) throws
        -> (DesktopSession, ScriptedReader, SessionState, SessionTests.Clock)
    {
        let clock = SessionTests.Clock()
        let r = ScriptedReader()
        r.tree = TreeReading(root: SessionTests.sampleTree(), truncated: preTruncated)
        let s = DesktopSession(reader: r, settle: clock.settle)
        let state = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.script = script
        r.resetReadCount()
        return (s, r, state, clock)
    }

    @Test func unchangedUiIsReportedAsSuspectedNoOpAndKeepsTheToken() throws {
        let (s, r, st, _) = try make([.success(Self.tree())])
        let rep = try s.click(token: st.token.value, handle: 3)
        #expect(rep.delivered && rep.observed && rep.converged)
        #expect(rep.treeChanged == false && rep.targetChanged == false && rep.noOpSuspected == true)
        #expect(rep.polls == 2)  // 至少要两次一致的读取才算收敛
        #expect(!rep.tokenInvalidated)
        _ = try s.resolve(token: st.token.value, handle: 3)
        #expect(r.actionCalls.count == 1 && r.actionCalls[0].action == .press)
    }

    @Test func structuralChangeThatSettlesInvalidatesTheOldTokenOnly() throws {
        // 第一次重读已经变化，第二次与之一致：收敛，树变化。
        let (s, _, st, _) = try make([.success(Self.tree(extra: true)), .success(Self.tree(extra: true))])
        let rep = try s.click(token: st.token.value, handle: 3)
        #expect(rep.converged && rep.treeChanged == true && rep.noOpSuspected == false)
        #expect(rep.targetChanged == false)  // 目标按钮还在原位
        #expect(rep.tokenInvalidated)
        #expect(s.invalidations == 1)
        do {
            _ = try s.resolve(token: st.token.value, handle: 3)
            Issue.record("旧令牌应失效")
        } catch let e as WireError {
            #expect(e.code == "stale_snapshot")
        }
        // 不签发新令牌：下一次读取才会签发。
        let next = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(next.token != st.token && !next.reused)
    }

    @Test func uiThatKeepsChangingStopsAtTheCapAndIsNotConverged() throws {
        let frames: [R] = (0..<100).map { .success(Self.tree(okTitle: "t\($0)")) }
        let (s, r, st, clock) = try make(frames)
        let rep = try s.click(token: st.token.value, handle: 4)
        #expect(!rep.converged && rep.observed)
        #expect(rep.treeChanged == true && rep.noOpSuspected == false)
        #expect(rep.elapsed >= 3.0 && rep.elapsed < 3.5)
        #expect(rep.polls == r.readCount && rep.polls >= 14 && rep.polls <= 16)
        #expect(clock.now.timeIntervalSince1970 >= 3.0)
    }

    @Test func targetReplacedIsReported() throws {
        var changed = SessionTests.sampleTree()
        changed.children[0].children[0] = AXNode(role: "AXButton", title: "删除")
        let r: R = .success(TreeReading(root: changed, truncated: false))
        let (s, _, st, _) = try make([r])
        let rep = try s.click(token: st.token.value, handle: 3)
        #expect(rep.targetChanged == true && rep.treeChanged == true)
    }

    @Test func truncatedReadingsMeanUnknownNotChanged() throws {
        var t = Self.tree()
        t.truncated = true
        let (s, _, st, _) = try make([.success(t)])
        let rep = try s.click(token: st.token.value, handle: 3)
        #expect(rep.treeChanged == nil && rep.noOpSuspected == nil && rep.targetChanged == nil)
        #expect(!rep.tokenInvalidated)  // 无法判断就不作废；下一次动作由原生层核对
        _ = try s.resolve(token: st.token.value, handle: 3)
    }

    @Test func truncatedBeforeActionAlsoMeansUnknown() throws {
        let (s, _, st, _) = try make([.success(Self.tree())], preTruncated: true)
        let rep = try s.click(token: st.token.value, handle: 3)
        #expect(rep.treeChanged == nil && rep.noOpSuspected == nil)
    }

    @Test func readFailureAfterDeliveryIsReportedNotThrown() throws {
        // 动作已经投递，不能因为事后读不到界面就报"失败"让调用方重试一次点击。
        let (s, _, st, _) = try make([.failure(.platformUnavailable("原生进程崩溃"))])
        let rep = try s.click(token: st.token.value, handle: 3)
        #expect(rep.delivered && !rep.observed && !rep.converged)
        #expect(rep.treeChanged == nil && rep.noOpSuspected == nil)
        #expect(rep.observationError?.contains("platform_unavailable") == true)
    }

    @Test func staleOrUnsupportedClickDoesNotPollOrAct() throws {
        let (s, r, st, _) = try make([.success(Self.tree())])
        r.action = .failure(.unsupportedOperation("不支持"))
        #expect(throws: WireError.self) { _ = try s.click(token: st.token.value, handle: 3) }
        r.action = .success(.stale(StaleDetail(reason: .target)))
        #expect(throws: WireError.self) { _ = try s.click(token: st.token.value, handle: 3) }
        #expect(r.readCount == 0)  // 动作没发生，就不做事后重读
    }

    @Test func targetPresentMatchesPathAndKey() {
        let root = SessionTests.sampleTree()
        let loc = DesktopSession.locator(for: 2, in: ElementTable.flatten(root))  // 确定
        #expect(DesktopSession.targetPresent(loc, in: root))
        var moved = root
        moved.children[0].children.insert(AXNode(role: "AXButton", title: "新"), at: 0)
        moved.children[0].childCount = 3
        #expect(!DesktopSession.targetPresent(loc, in: moved))
    }
}

extension ScriptedReader {
    /// 把读取计数清零：测试里读取状态那一次不算点击之后的轮询。
    func resetReadCount() { readCountReset() }
}
