import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// 端到端：真实原生进程 + 真实夹具应用（`scu-fixture`，行为可预知）+ 真实 `AXPress`。
///
/// 需要辅助功能权限，且会在屏幕上短暂出现夹具窗口（不抢焦点）。没有权限时**明确失败**，
/// 不静默跳过——静默跳过会让这些测试在没有权限的机器上变成空检查。
/// 确实要跳过时设置环境变量 `SCU_SKIP_LIVE=1`：整个套件被标为跳过（不计失败），
/// 此时这些验证**没有被执行**，提交说明里应写明。
final class FixtureApp {
    let process: Process
    var pid: Int32 { process.processIdentifier }

    final class BundleToken {}

    init() throws {
        let dir = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("scu-fixture")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw LiveError.message("找不到 scu-fixture：\(url.path)，请先 swift build")
        }
        process = Process()
        process.executableURL = url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

enum LiveError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let m) = self { return m }
        return ""
    }
}

/// 一次实验：原生会话 + 一个夹具实例 + 一个 DesktopSession。
final class Rig {
    let native: NativeSession
    let fixture: FixtureApp
    let session: DesktopSession

    init(policy: PolicyGate = PolicyGate(), hostPidsIncludeFixture: Bool = false) throws {
        native = NativeSession(nativeExecutable: try HandshakeTests.nativeURL())
        guard try native.checkPermissions() else {
            throw LiveError.message("没有辅助功能权限：夹具测试无法运行（设置 SCU_SKIP_LIVE=1 可跳过）")
        }
        fixture = try FixtureApp()
        let gate = hostPidsIncludeFixture ? PolicyGate(hostPids: [fixture.pid]) : policy
        session = DesktopSession(reader: native, policy: gate)
        try waitReady()
    }

    func stop() {
        fixture.stop()
        native.close()
    }

    /// 等夹具窗口出现，且界面**稳定**：连续三次读取结构一致（令牌被复用）。
    /// 刚启动的应用树还在变（菜单与窗口控件陆续出现），不等稳定就开始，
    /// 点击之后的"树变化"会混入启动期的变化，把空操作误报成有效果。
    func waitReady() throws {
        let deadline = Date().addingTimeInterval(30)
        var stableRuns = 0
        while Date() < deadline {
            if let st = try? read(), (try? handle("Increment", in: st)) != nil {
                stableRuns = st.reused ? stableRuns + 1 : 0
                if stableRuns >= 3 { return }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw LiveError.message("夹具窗口 30 秒内没有出现或没有稳定")
    }

    func read() throws -> SessionState {
        try session.readState(pid: fixture.pid, maxDepth: 12, budgetMs: 10_000)
    }

    func handle(_ title: String, in st: SessionState) throws -> Int {
        let entries = ElementTable.flatten(st.reading.root)
        guard let i = entries.firstIndex(where: { $0.node.role == "AXButton" && $0.node.title == title }) else {
            throw LiveError.message("树里没有按钮 \(title)")
        }
        return i + 1
    }

    func handle(identifier: String, in st: SessionState) throws -> Int {
        let entries = ElementTable.flatten(st.reading.root)
        guard let i = entries.firstIndex(where: { $0.node.identifier == identifier }) else {
            throw LiveError.message("树里没有标识符为 \(identifier) 的元素")
        }
        return i + 1
    }

    /// 标签当前的文本，如 `count: 3`。
    func label(startingWith prefix: String, in st: SessionState) -> String? {
        ElementTable.flatten(st.reading.root).compactMap(\.node.value).first { $0.hasPrefix(prefix) }
    }

    func count() throws -> String? { label(startingWith: "count:", in: try read()) }

    func click(_ title: String) throws -> (SessionState, DesktopSession.ClickReport) {
        let st = try read()
        return (st, try session.click(token: st.token.value, handle: try handle(title, in: st)))
    }

    func expectCode(_ code: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("应抛出 \(code)")
        } catch let e as WireError {
            #expect(e.code == code, "\(e)")
        } catch {
            Issue.record("意外错误 \(error)")
        }
    }
}

/// 动作效果、收敛判定、令牌、策略的端到端验证。串行：每个用例拉起自己的夹具。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SCU_SKIP_LIVE"] == nil))
struct FixtureTests {
    // MARK: - 动作效果（testing.md「动作效果验证」）

