import Testing

@testable import SCUCore
@testable import SCUWire

/// 策略与允许列表的单一执行点：读/动作规则不同，但顺序与错误码只在这里定义。
@Suite struct TargetAuthorizerTests {
    let terminal = TargetIdentity(name: "终端", bundleId: "com.apple.Terminal")
    let demo = TargetIdentity(name: "演示", bundleId: "com.example.demo")

    func expectError(_ code: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("应抛出 \(code)")
        } catch let e as WireError {
            #expect(e.code == code)
        } catch {
            Issue.record("意外的错误 \(error)")
        }
    }

    @Test func readOnlyChecksTheAllowlistNotTheDenyCategory() throws {
        let a = TargetAuthorizer(
            policy: PolicyGate(),
            authorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.apple.terminal"]))
        // 拒绝类目只限制动作；读取本身不改变应用状态。
        try a.authorizeRead(terminal, pid: 10)

        let blocked = TargetAuthorizer(
            policy: PolicyGate(),
            authorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.other"]))
        expectError("app_not_authorized") {
            try blocked.authorizeRead(terminal, pid: 10)
        }
    }

    @Test func actionChecksDenyCategoryBeforeTheAllowlist() {
        let a = TargetAuthorizer(
            policy: PolicyGate(),
            authorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.apple.terminal"]))
        // 即使允许列表放行，硬拒绝类目仍然拒绝动作。
        expectError("policy_denied") {
            try a.authorizeAction(terminal, pid: 10)
        }
    }

    @Test func actionChecksTheAllowlistForAllowedCategories() {
        let a = TargetAuthorizer(
            policy: PolicyGate(),
            authorization: AppAuthorization(mode: .allowlist, bundleIds: ["com.other"]))
        expectError("app_not_authorized") {
            try a.authorizeAction(demo, pid: 10)
        }
    }

    @Test func launchDeniesByBundleIdWithoutAPid() {
        let a = TargetAuthorizer(policy: PolicyGate(), authorization: .allowAll)
        expectError("policy_denied") {
            try a.denyIfForbidden(bundleId: "com.apple.Terminal", app: "终端")
        }
        // 无 bundle id 的应用按现有策略放行（清单只收后果不可逆的情形）。
        do {
            try a.denyIfForbidden(bundleId: nil, app: "未知")
        } catch {
            Issue.record("无 bundle id 不应被拒绝：\(error)")
        }
    }
}
