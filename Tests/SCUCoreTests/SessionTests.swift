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
    private(set) var readWindowTitles: [String?] = []
    func readCountReset() { readCount = 0 }
    var apps: Result<[AppInfo], WireError> = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
    private(set) var listAppsCalls = 0
    var windows: Result<[WindowInfo], WireError> = .success([
        WindowInfo(title: "主", frame: Rect(x: 0, y: 0, width: 100, height: 80))
    ])
    private(set) var listWindowsCalls: [Int32] = []
    private(set) var captureTitles: [String?] = []
    var capture: Result<WindowCapture, WireError> = .failure(.unsupportedOperation("没有配置截图"))
    var action: Result<ActionOutcome, WireError> = .success(.acted)
    private(set) var actionCalls: [(pid: Int32, locator: ElementLocator, action: ActionKind)] = []
    private(set) var actionWindowTitles: [String?] = []
    private(set) var coordinateClicks: [(pid: Int32, windowTitle: String?, x: Double, y: Double)] = []
    /// 非 nil 时坐标动作直接抛出，用来模拟“请求已写出但结果未知”。
    var coordinateError: WireError?
    private(set) var typed: [(pid: Int32, locator: ElementLocator, text: String)] = []
    private(set) var pressed: [(pid: Int32, locator: ElementLocator, key: String)] = []
    private(set) var written: [(pid: Int32, locator: ElementLocator, value: String)] = []
    /// 动作发生时执行，用来模拟"界面被这次动作改变了"。
    var onAction: (() -> Void)?

    func checkPermissions() throws -> Bool { true }
    func listApps() throws -> [AppInfo] {
        listAppsCalls += 1
        return try apps.get()
    }
    func listWindows(pid: Int32) throws -> [WindowInfo] {
        listWindowsCalls.append(pid)
        return try windows.get()
    }
    func readTree(
        pid: Int32, windowTitle: String?, maxDepth: Int, budgetMs: Int
    ) throws -> TreeReading {
        readWindowTitles.append(windowTitle)
        defer { readCount += 1 }
        guard !script.isEmpty else { return tree }
        return try script[min(readCount, script.count - 1)].get()
    }
    func captureWindow(pid: Int32, windowTitle: String?) throws -> WindowCapture {
        captureTitles.append(windowTitle)
        return try capture.get()
    }

    func clickAt(pid: Int32, windowTitle: String?, x: Double, y: Double) throws -> ActionOutcome {
        coordinateClicks.append((pid, windowTitle, x, y))
        if let coordinateError { throw coordinateError }
        return .acted
    }
    func performAction(
        pid: Int32, windowTitle: String?, locator: ElementLocator, action kind: ActionKind
    ) throws -> ActionOutcome {
        actionCalls.append((pid, locator, kind))
        actionWindowTitles.append(windowTitle)
        onAction?()
        return try action.get()
    }

    func typeText(
        pid: Int32, windowTitle: String?, locator: ElementLocator, text: String
    ) throws -> ActionOutcome {
        typed.append((pid, locator, text))
        actionWindowTitles.append(windowTitle)
        onAction?()
        return try action.get()
    }

    func pressKey(
        pid: Int32, windowTitle: String?, locator: ElementLocator, key: String
    ) throws -> ActionOutcome {
        pressed.append((pid, locator, key))
        actionWindowTitles.append(windowTitle)
        onAction?()
        return try action.get()
    }

    func setValue(
        pid: Int32, windowTitle: String?, locator: ElementLocator, value: String
    ) throws -> ActionOutcome {
        written.append((pid, locator, value))
        actionWindowTitles.append(windowTitle)
        onAction?()
        return try action.get()
    }
}

final class FakeLauncher: AppLauncher, @unchecked Sendable {
    var resolved: AppInfo? = AppInfo(pid: 0, name: "演示", bundleId: "com.example.demo")
    var launched = AppInfo(pid: 99, name: "演示", bundleId: "com.example.demo")
    private(set) var launchCount = 0

