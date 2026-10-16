import SCUWire

/// 文本化元素表：每行一个元素，缩进表示层级，行首是 `[角色#句柄]`。
///
/// **这是元素寻址格式的只读子集，不是完整实现**：
/// - 句柄是**本次读取内**的先序编号（从 1 起，按完整树编号，与是否显示无关），
///   不跨快照延续，也没有任何动作接受它（句柄注册表暂缓，见 ADR-0013）。
/// - 没有 `actions=[...]` 与 `state=focused,selected`：原生层目前不读取动作与焦点。
/// - 没有"与上次的差异"，每次都是完整表。
///
/// **超出 `maxElements` 时按层级优先取舍，而不是取先序的前 N 个**：
/// 先序截断会让第一棵大子树（如访达的侧边栏）占满配额，窗口主体与工具栏一个都看不到。
/// 层级优先保证先看到整体结构，被折叠的元素在行尾标出其下还有多少后代未显示。
// @project-doc docs/interfaces/element_addressing.md#readonly_subset
public enum ElementTable {
    public static let defaultMaxElements = 300
    public static let maxElementsRange = 1...20_000
    /// 单个字符串字段的显示上限（字符数），超出以 `…` 截断。
    static let fieldLimit = 120
    /// `focus` 命中的子树数上限。更多的命中只计数，不展开。
    public static let maxFocusMatches = 20

    /// 只显示树的一部分。两个条件同时给出时必须同时满足。
    public struct Focus: Equatable, Sendable {
        /// 与标题、描述、值、标识符中任意一个做不区分大小写的子串匹配。
        public var text: String?
        /// 角色精确匹配；`Button` 与 `AXButton` 等价。
        public var role: String?

        public init(text: String? = nil, role: String? = nil) {
            self.text = text
            self.role = role
        }

        func matches(_ n: AXNode) -> Bool {
            if let role {
                let want = role.hasPrefix("AX") ? role : "AX" + role
                guard n.role == want else { return false }
            }
            if let text, !text.isEmpty {
                let t = text.lowercased()
                let fields = [n.title, n.description, n.value, n.identifier]
                guard fields.contains(where: { $0?.lowercased().contains(t) == true }) else { return false }
            }
            return true
        }
    }

    public struct Result: Equatable, Sendable {
        /// 元素表正文（不含标题行）。
        public var text: String
        /// 树中元素总数。
        public var total: Int
        /// 实际输出的元素数（折叠标记与 focus 的路径行不计）。
        public var shown: Int
        /// 树的最大深度（根为 0）。
        public var depth: Int
        /// 使用 `focus` 时命中的子树总数（含超出 `maxFocusMatches` 而未展开的）；未使用 `focus` 时为 nil。
        public var matches: Int?
        /// 命中范围内的元素总数；未使用 `focus` 时等于 `total`。
        public var scope: Int
    }

    /// 先序展开后的一个元素。句柄 = 下标 + 1。
    struct Entry {
        var node: AXNode
        var depth: Int
        var parent: Int  // -1 表示根
        var size: Int  // 子树元素数，含自身
    }

    static func flatten(_ root: AXNode) -> [Entry] {
        var out: [Entry] = []
        func walk(_ n: AXNode, depth: Int, parent: Int) {
            let i = out.count
            out.append(Entry(node: n, depth: depth, parent: parent, size: 1))
            for c in n.children { walk(c, depth: depth + 1, parent: i) }
            out[i].size = out.count - i
        }
        walk(root, depth: 0, parent: -1)
        return out
    }

