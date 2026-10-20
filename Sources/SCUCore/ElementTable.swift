import SCUWire

/// 文本化元素表：每行一个元素，缩进表示层级，行首是 `[角色#句柄]`。
///
/// **这是元素寻址格式的只读子集，不是完整实现**：
/// - 句柄是**本次读取内**的先序编号（从 1 起，按完整树编号，与是否显示无关），
///   不跨快照延续；动作经 `DesktopSession` 把它解析成定位器（ADR-0015），句柄注册表暂缓（ADR-0013）。
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
    /// 一次快照里最多分配多少个标签。超出的可交互元素保留句柄，但不带标签。
    public static let maxLabels = 300

    /// 可交互角色的近似集合。不是"可点击"的完整判断：
    /// 自绘的行、支持 AXPress 的 AXGroup 等不在其中，等读取 AXActionNames 后再补。
    static let labelableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXMenuItem", "AXMenuButton", "AXTab", "AXSlider", "AXStepper",
        "AXIncrementor", "AXDisclosureTriangle", "AXColorWell", "AXDateField",
        "AXSplitButton",
    ]

    /// 快照内的一个短标签。标签只对签发它的令牌有效，不跨快照。
    public struct Label: Equatable, Sendable {
        public var text: String
        public var handle: Int
        public var role: String
        public var title: String?
        public var frame: Rect

        public init(text: String, handle: Int, role: String, title: String?, frame: Rect) {
            self.text = text
            self.handle = handle
            self.role = role
            self.title = title
            self.frame = frame
        }
    }

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
        /// 实际显示出来的标签（只含已显示的元素），供截图叠加与调试使用。
        public var labels: [Label]
        /// 整棵树中可标注的元素总数；超过 `maxLabels` 时大于 `labels` 的上限。
        public var labelTotal: Int
    }

    /// 先序展开后的一个元素。句柄 = 下标 + 1。
    struct Entry {
        var node: AXNode
        var depth: Int
        var parent: Int  // -1 表示根
        var size: Int  // 子树元素数，含自身
        var indexInParent: Int  // 在父节点子列表中的下标；根为 0
        var label: String?  // 快照内的短标签；只给可交互元素分配
    }

    static func flatten(_ root: AXNode) -> [Entry] {
        var out: [Entry] = []
        func walk(_ n: AXNode, depth: Int, parent: Int, index: Int) {
            let i = out.count
            out.append(
                Entry(node: n, depth: depth, parent: parent, size: 1, indexInParent: index, label: nil))
            for (k, c) in n.children.enumerated() { walk(c, depth: depth + 1, parent: i, index: k) }
            out[i].size = out.count - i
        }
        walk(root, depth: 0, parent: -1, index: 0)
        assignLabels(&out)
        return out
    }

    /// 按先序给可交互元素分配短标签。按树序而不是几何排序：
    /// 窗口移动不改变标签，令牌复用时标签也稳定。
    ///
    /// **优先叶子**：父容器和子按钮都可点击时只标子按钮，避免同一个区域叠两个标签。
    /// 左栏这种"AXGroup + AXPress、内部只有文字/图标"的行没有可标子元素，会保留标签。
    static func assignLabels(_ entries: inout [Entry]) {
        for (n, i) in labelCandidateIndices(entries).prefix(maxLabels).enumerated() {
            entries[i].label = labelText(n)
        }
    }

    static func labelCandidateIndices(_ entries: [Entry]) -> [Int] {
        var candidates = Set<Int>()
        for (i, entry) in entries.enumerated() {
            guard isLabelable(entry.node) else { continue }
            guard let frame = entry.node.frame, frame.width > 0, frame.height > 0 else { continue }
            candidates.insert(i)
        }
        guard !candidates.isEmpty else { return [] }

        var selected: [Int] = []
        for i in entries.indices {
            guard candidates.contains(i) else { continue }
            let node = entries[i].node
            let isRoleTarget = labelableRoles.contains(node.role)
            let end = i + entries[i].size
            let hasRoleDescendant = ((i + 1)..<end).contains { j in
                labelableRoles.contains(entries[j].node.role) && candidates.contains(j)
            }

            // 按钮/链接/输入框总是标；卡片容器里已有这些控件时，不再标外层容器。
            if isRoleTarget {
                selected.append(i)
                continue
            }
            if hasRoleDescendant { continue }

            // 非角色目标（支持 AXPress 的 AXGroup/AXRow）只标最外层：
            // 外层卡片已经承担点击时，内部的图片/标题分组不再重复标。
            var parent = entries[i].parent
            var hasLabelableAncestor = false
            while parent >= 0 {
                if candidates.contains(parent) {
                    hasLabelableAncestor = true
                    break
                }
                parent = entries[parent].parent
            }
            if !hasLabelableAncestor { selected.append(i) }
        }
        return selected
    }

    static func isLabelable(_ node: AXNode) -> Bool {
        guard node.enabled != false else { return false }
        if labelableRoles.contains(node.role) { return true }
        // 网页侧边栏/表格行常见：角色是 AXGroup/AXRow，但平台声明了 AXPress。
        return node.actions?.contains("AXPress") == true
    }

    /// 0 → a, 25 → z, 26 → aa, 51 → az, 52 → ba。
    static func labelText(_ index: Int) -> String {
        var i = index
        var out = ""
        repeat {
            let scalar = UnicodeScalar(97 + i % 26)!
            out = String(scalar) + out
            i = i / 26 - 1
        } while i >= 0
        return out
    }

    static func labelableCount(_ entries: [Entry]) -> Int {
        labelCandidateIndices(entries).count
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
                lines.append(
                    line(
                        entries[j].node, handle: j + 1, depth: entries[j].depth - base,
                        collapsed: hidden, label: entries[j].label))
            }
        }
        let shownLabels = entries.enumerated().compactMap { i, e -> Label? in
            guard emitted[i], let text = e.label, let frame = e.node.frame else { return nil }
            return Label(text: text, handle: i + 1, role: e.node.role, title: e.node.title, frame: frame)
        }
        return Result(
            text: lines.joined(separator: "\n"), total: entries.count, shown: shown, depth: maxDepth,
            matches: matchCount, scope: scope, labels: shownLabels, labelTotal: labelableCount(entries))
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

    static func line(_ n: AXNode, handle: Int, depth: Int, collapsed: Int = 0, label: String? = nil) -> String {
        var s = String(repeating: "  ", count: depth)
        if let label { s += "[\(label)] " }
        s += "[\(n.role)#\(handle)]"
        if let t = n.title, !t.isEmpty { s += " " + quote(t) }
        if let v = n.subrole { s += " subrole=\(v)" }
        if let d = n.description, !d.isEmpty { s += " desc=" + quote(d) }
        if let v = n.value, !v.isEmpty { s += " value=" + quote(v) }
        if let i = n.identifier, !i.isEmpty { s += " id=" + quote(i) }
        if let actions = n.actions, !actions.isEmpty { s += " actions=[\(actions.joined(separator: ","))]" }
        if n.enabled == false { s += " state=disabled" }
        if let f = n.frame { s += " frame=(\(coord(f.x)),\(coord(f.y)),\(coord(f.width)),\(coord(f.height)))" }
        if collapsed > 0 { s += " (折叠 \(collapsed))" }
        return s
    }

    static func coord(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// 带引号的单行字符串：转义反斜杠、双引号与控制字符，过长则截断。
    /// 输出永远不含换行，保证"一行一个元素"的结构不被元素文本破坏。
    public static func quote(_ s: String) -> String {
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
