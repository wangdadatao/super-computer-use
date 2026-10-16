import SCUWire

/// 文本化元素表：每行一个元素，缩进表示层级，行首是 `[角色#句柄]`。
///
/// **这是元素寻址格式的只读子集，不是完整实现**：
/// - 句柄是**本次输出内**的先序编号（从 1 起），不跨快照延续，也没有任何动作接受它
///   （句柄注册表暂缓，见 ADR-0013）。
/// - 没有 `actions=[...]` 与 `state=focused,selected`：原生层目前不读取动作与焦点。
/// - 没有"与上次的差异"，每次都是完整表。
// @project-doc docs/interfaces/element_addressing.md#readonly_subset
public enum ElementTable {
    public static let defaultMaxElements = 1500
    public static let maxElementsRange = 1...20_000
    /// 单个字符串字段的显示上限（字符数），超出以 `…` 截断。
    static let fieldLimit = 120

    public struct Result: Equatable, Sendable {
        /// 元素表正文（不含标题行）。
        public var text: String
        /// 树中元素总数。
        public var total: Int
        /// 实际输出的元素数。`shown < total` 表示被 `maxElements` 截断。
        public var shown: Int
        /// 树的最大深度（根为 0）。
        public var depth: Int
    }

    public static func render(_ root: AXNode, maxElements: Int = defaultMaxElements) -> Result {
        var lines: [String] = []
        var next = 1
        var maxDepth = 0
        var total = 0

        func walk(_ n: AXNode, depth: Int) {
            total += 1
            maxDepth = max(maxDepth, depth)
            let handle = next
            next += 1
            if lines.count < maxElements {
                lines.append(line(n, handle: handle, depth: depth))
            }
            for c in n.children { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return Result(text: lines.joined(separator: "\n"), total: total, shown: lines.count, depth: maxDepth)
    }

    static func line(_ n: AXNode, handle: Int, depth: Int) -> String {
        var s = String(repeating: "  ", count: depth) + "[\(n.role)#\(handle)]"
        if let t = n.title, !t.isEmpty { s += " " + quote(t) }
        if let v = n.subrole { s += " subrole=\(v)" }
        if let d = n.description, !d.isEmpty { s += " desc=" + quote(d) }
        if let v = n.value, !v.isEmpty { s += " value=" + quote(v) }
        if let i = n.identifier, !i.isEmpty { s += " id=" + quote(i) }
        if n.enabled == false { s += " state=disabled" }
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