    @Test func clickingAnEnabledButtonChangesTheTree() throws {
        let rig = try Rig()
        defer { rig.stop() }
        #expect(try rig.count() == "count: 0")
        let (st, r) = try rig.click("Increment")
        #expect(r.delivered && r.observed && r.converged)
        #expect(r.treeChanged == true && r.noOpSuspected == false && r.targetChanged == false)
        #expect(r.tokenInvalidated)
        #expect(try rig.count() == "count: 1", "点击真的生效了")
        #expect(r.polls <= 6 && r.elapsed < 2.0, "polls=\(r.polls) elapsed=\(r.elapsed)")
        _ = st
    }

    @Test func clickingANoOpButtonIsSuspectedNoOpAndKeepsTheToken() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let (st, r) = try rig.click("NoOp")
        #expect(r.converged && r.treeChanged == false && r.noOpSuspected == true)
        #expect(!r.tokenInvalidated)
        // 令牌仍然有效：能直接再点一次，不需要重读。
        let again = try rig.session.click(token: st.token.value, handle: try rig.handle("NoOp", in: st))
        #expect(again.noOpSuspected == true)
    }

    @Test func clickingADisabledButtonReportsWhatThePlatformDoes() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        let h = try rig.handle("Disabled", in: st)
        // 计划是"照常执行并如实回报"。平台对被禁用控件的 AXPress 可能直接报错，也可能静默无效：
        // 两种都可接受，但不能把它报告成有效果。
        do {
            let r = try rig.session.click(token: st.token.value, handle: h)
            print("FIXTURE-DISABLED: 投递成功 noOpSuspected=\(String(describing: r.noOpSuspected))")
            #expect(r.noOpSuspected == true, "被禁用的按钮不应显示有效果")
        } catch let e as WireError {
            print("FIXTURE-DISABLED: 平台报错 \(e.code)：\(e.message)")
            #expect(["action_failed", "unsupported_operation"].contains(e.code))
        }
        #expect(try rig.count() == "count: 0")
    }

    @Test func clickingACoveredButtonStillPresses() throws {
        // testing.md 预期"被遮挡的元素 noOp 为 true（或直接拒绝）"。AXPress 走无障碍而不是屏幕坐标，
        // 不受遮挡影响，所以这条预期**不成立**：按钮照常被按下。记录事实，而不是迁就预期。
        let rig = try Rig()
        defer { rig.stop() }
        let (_, r) = try rig.click("Covered")
        #expect(r.treeChanged == true && r.noOpSuspected == false)
        #expect(try rig.count() == "count: 1")
    }

    @Test func unsupportedElementReportsUnsupportedOperationAndKeepsTheToken() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        let entries = ElementTable.flatten(st.reading.root)
        guard let i = entries.firstIndex(where: { $0.node.value?.hasPrefix("count:") == true }) else {
            Issue.record("没有找到标签")
            return
        }
        rig.expectCode("unsupported_operation") { _ = try rig.session.click(token: st.token.value, handle: i + 1) }
        _ = try rig.session.resolve(token: st.token.value, handle: i + 1)  // 令牌没有因此作废
    }

    // MARK: - 收敛判定（testing.md「收敛判定验证」）

    @Test func animationNeverConvergesAndIsBoundedByTheCap() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let started = Date()
        let (_, r) = try rig.click("Animate")
        #expect(!r.converged && r.observed)
        #expect(r.treeChanged == true)
        #expect(r.elapsed >= 3.0 && r.elapsed < 6.0, "elapsed=\(r.elapsed)")
        #expect(Date().timeIntervalSince(started) < 8.0, "不得无限等待")
    }

    @Test func busyBackgroundWithoutUiChangeIsReportedAsNoChange_knownLimitation() throws {
        // 第五行是已知局限：界面不动、后台繁忙，与"空操作"无法区分，不要求区分，但归属要写明。
        let rig = try Rig()
        defer { rig.stop() }
        let (_, r) = try rig.click("Busy")
        #expect(r.converged && r.treeChanged == false && r.noOpSuspected == true)
    }

    @Test func slowLoadOfTwoSecondsIsMissedByTwoEqualReads_knownGap() throws {
        // testing.md 第三行：点击后触发两秒加载，期望"等待期间不返回；稳定后返回已收敛（且有变化）"。
        // P0 的最小判定（连续两次一致）会在 0.4 秒就判已收敛，错过 2 秒后的变化：这是**未满足**的出口门槛项。
        // 用 withKnownIssue 固定"期望的行为"：它现在不成立；哪天成立了，这个测试会提示去更新记录。
        let rig = try Rig()
        defer { rig.stop() }
        let (_, r) = try rig.click("Delayed")
        print(
            "FIXTURE-DELAYED: converged=\(r.converged) treeChanged=\(String(describing: r.treeChanged)) elapsed=\(r.elapsed)"
        )
        withKnownIssue("两秒加载被过早判为收敛，见 ADR-0011 追加记录") {
            #expect(r.converged && r.treeChanged == true)
        }
        // 事实：之后界面确实变了，说明这是判定的缺口而不是夹具没生效。
        Thread.sleep(forTimeInterval: 2.5)
        let st = try rig.read()
        #expect(rig.label(startingWith: "status:", in: st) == "status: loaded")
    }

    // MARK: - 输入与按键（ADR-0016）

    @Test func typingIntoTheInputFieldChangesItsValue() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        let field = try rig.handle(identifier: "input", in: st)
        let report = try rig.session.typeText(token: st.token.value, handle: field, text: "hello")
        #expect(report.delivered)
        #expect(report.observed)
        #expect(report.treeChanged == true)
        #expect(report.tokenInvalidated)
        let after = try rig.read()
        let value = ElementTable.flatten(after.reading.root).first { $0.node.identifier == "input" }?.node.value
        #expect(value == "hello")
    }

    @Test func setValueWritesTheFieldDirectly() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        let field = try rig.handle(identifier: "input", in: st)
        let report = try rig.session.setValue(token: st.token.value, handle: field, value: "written")
        #expect(report.delivered)
        #expect(report.treeChanged == true)
        #expect(report.tokenInvalidated)
        let after = try rig.read()
        let value = ElementTable.flatten(after.reading.root).first { $0.node.identifier == "input" }?.node.value
        #expect(value == "written")
    }

    @Test func setValueOnAButtonIsUnsupportedAndKeepsTheToken() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        let button = try rig.handle("NoOp", in: st)
        rig.expectCode("unsupported_operation") {
            _ = try rig.session.setValue(token: st.token.value, handle: button, value: "x")
        }
        // 动作没有执行，令牌仍然有效。
        _ = try rig.session.act(token: st.token.value, handle: button, action: .verify)
    }

    @Test func pressingReturnInTheFieldSubmitsIt() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        _ = try rig.session.typeText(
            token: st.token.value, handle: try rig.handle(identifier: "input", in: st), text: "abc")
        let st2 = try rig.read()
        let report = try rig.session.pressKey(
            token: st2.token.value, handle: try rig.handle(identifier: "input", in: st2), key: "Return")
        #expect(report.delivered)
        #expect(report.treeChanged == true)
        let after = try rig.read()
        #expect(ElementTable.flatten(after.reading.root).compactMap(\.node.value).contains("status: submitted: abc"))
    }

    // MARK: - 令牌（testing.md「令牌语义验证」）

    @Test func validTokenActsWithoutFalseAlarm() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let st = try rig.read()
        let again = try rig.read()
        #expect(again.reused && again.token == st.token, "界面没变，令牌应沿用")
        #expect(
            try rig.session.act(token: st.token.value, handle: try rig.handle("NoOp", in: st), action: .verify)
                == .located)
    }

    @Test func valueChangeElsewhereDoesNotRejectTheTarget() throws {
        // 别处的**取值**变化（标签文字）不改变路径与核对键，句柄仍然有效：这是不误拒的一面。
        let rig = try Rig()
        defer { rig.stop() }
        let stale = try rig.read()
        let other = DesktopSession(reader: rig.native)
        let st2 = try other.readState(pid: rig.fixture.pid, maxDepth: 12, budgetMs: 10_000)
        _ = try other.click(token: st2.token.value, handle: try rig.handle("Increment", in: st2))  // count 变了
        #expect(
            try rig.session.act(
                token: stale.token.value, handle: try rig.handle("NoOp", in: stale), action: .verify) == .located)
    }

    @Test func siblingAddedInTheSameContainerRejectsTheHandle_strictnessTradeoff() throws {
        // 严格的另一面（ADR-0015 的取舍，现在有了实测）：AX 把 NSStackView 摊平，
        // "往下方加一行"在无障碍树里等于窗口多了一个子节点，通往 Increment 的路径因此被拒绝，
        // 尽管 Increment 本身毫无变化。这是误拒，不是漏判；误拒率尚未在真实动态界面上度量。
        let rig = try Rig()
        defer { rig.stop() }
        let stale = try rig.read()
        let other = DesktopSession(reader: rig.native)
        let st2 = try other.readState(pid: rig.fixture.pid, maxDepth: 12, budgetMs: 10_000)
        _ = try other.click(token: st2.token.value, handle: try rig.handle("AddRow", in: st2))
        do {
            _ = try rig.session.act(
                token: stale.token.value, handle: try rig.handle("Increment", in: stale), action: .verify)
            Issue.record("本应因路径上子节点数变化而拒绝")
        } catch let e as WireError {
            #expect(e.code == "stale_snapshot")
        }
    }

    @Test func changeOnThePathMakesTheOldTokenStaleWithTreeChangeClass() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let other = DesktopSession(reader: rig.native)
        // 先加一行，读取（令牌里有 Row 1，rows 的子节点数是 1），再由另一个会话再加一行。
        let o1 = try other.readState(pid: rig.fixture.pid, maxDepth: 12, budgetMs: 10_000)
        _ = try other.click(token: o1.token.value, handle: try rig.handle("AddRow", in: o1))
        let st = try rig.read()
        let row1 = try rig.handle("Row 1", in: st)
        let o2 = try other.readState(pid: rig.fixture.pid, maxDepth: 12, budgetMs: 10_000)
        _ = try other.click(token: o2.token.value, handle: try rig.handle("AddRow", in: o2))
        // rows 的子节点数变成 2，而令牌里记的是 1：原生层核对失败。
        rig.expectCode("stale_snapshot") {
            _ = try rig.session.act(token: st.token.value, handle: row1, action: .verify)
        }
        #expect(rig.session.invalidations >= 1)
    }

    @Test func tokenInvalidatedByOwnClickIsRejectedAfterwards() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let (st, r) = try rig.click("Increment")
        #expect(r.tokenInvalidated)
        rig.expectCode("stale_snapshot") {
            _ = try rig.session.click(token: st.token.value, handle: try rig.handle("Increment", in: st))
        }
        #expect(try rig.count() == "count: 1", "被拒绝的第二次点击没有被执行")
    }

    @Test func switchingTargetMarksTheOldTokenSwitched() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let second = try FixtureApp()
        defer { second.stop() }
        let st = try rig.read()
        let deadline = Date().addingTimeInterval(20)
        var other: SessionState?
        while other == nil, Date() < deadline {
            other = try? rig.session.readState(pid: second.pid, maxDepth: 12, budgetMs: 10_000)
            if other == nil { Thread.sleep(forTimeInterval: 0.25) }
        }
        #expect(other != nil)
        rig.expectCode("target_switched") {
            _ = try rig.session.click(token: st.token.value, handle: try rig.handle("Increment", in: st))
        }
        #expect(try rig.count() == "count: 0" || true)  // 读取会再切换目标；点击已被拒绝，计数不变由下面核对
        let back = try rig.read()
        #expect(rig.label(startingWith: "count:", in: back) == "count: 0", "被拒绝的点击没有被执行")
    }

    @Test func reusingAStaleTokenIsRejectedEveryTimeButCountedOnce() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let (st, _) = try rig.click("Increment")  // 令牌被自己的点击作废
        let before = rig.session.invalidations
        for _ in 0..<3 {
            rig.expectCode("stale_snapshot") {
                _ = try rig.session.click(token: st.token.value, handle: try rig.handle("Increment", in: st))
            }
        }
        #expect(rig.session.invalidations == before, "重复使用不再产生新的失效迁移")
        #expect(try rig.count() == "count: 1")
    }

    // MARK: - 策略（testing.md「准入与审批验证」）

    @Test func hostProcessIsRefusedBeforeAnythingReachesTheApp() throws {
        let rig = try Rig(hostPidsIncludeFixture: true)
        defer { rig.stop() }
        let st = try rig.read()
        #expect(st.policy == .deny(category: PolicyGate.hostCategoryId))
        for _ in 0..<3 {  // 重复请求每次都拒绝
            rig.expectCode("policy_denied") {
                _ = try rig.session.click(token: st.token.value, handle: try rig.handle("Increment", in: st))
            }
        }
        #expect(try rig.count() == "count: 0", "被策略拒绝的点击没有到达应用")
    }

    @Test func policyDenialAndProtocolStalenessAreDistinguishableByCodeLayerAndRetry() throws {
        let rig = try Rig(hostPidsIncludeFixture: true)
        defer { rig.stop() }
        let st = try rig.read()
        var denied: WireError?
        do { _ = try rig.session.click(token: st.token.value, handle: 1) } catch let e as WireError { denied = e }
        let stale = WireError.staleSnapshot("x")
        #expect(denied?.code == "policy_denied" && denied?.layer == "policy" && denied?.retry == "no")
        #expect(stale.code == "stale_snapshot" && stale.layer == "protocol" && stale.retry == "after_refresh")
        #expect(denied?.code != stale.code && denied?.layer != stale.layer && denied?.retry != stale.retry)
    }

    /// 读取真实的 Terminal（若它正在运行），验证按真实 bundle id 拒绝，且动作永远到不了原生层。
    /// 守卫读取器：一旦收到 performAction 就让测试失败。不会启动 Terminal，也不会操作它。
    @Test func realTerminalIsDeniedByItsRealBundleId() throws {
        guard ProcessInfo.processInfo.environment["SCU_SKIP_LIVE"] == nil else { return }
        let native = NativeSession(nativeExecutable: try HandshakeTests.nativeURL())
        defer { native.close() }
        guard try native.checkPermissions(),
            let terminal = try native.listApps().first(where: { $0.bundleId == "com.apple.Terminal" })
        else { return }  // 没在运行就没法验证，不为此启动它
        final class Guard: DesktopReader {
            let inner: NativeSession
            var acted = false
            init(_ n: NativeSession) { inner = n }
            func checkPermissions() throws -> Bool { try inner.checkPermissions() }
            func listApps() throws -> [AppInfo] { try inner.listApps() }
            func listWindows(pid: Int32) throws -> [WindowInfo] { try inner.listWindows(pid: pid) }
            func readTree(
                pid: Int32, windowTitle: String?, maxDepth: Int, budgetMs: Int
            ) throws -> TreeReading {
                try inner.readTree(
                    pid: pid, windowTitle: windowTitle, maxDepth: maxDepth, budgetMs: budgetMs)
            }
            func performAction(
                pid: Int32, windowTitle: String?, locator: ElementLocator, action: ActionKind
            ) throws -> ActionOutcome {
                acted = true
                return try inner.performAction(
                    pid: pid, windowTitle: windowTitle, locator: locator, action: action)
            }
        }
        let g = Guard(native)
        let s = DesktopSession(reader: g, policy: PolicyGate())
        let st = try s.readState(pid: terminal.pid, maxDepth: 4, budgetMs: 5_000)
        #expect(st.policy == .deny(category: "runs_shell_commands"))
        do {
            _ = try s.click(token: st.token.value, handle: 1)
            Issue.record("应被拒绝")
        } catch let e as WireError {
            #expect(e.code == "policy_denied")
        }
        #expect(!g.acted, "动作不得到达原生层")
    }
}
