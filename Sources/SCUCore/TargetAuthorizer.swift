import SCUWire

/// 一个目标应用的可见身份。读取时尽量缓存；缓存失败（nil）时动作前必须重查。
struct TargetIdentity: Sendable, Equatable {
    var name: String?
    var bundleId: String?
}

/// 策略与连接级允许列表的**唯一**执行点。
///
/// 读取与动作的规则不同：两者都受连接级允许列表约束；只有动作受硬拒绝类目约束
/// （读取不改变应用，拒绝类目只限制动作）。把“先查哪个、抛什么错”收在这里，
/// 避免新增工具/入口时各自拼一遍顺序（ADR-0015 §5、ADR-0024）。
struct TargetAuthorizer {
    let policy: PolicyGate
    let authorization: AppAuthorization

    /// 启动前检查：硬拒绝类目先于允许列表，且不需要 pid。
    func denyIfForbidden(bundleId: String?, app: String) throws {
        if case .deny(let category) = policy.evaluate(bundleId: bundleId) {
            throw WireError.policyDenied(category: category, app: app)
        }
    }

    /// 动作前检查：策略先于令牌，被拒绝的动作不消耗令牌（ADR-0015 §5）。
    func denyIfForbidden(pid: Int32, identity: TargetIdentity) throws {
        if case .deny(let category) = policy.evaluate(pid: pid, bundleId: identity.bundleId) {
            throw WireError.policyDenied(category: category, app: identity.name ?? "pid \(pid)")
        }
    }

    /// 连接级允许列表。硬拒绝类目由 `denyIfForbidden` 单独负责，且先于这里。
    func requireAuthorized(_ identity: TargetIdentity, pid: Int32) throws {
        guard authorization.permits(bundleId: identity.bundleId) else {
            throw WireError.appNotAuthorized(
                app: identity.name ?? identity.bundleId ?? "pid \(pid)",
                bundleId: identity.bundleId,
                allowed: authorization.allowedBundleIds)
        }
    }

    /// 读取：只检查连接级允许列表。
    func authorizeRead(_ identity: TargetIdentity, pid: Int32) throws {
        try requireAuthorized(identity, pid: pid)
    }

    /// 动作：硬拒绝类目 + 连接级允许列表。
    func authorizeAction(_ identity: TargetIdentity, pid: Int32) throws {
        try denyIfForbidden(pid: pid, identity: identity)
        try requireAuthorized(identity, pid: pid)
    }
}
