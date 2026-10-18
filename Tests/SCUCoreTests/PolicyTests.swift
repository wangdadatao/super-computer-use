import Foundation
import Testing

@testable import SCUCore
@testable import SCUWire

/// 拒绝类目：清单内容取自 Grok Bot 0.71.2 的复核（verification/external-sources.md）。
@Suite struct PolicyTests {
    @Test func everyListedBundleIdIsDenied() {
        let gate = PolicyGate()
        var count = 0
        for c in PolicyGate.categories {
            for b in c.bundleIds {
                #expect(gate.evaluate(pid: 500, bundleId: b) == .deny(category: c.id), "\(b)")
                count += 1
            }
        }
        // 与外部来源登记的条目数一致：9 + 3 + 2 + 5 + 1。清单变动必须同步 external-sources.md。
        #expect(count == 20)
    }

    @Test func matchingNormalizesCaseAndWhitespace() {
        let gate = PolicyGate()
        #expect(gate.evaluate(pid: 500, bundleId: "COM.APPLE.Terminal") == .deny(category: "runs_shell_commands"))
        #expect(gate.evaluate(pid: 500, bundleId: "  com.apple.terminal\n") == .deny(category: "runs_shell_commands"))
    }

    @Test func unlistedOrMissingBundleIdIsAllowed() {
        let gate = PolicyGate()
        #expect(gate.evaluate(pid: 500, bundleId: "com.apple.finder") == .allow)
        #expect(gate.evaluate(pid: 500, bundleId: nil) == .allow)
        #expect(gate.evaluate(pid: 500, bundleId: "") == .allow)
        // 子串不算命中：只比整个 bundle id。
        #expect(gate.evaluate(pid: 500, bundleId: "com.apple.terminal.helper") == .allow)
    }

    @Test func hostProcessesAreDeniedRegardlessOfBundleId() {
        let gate = PolicyGate(hostPids: [77, 78])
        #expect(gate.evaluate(pid: 77, bundleId: nil) == .deny(category: PolicyGate.hostCategoryId))
        #expect(gate.evaluate(pid: 78, bundleId: "com.apple.finder") == .deny(category: PolicyGate.hostCategoryId))
        #expect(gate.evaluate(pid: 79, bundleId: "com.apple.finder") == .allow)
    }

