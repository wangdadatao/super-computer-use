import Darwin
import Foundation
import SCUWire

/// 动作准入的拒绝类目：命中即拒绝，不提供覆盖途径（policy_layer.md）。
///
/// **来源**：条目取自对 Grok Bot `0.71.2` 的 `app.asar` 的复核，证据与 SHA-256 见
/// `verification/external-sources.md`「2026-10-18 复核记录」。只借鉴清单的组织方式与条目，不复制其代码。
/// 与 Grok 的**差别**（有意的，都记在 policy_layer.md 的 P0 一节）：
/// - 只拒绝**动作**，读取不受限；Grok 连只读状态也拒绝；
/// - 没有 Sand / Grok Bot 条目：那是 Grok 保护它自己的，不是 SCU 的拒绝理由；
/// - 增加 SCU 自身与启动它的宿主进程（按进程祖先链判定，不依赖 bundle id）。
// @project-doc docs/architecture/policy_layer.md#p0_denylist
public struct PolicyGate: Sendable {
    public struct Category: Sendable, Equatable {
        public var id: String
        /// 小写 bundle id。
        public var bundleIds: [String]
    }

    public static let categories: [Category] = [
        Category(
            id: "runs_shell_commands",
            bundleIds: [
                "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "net.kovidgoyal.kitty",
                "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty", "co.zeit.hyper",
            ]),
        Category(
            id: "runs_scripts",
            bundleIds: ["com.apple.scripteditor2", "com.apple.automator", "com.apple.shortcuts"]),
        Category(id: "holds_passwords", bundleIds: ["com.apple.keychainaccess", "com.apple.passwords"]),
        Category(
            id: "hosts_terminals_and_agents",
            bundleIds: [
                "com.todesktop.230313mzl4w4u92", "co.anysphere.cursor.nightly", "co.anysphere.cursor.lab",
                "co.anysphere.cursor.alpha", "co.anysphere.cursor.dev",
            ]),
        Category(id: "changes_system_settings", bundleIds: ["com.apple.systempreferences"]),
    ]

    /// 命中即拒绝的宿主类目 id：SCU 进程自身与它的祖先进程。
    public static let hostCategoryId = "scu_or_its_host"

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(category: String)
    }

    private let hostPids: Set<Int32>

    /// - Parameter hostPids: SCU 自身与其祖先进程的 pid。
    public init(hostPids: Set<Int32> = []) {
        self.hostPids = hostPids
    }

    /// 以当前进程为起点取祖先链（含自身）。
    public static func forCurrentProcess() -> PolicyGate {
        PolicyGate(hostPids: Set(ProcessAncestry.chain(from: getpid())))
    }

    /// 没有 bundle id 的应用无法按清单归类，**放行**：清单只收后果不可逆的情形（policy_layer.md），
    /// 宁可漏掉也不把无法识别的应用一律封死。宿主判定不依赖 bundle id，不受此影响。
    public func evaluate(pid: Int32, bundleId: String?) -> Decision {
        if hostPids.contains(pid) { return .deny(category: Self.hostCategoryId) }
        guard let key = Self.normalize(bundleId) else { return .allow }
        for c in Self.categories where c.bundleIds.contains(key) { return .deny(category: c.id) }
        return .allow
    }

    /// 规范化：去空白、转小写。
    static func normalize(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? nil : t
    }
}

extension WireError {
    /// 命中拒绝类目，不可协商。`message` 给出类目与建议，调用方按 `code` 分支。
    public static func policyDenied(category: String, app: String) -> WireError {
        WireError(
            code: "policy_denied", layer: "policy", retry: "no",
            message: "\(app) 属于拒绝类目 \(category)，SCU 不会对它执行动作，重试不会改变结果。请让用户自己完成这一步。")
    }
}

/// 进程祖先链。用于识别启动 SCU 的宿主（例如 Cursor 经由多层子进程启动 `scu mcp`）。
public enum ProcessAncestry {
    /// 从 `pid` 起逐级向上，含 `pid` 自身，到 launchd（pid 1）之前为止。
    /// 读不到父进程时停止；深度有上限，防止异常数据造成死循环。
    public static func chain(from pid: Int32, parentOf: (Int32) -> Int32? = parent) -> [Int32] {
        var out: [Int32] = []
        var current = pid
        while current > 1, out.count < 64, !out.contains(current) {
            out.append(current)
            guard let p = parentOf(current) else { break }
            current = p
        }
        return out
    }

    public static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }
}