    public static func render(
        _ root: AXNode, maxElements: Int = defaultMaxElements, focus: Focus? = nil
    ) -> Result {
        let entries = flatten(root)
        let maxDepth = entries.map(\.depth).max() ?? 0

        // 选出要显示的子树根（先序区间）。无 focus 时就是整棵树。
        var roots: [Int] = []
        var matchCount: Int?
        if let focus {
            var i = 0
            var count = 0
            while i < entries.count {
                if focus.matches(entries[i].node) {
                    count += 1
                    if roots.count < maxFocusMatches { roots.append(i) }
                    i += entries[i].size  // 只取最外层命中，其子树整体展开
                } else {
                    i += 1
                }
            }
            matchCount = count
        } else {
            roots = [0]
        }
        let scope = roots.reduce(0) { $0 + entries[$1].size }

        // 相对深度（相对各自子树根）；统计每层元素数，找出放得下的层数。
        var perLevel: [Int] = []
        for r in roots {
            let base = entries[r].depth
            for j in r..<(r + entries[r].size) {
                let d = entries[j].depth - base
                if d >= perLevel.count { perLevel.append(contentsOf: Array(repeating: 0, count: d - perLevel.count + 1)) }
                perLevel[d] += 1
            }
        }
        // 完整层依次放入；放不下的那一层按先序放满剩余配额。
        var used = 0
        var frontier = perLevel.count  // 全部放得下时 = 层数
        for (d, n) in perLevel.enumerated() {
            if used + n > maxElements {
                frontier = d
                break
            }
            used += n
        }
        var frontierQuota = frontier < perLevel.count ? maxElements - used : 0
        // 至少显示每个子树根；配额小于根数时按先序取前面的根。
        var emitted = [Bool](repeating: false, count: entries.count)
        var shown = 0
        for r in roots {
            let base = entries[r].depth
            for j in r..<(r + entries[r].size) {
                let d = entries[j].depth - base
                if d < frontier {
                    emitted[j] = true
                    shown += 1
                } else if d == frontier, frontierQuota > 0 {
                    emitted[j] = true
                    frontierQuota -= 1
                    shown += 1
                }
            }
        }
        var prefix = [Int](repeating: 0, count: entries.count + 1)
        for j in 0..<entries.count { prefix[j + 1] = prefix[j] + (emitted[j] ? 1 : 0) }

        var lines: [String] = []
        for r in roots {
            if focus != nil { lines.append("@ " + pathText(entries, to: r)) }
            let base = entries[r].depth
            for j in r..<(r + entries[r].size) where emitted[j] {
                let sub = entries[j].size - 1
                let hidden = sub - (prefix[j + entries[j].size] - prefix[j + 1])
                lines.append(line(entries[j].node, handle: j + 1, depth: entries[j].depth - base, collapsed: hidden))
            }
        }
        return Result(
            text: lines.joined(separator: "\n"), total: entries.count, shown: shown, depth: maxDepth,
            matches: matchCount, scope: scope)
    }

    /// 从根到目标元素的祖先链，供 `focus` 的结果说明"这块在哪里"。
    static func pathText(_ entries: [Entry], to index: Int) -> String {
        var chain: [Int] = []
        var i = entries[index].parent
        while i >= 0 {
            chain.append(i)
            i = entries[i].parent
        }
        chain.reverse()
        let parts = chain.map { j -> String in
            let n = entries[j].node
            let label = [n.title, n.description].compactMap { $0 }.first { !$0.isEmpty }
            return label.map { "\(n.role) \(quote($0))" } ?? n.role
        }
        return parts.isEmpty ? "（树根）" : parts.joined(separator: " > ")
    }

    static func line(_ n: AXNode, handle: Int, depth: Int, collapsed: Int = 0) -> String {
        var s = String(repeating: "  ", count: depth) + "[\(n.role)#\(handle)]"
        if let t = n.title, !t.isEmpty { s += " " + quote(t) }
        if let v = n.subrole { s += " subrole=\(v)" }
        if let d = n.description, !d.isEmpty { s += " desc=" + quote(d) }
        if let v = n.value, !v.isEmpty { s += " value=" + quote(v) }
        if let i = n.identifier, !i.isEmpty { s += " id=" + quote(i) }
        if n.enabled == false { s += " state=disabled" }
        if collapsed > 0 { s += " (折叠 \(collapsed))" }
        return s
    }

    /// 带引号的单行字符串：转义反斜杠、双引号与控制字符，过长则截断。
    /// 输出永远不含换行，保证"一行一个元素"的结构不被元素文本破坏。
    static func quote(_ s: String) -> String {
        var out = ""
        var count = 0
        for ch in s {
            if count >= fieldLimit {
                out += "…"
                break
            }
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
            count += 1
        }
        return "\"" + out + "\""
    }
}
