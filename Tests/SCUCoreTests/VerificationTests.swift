import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// T-019：验证三值化（`verified` / `refuted` / `unknown`）的不变量。
///
/// 六条不变量各一个用例，名字对应 `decisions/T-018-design-defaults.md` §2.2 的编号。
/// 判定本身只有两个纯函数（`Verification.action` / `Verification.coordinate`），
/// 所以这里先穷举判定输入，再用报告层的 `apply` 核对派生字段。
@Suite struct VerificationTests {
    // MARK: - 输入穷举

    static func allActionObservations() -> [Verification.ActionObservation] {
        let targetChangedOptions: [Bool?] = [true, false, nil]
        var out: [Verification.ActionObservation] = []
        for observed in [true, false] {
            for converged in [true, false] {
                for baseline in [true, false] {
                    for truncated in [true, false] {
                        for targetChangedValue in targetChangedOptions {
                            for changed in [true, false] {
                                out.append(
                                    .init(
                                        observed: observed, converged: converged,
                                        baselineAvailable: baseline, truncated: truncated,
                                        targetChanged: targetChangedValue, stateChanged: changed))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func allCoordinateObservations() -> [Verification.CoordinateObservation] {
        let flags: [Bool?] = [true, false, nil]
        let kinds: [String?] = ["selection_changed", "caret_pixels", nil]
        var out: [Verification.CoordinateObservation] = []
        for readable in [true, false] {
            for observed in [true, false] {
                for baseline in [true, false] {
                    for truncated in [true, false] {
                        for geometry in [true, false] {
                            for screenshot in [true, false] {
                                for landing in flags {
                                    for met in flags {
                                        for kind in kinds {
                                            out.append(
                                                .init(
                                                    readablePostcondition: readable,
                                                    observed: observed,
                                                    baselineAvailable: baseline,
                                                    treeTruncated: truncated,
                                                    geometryChanged: geometry,
                                                    screenshotAvailable: screenshot,
                                                    landingStillReadable: landing,
                                                    postcondition: met, kind: kind))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func allVerdicts() -> [VerificationVerdict] {
        var out = allActionObservations().map { Verification.action($0) }
        out += allCoordinateObservations().map { Verification.coordinate($0) }
        // 每个非 verified 状态配每个原因：报告层的 `apply` 不看输入，只看判定。
        for reason in VerificationReason.allCases {
            out.append(.init(state: .refuted, reason: reason))
            out.append(.init(state: .unknown, reason: reason))
        }
        return out
    }

    // MARK: - 构造报告

    static func clickReport() -> DesktopSession.ClickReport {
        DesktopSession.ClickReport(
            pid: 10, target: TargetKey(role: "AXButton"), delivered: true, verified: false,
            verifiedBy: nil, verificationState: .unknown, verificationReason: .observationFailed,
            observed: false, converged: false, treeChanged: nil, targetChanged: nil,
            noOpSuspected: nil, polls: 0, elapsed: 0, tokenInvalidated: false,
            observationError: nil)
    }

    static func coordinateReport() -> CoordinateReport {
        CoordinateReport(
            pid: 10, delivered: true, verified: false, verifiedBy: nil,
            verificationState: .unknown, verificationReason: .observationFailed,
            landingRole: nil, selectionBefore: nil, selectionAfter: nil,
            landingElementValid: nil, clickCount: nil, verifiedNote: nil, observed: false,
            treeChanged: nil, screenshotChanged: nil, diffRatio: nil, geometryChanged: false,
            tokenInvalidated: false, noOpSuspected: false, elapsed: 0)
    }

    static func sampleTree(okTitle: String = "确定") -> AXNode {
        SessionTests.sampleTree(okTitle: okTitle)
    }

    func session(_ r: ScriptedReader) -> (DesktopSession, ScriptedReader) {
        (DesktopSession(reader: r, settle: SessionTests.Clock().settle), r)
    }

    // MARK: - ① state == .verified ⇔ verified == true ⇔ verifiedBy != nil

    @Test func invariantOneVerifiedAgreesWithTheFlagAndTheKind() {
        for verdict in Self.allVerdicts() {
            #expect((verdict.state == .verified) == (verdict.by != nil))
            #expect((verdict.state == .verified) == (verdict.reason == nil))
            #expect((verdict.state != .verified) == (verdict.reason != nil))

            var click = Self.clickReport()
            click.apply(verdict)
            #expect(click.verified == (click.verificationState == .verified))
            #expect(click.verified == (click.verifiedBy != nil))
            #expect(click.verificationState == verdict.state)
            #expect(click.verificationReason == verdict.reason)

            var coordinate = Self.coordinateReport()
            coordinate.apply(verdict)
            #expect(coordinate.verified == (coordinate.verificationState == .verified))
            #expect(coordinate.verified == (coordinate.verifiedBy != nil))
        }
    }

    // MARK: - ② state != .verified ⇒ verified == false

    @Test func invariantTwoNonVerifiedStatesNeverReportVerified() {
        for verdict in Self.allVerdicts() where verdict.state != .verified {
            var click = Self.clickReport()
            click.apply(verdict)
            #expect(click.verified == false)
            #expect(click.verifiedBy == nil)
            #expect(click.verificationState == verdict.state)

            var coordinate = Self.coordinateReport()
            coordinate.apply(verdict)
            #expect(coordinate.verified == false)
            #expect(coordinate.verifiedBy == nil)
            #expect(coordinate.verificationState == verdict.state)
        }
    }

    // MARK: - ③ noOpSuspected == true ⇒ state != .verified

    @Test func invariantThreeNoOpSuspectedIsNeverVerified() throws {
        // 界面稳定、结构没变：疑似空操作，结论只能是 refuted 或 unknown。
        let r = ScriptedReader()
        let (s, _) = session(r)
        let before = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        let report = try s.click(token: before.token.value, handle: 3)
        #expect(report.noOpSuspected == true)
        #expect(report.verificationState != .verified)
        #expect(!report.verified)

        // 报告层：先标成疑似空操作再写入 verified，`apply` 必须把它清掉。
        var click = Self.clickReport()
        click.noOpSuspected = true
        click.apply(.init(state: .verified, by: "target_state"))
        #expect(click.noOpSuspected == false)
        #expect(click.verified)
    }

    // MARK: - ④ observed == false ⇒ state == .unknown（不得 refuted）

    @Test func invariantFourUnobservedIsAlwaysUnknown() throws {
        for observation in Self.allActionObservations() where !observation.observed {
            let verdict = Verification.action(observation)
            #expect(verdict.state == .unknown)
            #expect(verdict.reason == .observationFailed)
        }
        for observation in Self.allCoordinateObservations()
        where !observation.observed && observation.readablePostcondition {
            // 没有可读后置动作的结论与观察成败无关：见下面那条原因表用例。
            let verdict = Verification.coordinate(observation)
            #expect(verdict.state == .unknown)
            #expect(verdict.reason == .observationFailed)
        }

        // 端到端：动作已投递，但事后重读失败。
        let r = ScriptedReader()
        let (s, _) = session(r)
        let before = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.script = [
            .success(TreeReading(root: Self.sampleTree(), truncated: false)),
            .failure(.platformUnavailable("事后读取失败")),
        ]
        let report = try s.click(token: before.token.value, handle: 3)
        #expect(report.observed == false)
        #expect(report.verificationState == .unknown)
        #expect(report.verificationReason == .observationFailed)
        #expect(!report.verified)
    }

    // MARK: - ⑤ converged == false ⇒ 不得 refuted

    @Test func invariantFiveUnconvergedIsNeverRefuted() throws {
        for observation in Self.allActionObservations()
        where observation.observed && !observation.converged && observation.baselineAvailable
            && !observation.truncated
        {
            let verdict = Verification.action(observation)
            #expect(verdict.state != .refuted)
            // 没稳定时连 verified 也不给：判据要求同一份稳定读数。
            #expect(verdict.state == .unknown)
            #expect(verdict.reason == .notConverged)
        }

        // 端到端：界面一直在变，直到时钟上限。目标其实没有变化，但也不能下否定结论。
        let r = ScriptedReader()
        let (s, _) = session(r)
        let before = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.script = (0..<40).map { i in
            .success(
                TreeReading(
                    root: Self.sampleTree(okTitle: i.isMultiple(of: 2) ? "甲" : "乙"),
                    truncated: false))
        }
        let report = try s.click(token: before.token.value, handle: 3)
        #expect(report.converged == false)
        #expect(report.verificationState == .unknown)
        #expect(report.verificationReason == .notConverged)
        #expect(report.verificationState != .refuted)
    }

    // MARK: - unknown / refuted 的原因（决策文 §2.4 的表）

    @Test func reasonsFollowTheDeclaredTable() {
        func action(
            observed: Bool = true, converged: Bool = true, baseline: Bool = true,
            truncated: Bool = false, targetChanged: Bool? = false, changed: Bool = false
        ) -> VerificationVerdict {
            Verification.action(
                .init(
                    observed: observed, converged: converged, baselineAvailable: baseline,
                    truncated: truncated, targetChanged: targetChanged, stateChanged: changed))
        }
        func coordinate(
            readable: Bool = true, observed: Bool = true, baseline: Bool = true,
            truncated: Bool = false, geometry: Bool = false, screenshot: Bool = true,
            landing: Bool? = nil, met: Bool? = nil, kind: String? = nil
        ) -> VerificationVerdict {
            Verification.coordinate(
                .init(
                    readablePostcondition: readable, observed: observed,
                    baselineAvailable: baseline, treeTruncated: truncated,
                    geometryChanged: geometry, screenshotAvailable: screenshot,
                    landingStillReadable: landing, postcondition: met, kind: kind))
        }

        // refuted：已收敛、目标仍在、字段未变。
        #expect(action().state == .refuted)
        #expect(action().reason == .postconditionAbsent)
        // unknown：重读失败、基线读不到、事后截断、未收敛、目标判不了。
        #expect(action(observed: false).reason == .observationFailed)
        #expect(action(baseline: false).reason == .baselineUnavailable)
        #expect(action(truncated: true).reason == .treeTruncated)
        #expect(action(converged: false).reason == .notConverged)
        #expect(action(targetChanged: nil).reason == .targetNotVisible)
        // 截断 / 未收敛时不得下否定结论。
        #expect(action(truncated: true).state == .unknown)
        #expect(action(converged: false).state == .unknown)

        // 坐标动作：没有可读后置条件的最先短路。
        #expect(coordinate(readable: false).reason == .noReadablePostcondition)
        #expect(coordinate(readable: false, observed: false).reason == .noReadablePostcondition)
        #expect(coordinate(observed: false).reason == .observationFailed)
        #expect(coordinate(geometry: true).reason == .geometryChanged)
        #expect(coordinate(landing: false).reason == .targetNotVisible)
        #expect(coordinate(baseline: false).reason == .baselineUnavailable)
        #expect(coordinate(screenshot: false).reason == .screenshotUnavailable)
        // 判据为假、但基线/事后读取有缺口：unknown，不是 refuted。
        #expect(coordinate(baseline: false, met: false).reason == .baselineUnavailable)
        #expect(coordinate(truncated: true, met: false).reason == .treeTruncated)
        // 判据为真且带判据名才是 verified。
        #expect(coordinate(met: true, kind: "caret_pixels").state == .verified)
        #expect(coordinate(met: true, kind: "caret_pixels").by == "caret_pixels")
        #expect(coordinate(met: true).state == .unknown)
    }

    // MARK: - ⑥ treeChanged == true 不蕴含 verified

    @Test func invariantSixTreeChangeAloneDoesNotVerify() throws {
        let r = ScriptedReader()
        let (s, _) = session(r)
        let before = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        // 只在「副」窗口里加一个节点：整棵树变了，但目标（确定）的路径与自身字段都没变。
        let untouched = AXNode(
            role: "AXButton", title: "别的", frame: Rect(x: 0, y: 0, width: 10, height: 10))
        let main = AXNode(
            role: "AXWindow", title: "主", childCount: 2,
            children: [
                AXNode(role: "AXButton", title: "确定", frame: Rect(x: 0, y: 0, width: 80, height: 20)),
                AXNode(role: "AXButton", title: "取消", frame: Rect(x: 0, y: 0, width: 80, height: 20)),
            ])
        let aux = AXNode(
            role: "AXWindow", title: "副", childCount: 1, children: [untouched])
        let changedTree = AXNode(
            role: "AXApplication", childCount: 2, children: [main, aux])
        r.onAction = { r.tree = TreeReading(root: changedTree, truncated: false) }
        let report = try s.click(token: before.token.value, handle: 3)

        #expect(report.treeChanged == true)
        #expect(report.targetChanged == false)
        #expect(report.verificationState != .verified)
        #expect(!report.verified)
        #expect(report.verifiedBy == nil)
    }
}