    func resolve(_ identifier: String) throws -> AppInfo? { resolved }
    func launch(_ identifier: String, activate: Bool) throws -> AppInfo {
        launchCount += 1
        return launched
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

    // MARK: - 输入与按键（ADR-0016）

    @Test func typeTextObservesTheChangeAndInvalidatesTheToken() throws {
        let (s, r) = session()
        let a = try read(s)
        r.onAction = { r.tree = TreeReading(root: Self.sampleTree(okTitle: "确定!"), truncated: false) }
        let report = try s.typeText(token: a.token.value, handle: 3, text: "hi")
        #expect(report.delivered)
        #expect(report.treeChanged == true)
        #expect(report.tokenInvalidated)
        #expect(r.typed.count == 1)
        #expect(r.typed[0].text == "hi")
        // 令牌已作废：下一次输入在联系原生层之前就被拒绝。
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.pressKey(token: a.token.value, handle: 3, key: "Return")
        }
        #expect(r.pressed.isEmpty)
    }

    @Test func setValueWritesTheValueAndInvalidatesTheToken() throws {
        let (s, r) = session()
        let a = try read(s)
        r.onAction = { r.tree = TreeReading(root: Self.sampleTree(okTitle: "新值"), truncated: false) }
        let report = try s.setValue(token: a.token.value, handle: 3, value: "新值")
        #expect(report.delivered)
        #expect(report.treeChanged == true)
        #expect(report.tokenInvalidated)
        #expect(r.written.count == 1)
        #expect(r.written[0].value == "新值")
    }

    @Test func pressKeyUsesTheSameTargetAndReportsTheEffect() throws {
        let (s, r) = session()
        let a = try read(s)
        let report = try s.pressKey(token: a.token.value, handle: 3, key: "Return")
        #expect(report.delivered)
        #expect(report.noOpSuspected == true)  // 树没变
        #expect(r.pressed.count == 1)
        #expect(r.pressed[0].key == "Return")
        #expect(r.pressed[0].locator.target.title == "确定")
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

    // MARK: - 差异渲染

    @Test func secondReadReportsNoChange() throws {
        let (s, _) = session()
        let first = try read(s)
        #expect(first.diff == nil)
        let second = try read(s)
        #expect(second.reused)
        #expect(second.diff?.unchanged == true)
        #expect(second.token == first.token)
    }

    @Test func changedTreeProducesDiffAndNewToken() throws {
        let (s, r) = session()
        let first = try read(s)
        r.tree = TreeReading(root: Self.sampleTree(okTitle: "确定!"), truncated: false)
        let second = try read(s)
        #expect(!second.reused)
        #expect(second.token != first.token)
        #expect(second.diff != nil)
        #expect(second.diff?.unchanged == false)
        // 标题变化按保守口径是删除 + 新增，不是猜测的“同一个元素改名”。
        #expect(second.diff?.removed == 1)
        #expect(second.diff?.added == 1)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.resolve(token: first.token.value, handle: 3)
        }
    }

    @Test func diffUsesThePreActionBaselineAfterTokenInvalidation() throws {
        let (s, r) = session()
        let before = try read(s)
        r.onAction = { r.tree = TreeReading(root: Self.sampleTree(okTitle: "新标题"), truncated: false) }
        _ = try s.click(token: before.token.value, handle: 3)
        // 动作后的令牌已失效，Record.snapshot 已释放；差异基线仍应保留动作前的树。
        let after = try read(s)
        #expect(after.diff != nil)
        #expect(after.diff?.unchanged == false)
        #expect(after.diff?.removed == 1)
        #expect(after.diff?.added == 1)
    }

    @Test func truncatedReadsDoNotProduceDiff() throws {
        let (s, r) = session()
        _ = try read(s)
        r.tree = TreeReading(root: Self.sampleTree(okTitle: "确定!"), truncated: true)
        let second = try read(s)
        #expect(second.diff == nil)
    }

    // MARK: - 窗口绑定

