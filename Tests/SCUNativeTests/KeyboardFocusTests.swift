import ApplicationServices
import Foundation
import Testing

@testable import SCUNative
@testable import SCUWire

/// 焦点门禁的纯判定与读回（T-019 第二批 §1.3 U1）。
///
/// 不依赖真实应用：元素用 `AXUIElementCreateApplication(pid:)` 构造，
/// 判等注入成“同 pid 即同一元素”，把被测的判定规则与平台读值分开。
@Suite struct KeyboardFocusTests {
    private func element(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    private func samePid(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        var left: pid_t = 0
        var right: pid_t = 0
        _ = AXUIElementGetPid(a, &left)
        _ = AXUIElementGetPid(b, &right)
        return left == right
    }

    private func evidence(
        focused: AXUIElement?, focusedWindow: AXUIElement?, target: AXUIElement,
        targetWindow: AXUIElement?, within: Bool = false
    ) -> KeyboardFocus.Evidence {
        KeyboardFocus.Evidence(
            focusedElement: focused, focusedWindow: focusedWindow, targetElement: target,
            targetWindow: targetWindow, focusedWithinTargetWindow: within)
    }

    @Test func typeTextPassesWhenTargetIsFocused() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .typeText,
            evidence(focused: target, focusedWindow: nil, target: target, targetWindow: nil),
            equals: samePid)
        #expect(verdict == nil)
    }

    @Test func typeTextRefusesWhenFocusIsElsewhere() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .typeText,
            evidence(
                focused: element(2), focusedWindow: nil, target: target, targetWindow: nil),
            equals: samePid)
        #expect(verdict == .focusedElementElsewhere)
    }

    @Test func unreadableFocusIsItsOwnReason() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .typeText,
            evidence(focused: nil, focusedWindow: nil, target: target, targetWindow: nil),
            equals: samePid)
        #expect(verdict == .focusedElementUnreadable)
    }

    @Test func pressKeyRefusesWhenTargetWindowIsNotKey() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .pressKey,
            evidence(
                focused: target, focusedWindow: element(200), target: target,
                targetWindow: element(100)),
            equals: samePid)
        #expect(verdict == .windowNotKey)
    }

    @Test func pressKeyPassesForAChildOfTheTargetWindow() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .pressKey,
            evidence(
                focused: element(2), focusedWindow: element(100), target: target,
                targetWindow: element(100), within: true),
            equals: samePid)
        #expect(verdict == nil)
    }

    @Test func pressKeySkipsTheWindowCheckWithoutAWindowAncestor() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .pressKey,
            evidence(focused: target, focusedWindow: nil, target: target, targetWindow: nil),
            equals: samePid)
        #expect(verdict == nil)
    }

    @Test func pressKeyWithoutKeyWindowIsRefusedEvenWhenFocusMatches() {
        let target = element(1)
        let verdict = KeyboardFocus.verdict(
            action: .pressKey,
            evidence(
                focused: target, focusedWindow: nil, target: target,
                targetWindow: element(100)),
            equals: samePid)
        #expect(verdict == .windowNotKey)
    }

    /// 读回最多 12 次；读到目标即停。
    @Test func focusReadBackStopsWhenTheApplicationReportsTheTarget() {
        let target = element(10)
        var reads = 0
        let observed = AXBackend.waitForFocus(
            expected: target, pid: 10, attempts: 12, interval: 0.05,
            read: { _ in
                reads += 1
                return reads < 3 ? self.element(20) : target
            },
            sleep: { _ in })
        #expect(reads == 3)
        #expect(observed != nil)
    }

    /// 一直读不到目标：12 次后放弃，返回最后一次读到的元素。
    @Test func focusReadBackGivesUpAfterSixHundredMilliseconds() {
        let target = element(10)
        var reads = 0
        let observed = AXBackend.waitForFocus(
            expected: target, pid: 10, attempts: 12, interval: 0.05,
            read: { _ in
                reads += 1
                return self.element(20)
            },
            sleep: { _ in })
        #expect(reads == 12)
        #expect(observed != nil)
    }

    /// 读不到焦点：返回 nil，不把“读不到”当成“已聚焦”。
    @Test func focusReadBackReturnsNilWhenUnreadable() {
        let target = element(10)
        let observed = AXBackend.waitForFocus(
            expected: target, pid: 10, attempts: 12, interval: 0.05,
            read: { _ in nil }, sleep: { _ in })
        #expect(observed == nil)
    }
}