    @Test func categoriesDoNotShareBundleIds() {
        let all = PolicyGate.categories.flatMap(\.bundleIds)
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0 == $0.lowercased() })
    }

    // MARK: - 祖先链

    @Test func ancestryWalksUpToButNotIncludingLaunchd() {
        let parents: [Int32: Int32] = [300: 200, 200: 100, 100: 1]
        #expect(ProcessAncestry.chain(from: 300, parentOf: { parents[$0] }) == [300, 200, 100])
    }

    @Test func ancestryStopsWhenParentUnreadable() {
        #expect(ProcessAncestry.chain(from: 300, parentOf: { _ in nil }) == [300])
    }

    @Test func ancestryTerminatesOnCycles() {
        let parents: [Int32: Int32] = [5: 6, 6: 5]
        #expect(ProcessAncestry.chain(from: 5, parentOf: { parents[$0] }) == [5, 6])
    }

    @Test func ancestryIsBoundedInDepth() {
        let chain = ProcessAncestry.chain(from: 100_000, parentOf: { $0 - 1 })
        #expect(chain.count == 64)
    }

    @Test func realAncestryContainsSelfAndParent() {
        let chain = ProcessAncestry.chain(from: getpid())
        #expect(chain.first == getpid())
        if getppid() > 1 { #expect(chain.contains(getppid())) }
        #expect(PolicyGate.forCurrentProcess().evaluate(pid: getpid(), bundleId: nil)
            == .deny(category: PolicyGate.hostCategoryId))
    }

    // MARK: - 会话中的策略

    func terminalSession() -> (DesktopSession, ScriptedReader) {
        let r = ScriptedReader()
        r.apps = .success([AppInfo(pid: 10, name: "终端", bundleId: "com.apple.Terminal")])
        return (DesktopSession(reader: r, policy: PolicyGate()), r)
    }

    @Test func readingIsNotRestrictedButCarriesTheDecision() throws {
        let (s, _) = terminalSession()
        let st = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(st.policy == .deny(category: "runs_shell_commands"))
        #expect(st.appName == "终端")
        #expect(st.reading.root.role == "AXApplication")
    }

    @Test func deniedAppNeverReachesNativeAndRepeatsAreAlwaysDenied() throws {
        let (s, r) = terminalSession()
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        for _ in 0..<3 {
            do {
                _ = try s.act(token: t.token.value, handle: 3, action: .press)
                Issue.record("应被拒绝")
            } catch let e as WireError {
                #expect(e.code == "policy_denied" && e.layer == "policy" && e.retry == "no")
                #expect(e.message.contains("终端"))
            }
        }
        #expect(r.actionCalls.isEmpty)
    }

    @Test func denialDoesNotConsumeOrInvalidateTheToken() throws {
        let (s, _) = terminalSession()
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        _ = try? s.act(token: t.token.value, handle: 3, action: .press)
        #expect(s.invalidations == 0)
        _ = try s.resolve(token: t.token.value, handle: 3)
    }

    @Test func policyComesBeforeTokenStatus() throws {
        // 令牌已失效的受限应用：仍然报策略拒绝，而不是 stale_snapshot——
        // 否则调用方会以为"重读后就能点"，然后又撞上拒绝。
        let (s, r) = terminalSession()
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        r.tree = TreeReading(root: SessionTests.sampleTree(okTitle: "变了"), truncated: false)
        _ = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)  // 旧令牌失效
        do {
            _ = try s.act(token: t.token.value, handle: 3, action: .press)
            Issue.record("应被拒绝")
        } catch let e as WireError {
            #expect(e.code == "policy_denied")
        }
    }

    @Test func clickOnDeniedAppIsAlsoDenied() throws {
        let (s, r) = terminalSession()
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(throws: WireError.self) { _ = try s.click(token: t.token.value, handle: 3) }
        #expect(r.actionCalls.isEmpty)
        #expect(r.readCount == 1)  // 没有事后重读：动作根本没执行
    }

    @Test func hostProcessIsDeniedByAncestry() throws {
        let r = ScriptedReader()
        let s = DesktopSession(reader: r, policy: PolicyGate(hostPids: [10]))
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(t.policy == .deny(category: PolicyGate.hostCategoryId))
        do {
            _ = try s.act(token: t.token.value, handle: 3, action: .press)
            Issue.record("应被拒绝")
        } catch let e as WireError {
            #expect(e.code == "policy_denied")
        }
    }

    @Test func identityLookupFailureAtReadIsRetriedAtActionAndNeverFailsOpen() throws {
        let r = ScriptedReader()
        r.apps = .failure(.platformUnavailable("原生进程不可达"))
        let s = DesktopSession(reader: r, policy: PolicyGate())
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)  // 读取本身不因身份查询失败而失败
        #expect(t.appName == nil)
        // 仍然查不到：不能确认策略，就不执行。
        do {
            _ = try s.act(token: t.token.value, handle: 3, action: .press)
            Issue.record("身份未知不应放行")
        } catch let e as WireError {
            #expect(e.code == "platform_unavailable")
        }
        #expect(r.actionCalls.isEmpty)
        // 恢复之后重查成功，动作放行。
        r.apps = .success([AppInfo(pid: 10, name: "演示", bundleId: "com.example.demo")])
        #expect(try s.act(token: t.token.value, handle: 3, action: .press) == .acted)
    }

    @Test func identityLookupFailureStillDeniesAHostByAncestry() throws {
        // 宿主判定不依赖 bundle id，但仍要先走到策略判断：身份查询失败会在这里抛错，同样不执行。
        let r = ScriptedReader()
        r.apps = .failure(.platformUnavailable("x"))
        let s = DesktopSession(reader: r, policy: PolicyGate(hostPids: [10]))
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(throws: WireError.self) { _ = try s.act(token: t.token.value, handle: 3, action: .press) }
        #expect(r.actionCalls.isEmpty)
    }

    @Test func appMissingFromTheListIsNotAFailure() throws {
        // 列表读到了，但里面没有该进程（例如非常规激活策略的应用）：没有 bundle id 可判，放行。
        let r = ScriptedReader()
        r.apps = .success([])
        let s = DesktopSession(reader: r, policy: PolicyGate())
        let t = try s.readState(pid: 10, maxDepth: 12, budgetMs: 1000)
        #expect(try s.act(token: t.token.value, handle: 3, action: .press) == .acted)
        #expect(r.listAppsCalls == 1)  // 读取时查过一次，动作时不必再查
    }
}