    @Test func changingTheSelectedWindowIssuesANewTokenAndStalesTheOldOne() throws {
        let (s, r) = session()
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "A"))
        let a = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000, windowTitle: "A")
        let b = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000, windowTitle: "A")
        #expect(a.token == b.token && b.reused)
        #expect(a.windowTitle == "A")

        #expect(r.readWindowTitles == ["A", "A"])

        let c = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000, windowTitle: "B")
        #expect(c.token != a.token && !c.reused)
        #expect(r.readWindowTitles == ["A", "A", "B"])
        _ = try s.click(token: c.token.value, handle: 3)
        #expect(r.actionWindowTitles == ["B"])
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.resolve(token: a.token.value, handle: 3)
        }

        _ = try s.captureScreenshot(token: c.token.value)
        #expect(r.captureTitles == ["B"])
    }

    @Test func screenshotBindsTheActuallyCapturedWindowWhenTheTokenHasNone() throws {
        let (s, r) = session()
        let inside = AXNode(
            role: "AXButton", title: "内", frame: Rect(x: 0, y: 0, width: 80, height: 20))
        let actual = AXNode(
            role: "AXWindow", title: "实际", frame: Rect(x: 0, y: 0, width: 80, height: 20),
            childCount: 1, children: [inside])
        let other = AXNode(
            role: "AXWindow", title: "其他", frame: Rect(x: 200, y: 0, width: 80, height: 20))
        r.tree = TreeReading(
            root: AXNode(role: "AXApplication", childCount: 2, children: [actual, other]),
            truncated: false)
        // 令牌没有绑定窗口（默认窗口），原生层选中的是「实际」窗口。
        let a = try read(s)
        #expect(a.windowTitle == nil)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "实际"))
        let shot = try s.captureScreenshot(token: a.token.value)

        let report = try s.clickAt(token: a.token.value, screenshotID: shot.id, x: 10, y: 10)
        #expect(r.coordinateClicks.count == 1)
        #expect(r.coordinateClicks[0].windowTitle == "实际")
        // 观察仍在令牌的应用根上读取，避免把 nil 换成实际标题后每次都签发新令牌；
        // 变化比较限定到绑定窗口，因此结构没变时不能报 treeChanged=true。
        #expect(r.readWindowTitles.allSatisfy { $0 == nil })
        #expect(report.treeChanged == false)
        #expect(report.tokenInvalidated == false)
    }

    @Test func coordinateObservationIgnoresChangesInOtherWindows() throws {
        let (s, r) = session()
        let inside = AXNode(
            role: "AXButton", title: "内", frame: Rect(x: 0, y: 0, width: 80, height: 20))
        let actual = AXNode(
            role: "AXWindow", title: "实际", frame: Rect(x: 0, y: 0, width: 80, height: 20),
            childCount: 1, children: [inside])
        let oldOtherButton = AXNode(
            role: "AXButton", title: "旧", frame: Rect(x: 200, y: 0, width: 80, height: 20))
        let other = AXNode(
            role: "AXWindow", title: "其他", frame: Rect(x: 200, y: 0, width: 80, height: 20),
            childCount: 1, children: [oldOtherButton])
        r.tree = TreeReading(
            root: AXNode(role: "AXApplication", childCount: 2, children: [actual, other]),
            truncated: false)
        let a = try read(s)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "实际"))
        let shot = try s.captureScreenshot(token: a.token.value)

        // 只改另一个窗口；截图绑定的「实际」窗口结构不变。
        let newOtherButton = AXNode(
            role: "AXButton", title: "新", frame: Rect(x: 200, y: 0, width: 80, height: 20))
        let changedOther = AXNode(
            role: "AXWindow", title: "其他", frame: Rect(x: 200, y: 0, width: 80, height: 20),
            childCount: 1, children: [newOtherButton])
        r.tree = TreeReading(
            root: AXNode(role: "AXApplication", childCount: 2, children: [actual, changedOther]),
            truncated: false)

        let report = try s.clickAt(token: a.token.value, screenshotID: shot.id, x: 10, y: 10)
        // 全局结构变了，令牌会失效；但这次动作的效果仍应按绑定窗口判为“没变化”。
        #expect(report.treeChanged == false)
        #expect(report.tokenInvalidated == true)
    }

    @Test func screenshotLabelsAreClippedToTheCapturedWindow() throws {
        let (s, r) = session()
        let inside = AXNode(role: "AXButton", title: "内", frame: Rect(x: 0, y: 0, width: 80, height: 20))
        let outside = AXNode(role: "AXButton", title: "外", frame: Rect(x: 300, y: 0, width: 80, height: 20))
        let window = AXNode(role: "AXWindow", title: "主", childCount: 2, children: [inside, outside])
        r.tree = TreeReading(
            root: AXNode(role: "AXApplication", childCount: 1, children: [window]), truncated: false)
        let a = try read(s)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 100, height: 20), windowTitle: "主"))
        let shot = try s.captureScreenshot(token: a.token.value)
        #expect(shot.labels.map(\.title) == ["内"])
    }

    @Test func coordinateActionRejectsAWindowThatMovedAfterScreenshot() throws {
        let (s, r) = session()
        let a = try read(s)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "主"))
        let shot = try s.captureScreenshot(token: a.token.value)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 20, y: 0, width: 80, height: 20), windowTitle: "主"))

        expectError("stale_geometry", retry: "after_refresh") {
            _ = try s.clickAt(token: a.token.value, screenshotID: shot.id, x: 10, y: 10)
        }
        #expect(r.coordinateClicks.isEmpty)
    }

    @Test func actionOutcomeUnknownInvalidatesTokenAndScreenshots() throws {
        let (s, r) = session()
        let a = try read(s)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "主"))
        let shot = try s.captureScreenshot(token: a.token.value)
        r.action = .failure(.actionOutcomeUnknown("模拟动作已写出但无应答"))

        expectError("action_outcome_unknown", retry: "after_refresh") {
            _ = try s.click(token: a.token.value, handle: 3)
        }
        #expect(s.screenshotBindings[shot.id] == nil)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.click(token: a.token.value, handle: 3)
        }
        #expect(r.actionCalls.count == 1)
    }

    @Test func coordinateOutcomeUnknownInvalidatesTokenAndScreenshots() throws {
        let (s, r) = session()
        let a = try read(s)
        r.capture = .success(
            WindowCapture(
                png: Data([0x89, 0x50]), width: 80, height: 20, scale: 1,
                windowFrame: Rect(x: 0, y: 0, width: 80, height: 20), windowTitle: "主"))
        let shot = try s.captureScreenshot(token: a.token.value)
        r.coordinateError = .actionOutcomeUnknown("模拟坐标动作已写出但无应答")

        expectError("action_outcome_unknown", retry: "after_refresh") {
            _ = try s.clickAt(token: a.token.value, screenshotID: shot.id, x: 10, y: 10)
        }
        #expect(s.screenshotBindings[shot.id] == nil)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.clickAt(token: a.token.value, screenshotID: shot.id, x: 10, y: 10)
        }
    }

    // MARK: - 连接级应用授权

    @Test func allowlistDeniesReadBeforeReadingTheTree() throws {
        let r = ScriptedReader()
        r.apps = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
        let s = DesktopSession(
            reader: r,
            appAuthorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.other"]))
        expectError("app_not_authorized", retry: "no") {
            _ = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        }
        #expect(r.readCount == 0)
    }

    @Test func listWindowsRespectsTheAllowlistBeforeEnumerating() throws {
        let r = ScriptedReader()
        r.apps = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
        let s = DesktopSession(
            reader: r,
            appAuthorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.other"]))
        expectError("app_not_authorized", retry: "no") {
            _ = try s.listWindows(pid: 10)
        }
        #expect(r.listWindowsCalls.isEmpty)
    }

    @Test func listWindowsReturnsWindowTitlesAndFrames() throws {
        let r = ScriptedReader()
        r.apps = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
        let s = DesktopSession(
            reader: r,
            appAuthorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.example.demo"]))
        let windows = try s.listWindows(pid: 10)
        #expect(
            windows == [
                WindowInfo(title: "主", frame: Rect(x: 0, y: 0, width: 100, height: 80))
            ])
        #expect(r.listWindowsCalls == [10])
    }

    @Test func allowlistMatchesBundleIdsCaseInsensitively() throws {
        let r = ScriptedReader()
        r.apps = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
        let s = DesktopSession(
            reader: r,
            appAuthorization: AppAuthorization(mode: .allowlist, bundleIds: [" COM.EXAMPLE.DEMO "]))
        let state = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(state.pid == 10)
        #expect(r.readCount == 1)
    }

    @Test func allowlistDeniesActionEvenWhenTheTokenWasIssuedBeforeRestriction() throws {
        let (s, r) = session()
        let a = try read(s)
        s.appAuthorization = AppAuthorization(mode: .allowlist, bundleIds: ["com.other"])
        expectError("app_not_authorized", retry: "no") {
            _ = try s.click(token: a.token.value, handle: 3)
        }
        #expect(r.actionCalls.isEmpty)
    }

    @Test func launchAppChecksTheConnectionAllowlistBeforeLaunching() throws {
        let launcher = FakeLauncher()
        let s = DesktopSession(
            reader: ScriptedReader(), launcher: launcher,
            appAuthorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.other"]))
        expectError("app_not_authorized", retry: "no") {
            _ = try s.launchApp(identifier: "com.example.demo")
        }
        #expect(launcher.launchCount == 0)
    }

    @Test func allowAllStillPermitsAppsWithoutABundleId() throws {
        let r = ScriptedReader()
        r.apps = .success([AppInfo(pid: 10, name: "无身份", bundleId: nil)])
        let s = DesktopSession(reader: r)
        let state = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(state.pid == 10)
        #expect(r.readCount == 1)
    }

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

    @Test func launchAppChecksPolicyBeforeLaunching() throws {
        let launcher = FakeLauncher()
        let s = DesktopSession(reader: ScriptedReader(), launcher: launcher)
        let info = try s.launchApp(identifier: "演示")
        #expect(info.pid == 99)
        #expect(launcher.launchCount == 1)
    }

    @Test func launchAppRefusesDeniedBundleBeforeLaunching() throws {
        let launcher = FakeLauncher()
        launcher.resolved = AppInfo(pid: 0, name: "终端", bundleId: "com.apple.Terminal")
        let s = DesktopSession(reader: ScriptedReader(), launcher: launcher)
        expectError("policy_denied", retry: "no") {
            _ = try s.launchApp(identifier: "com.apple.Terminal")
        }
        #expect(launcher.launchCount == 0)
    }

    @Test func launchAppReportsUnknownIdentifiers() throws {
        let launcher = FakeLauncher()
        launcher.resolved = nil
        let s = DesktopSession(reader: ScriptedReader(), launcher: launcher)
        expectError("app_not_found", retry: "no") {
            _ = try s.launchApp(identifier: "不存在的应用")
        }
        #expect(launcher.launchCount == 0)
    }

    @Test func labelResolvesToHandleAndIsCaseInsensitive() throws {
        let (s, _) = session()
        let t = try read(s)
        #expect(try s.resolveLabel(token: t.token.value, label: "a") == 3)
        #expect(try s.resolveLabel(token: t.token.value, label: "A") == 3)
        #expect(try s.resolveLabel(token: t.token.value, label: "b") == 4)
        expectError("element_gone", retry: "after_refresh") {
            _ = try s.resolveLabel(token: t.token.value, label: "zz")
        }
    }

    @Test func labelSurvivesGeometryOnlyReadsButNotStructureChanges() throws {
        let (s, r) = session()
        let a = try read(s)
        #expect(try s.resolveLabel(token: a.token.value, label: "a") == 3)

        // 窗口移动：结构不变，令牌复用，标签不漂。
        r.tree = TreeReading(root: Self.sampleTree(frameX: 300), truncated: false)
        let b = try read(s)
        #expect(b.reused && b.token == a.token)
        #expect(try s.resolveLabel(token: b.token.value, label: "a") == 3)

        // 结构变化：旧令牌失效，旧标签被拒；新快照的标签重新可用。
        r.tree = TreeReading(root: Self.sampleTree(okTitle: "好的"), truncated: false)
        let c = try read(s)
        #expect(c.token != a.token)
        expectError("stale_snapshot", retry: "after_refresh") {
            _ = try s.resolveLabel(token: a.token.value, label: "a")
        }
        #expect(try s.resolveLabel(token: c.token.value, label: "a") == 3)
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
        // 访达偶尔在一瞬间读不到无障碍树（`target_missing`，2026-10-19 在提交钩子里遇到过一次，重跑即过）。
        // 这是外部应用的瞬时状态，不是被测逻辑的问题：只对"读取"重试，不对判定重试。
        var attempt = 0
        var loaded: SessionState?
        while loaded == nil {
            do {
                loaded = try session.readState(pid: finder.pid, maxDepth: 12, budgetMs: 20_000)
            } catch let e as WireError where e.code == "target_missing" {
                // 访达可能刚重启、在别的 Space 或暂时没有可读窗口。重试后仍不可读就跳过：
                // 这是外部环境状态，不是被测的令牌/定位逻辑回归。
                if attempt < 3 {
                    attempt += 1
                    Thread.sleep(forTimeInterval: 1.0)
                } else {
                    return
                }
            }
        }
        let state = try #require(loaded)
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
            } catch let e as WireError where e.code == "target_missing" || e.code == "platform_unavailable" {
                // 访达在验证过程中退出/被替换：外部状态，不是误拒。
                _ = e
                return
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
