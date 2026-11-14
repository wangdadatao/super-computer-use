/// 动作效果的**三值**结论。0.5.1 的 `verified` 是二值，"没观察到"与"确认没生效"混在一起；
/// 这里把后者单独分出来。`verified` / `verifiedBy` 原样保留，只是由同一处判定派生。
///
/// 判定只做一次：`Verification.action(_:)` 与 `Verification.coordinate(_:)` 是唯一的两处，
/// 报告里的 `verificationState` / `verificationReason` / `verified` / `verifiedBy` 全部由它们赋值。
/// 见 `docs/decisions/T-018-design-defaults.md` §2（团队仓）。
public enum VerificationState: String, Sendable, Equatable, CaseIterable {
    /// 观察到了声明的后置条件。
    case verified
    /// 声明的后置条件为假。**只否定这一条可读谓词**，不证明界面外没有副作用。
    case refuted
    /// 判不了。**不等于成功**，调用方不得据此认为动作已生效。
    case unknown
}

/// `verificationReason` 的取值。`verified` 不带原因（用 `verifiedBy` 说明判据）。
///
/// `refuted` 目前只有一个原因：`postcondition_absent`。
public enum VerificationReason: String, Sendable, Equatable, CaseIterable {
    // refuted
    /// 已收敛、目标仍在、声明的后置条件为假。
    case postconditionAbsent = "postcondition_absent"
    // unknown
    /// 事后重读失败，或读到了但读不出这条后置条件。
    case observationFailed = "observation_failed"
    /// 事后读取被截断，树不完整。
    case treeTruncated = "tree_truncated"
    /// 事后截图取不到或不可比（像素判据要用它）。
    case screenshotUnavailable = "screenshot_unavailable"
    /// 动作前的基线读不到（或绑定窗口定位不到），没有比较基准。
    case baselineUnavailable = "baseline_unavailable"
    /// 动作后窗口位置/缩放/尺寸变了，像素判据不可比。
    case geometryChanged = "geometry_changed"
    /// 这个动作没有可读的后置条件：坐标点击非文本落点、`scroll_at`、`drag`。
    case noReadablePostcondition = "no_readable_postcondition"
    /// 落点元素在动作后已不可读（被重建或移除），看不到就判不了。
    case targetNotVisible = "target_not_visible"
    /// 事后界面一直没有稳定（静默窗口内仍在变化），读到的是中间状态。
    /// 决策文列出的六类 unknown 之外的一条：它与"重读失败"是不同的事实，不合并。
    case notConverged = "not_converged"
}

/// 一次判定：状态、原因（`verified` 时为 nil）、判据（只有 `verified` 有）。
public struct VerificationVerdict: Sendable, Equatable {
    public var state: VerificationState
    public var reason: VerificationReason?
    /// 后置条件的种类：`target_changed` / `target_state` / `selection_changed` / `caret_pixels`。
    public var by: String?

    public init(state: VerificationState, reason: VerificationReason? = nil, by: String? = nil) {
        self.state = state
        self.reason = reason
        self.by = by
    }
}

/// 判定输入与规则。纯函数，便于把"六条不变量"写成单测。
public enum Verification {
    /// 元素动作（`click` / `type_text` / `press_key` / `set_value`）声明并可读的后置条件：
    /// 目标被替换/移除（`target_changed`），或同一节点自身字段变化（`target_state`）。
    public struct ActionObservation: Sendable, Equatable {
        /// 事后成功重读过界面。
        public var observed: Bool
        /// 重读已静默；上限内仍在变化时为 false。
        public var converged: Bool
        /// 动作前的快照可作为比较基准（未被截断）。
        public var baselineAvailable: Bool
        /// 事后读取被截断。
        public var truncated: Bool
        /// 目标是否仍在原路径上。nil 表示判不了。
        public var targetResolved: Bool?
        /// 同一节点自身字段是否变了（目标仍在路径上时才看）。
        public var stateChanged: Bool

        public init(
            observed: Bool, converged: Bool, baselineAvailable: Bool, truncated: Bool,
            targetResolved: Bool?, stateChanged: Bool
        ) {
            self.observed = observed
            self.converged = converged
            self.baselineAvailable = baselineAvailable
            self.truncated = truncated
            self.targetResolved = targetResolved
            self.stateChanged = stateChanged
        }
    }

    public static func action(_ o: ActionObservation) -> VerificationVerdict {
        // 没观察到不等于没生效：不得 refuted。
        guard o.observed else { return .init(state: .unknown, reason: .observationFailed) }
        guard o.baselineAvailable else {
            return .init(state: .unknown, reason: .baselineUnavailable)
        }
        guard !o.truncated else { return .init(state: .unknown, reason: .treeTruncated) }
        // 没稳定就没有资格下否定结论；已见变化也不能算证明（判据要求同一份稳定读数）。
        guard o.converged else { return .init(state: .unknown, reason: .notConverged) }
        if o.targetResolved == true { return .init(state: .verified, by: "target_changed") }
        if o.stateChanged { return .init(state: .verified, by: "target_state") }
        if o.targetResolved == false {
            return .init(state: .refuted, reason: .postconditionAbsent)
        }
        return .init(state: .unknown, reason: .targetNotVisible)
    }

    /// 坐标动作的判定输入。`readablePostcondition == false` 覆盖非文本落点、`scroll_at` 与 `drag`：
    /// 它们没有声明的可读谓词，结论固定是 unknown + `no_readable_postcondition`。
    public struct CoordinateObservation: Sendable, Equatable {
        /// 这个动作有没有可读的后置条件。
        public var readablePostcondition: Bool
        /// 事后成功重读过界面。
        public var observed: Bool
        /// 动作前的基线可比较。
        public var baselineAvailable: Bool
        /// 事后读取被截断。
        public var treeTruncated: Bool
        /// 动作后窗口几何变化；像素判据不可比。
        public var geometryChanged: Bool
        /// 事后截图取到且可比。选区判据不看这一项。
        public var screenshotAvailable: Bool
        /// 落点元素在事后仍可读。nil 表示这条判据没有落点元素。
        public var landingStillReadable: Bool?
        /// 判据结果：true 观察到、false 为假、nil 判不了。
        public var postcondition: Bool?
        /// 观察到的后置条件种类（`selection_changed` / `caret_pixels`）。
        public var kind: String?

        public init(
            readablePostcondition: Bool, observed: Bool, baselineAvailable: Bool,
            treeTruncated: Bool, geometryChanged: Bool, screenshotAvailable: Bool,
            landingStillReadable: Bool?, postcondition: Bool?, kind: String?
        ) {
            self.readablePostcondition = readablePostcondition
            self.observed = observed
            self.baselineAvailable = baselineAvailable
            self.treeTruncated = treeTruncated
            self.geometryChanged = geometryChanged
            self.screenshotAvailable = screenshotAvailable
            self.landingStillReadable = landingStillReadable
            self.postcondition = postcondition
            self.kind = kind
        }
    }

    public static func coordinate(_ o: CoordinateObservation) -> VerificationVerdict {
        guard o.readablePostcondition else {
            return .init(state: .unknown, reason: .noReadablePostcondition)
        }
        guard o.observed else { return .init(state: .unknown, reason: .observationFailed) }
        guard !o.geometryChanged else { return .init(state: .unknown, reason: .geometryChanged) }
        if o.postcondition == true {
            // 没有判据名就不算 verified：`verifiedBy != nil ⇔ verified` 由这里保证。
            // verified 只看判据自己的前后读数，不吃树的基线：选区/光标是独立证据。
            guard let kind = o.kind else {
                return .init(state: .unknown, reason: .observationFailed)
            }
            return .init(state: .verified, by: kind)
        }
        // 下否定结论要求整段观察没有缺口：基线在、事后读取没截断。
        if o.postcondition == false {
            guard o.baselineAvailable else {
                return .init(state: .unknown, reason: .baselineUnavailable)
            }
            guard !o.treeTruncated else { return .init(state: .unknown, reason: .treeTruncated) }
            return .init(state: .refuted, reason: .postconditionAbsent)
        }
        if o.landingStillReadable == false {
            return .init(state: .unknown, reason: .targetNotVisible)
        }
        guard o.baselineAvailable else { return .init(state: .unknown, reason: .baselineUnavailable) }
        guard !o.treeTruncated else { return .init(state: .unknown, reason: .treeTruncated) }
        guard o.screenshotAvailable else {
            return .init(state: .unknown, reason: .screenshotUnavailable)
        }
        return .init(state: .unknown, reason: .observationFailed)
    }
}
