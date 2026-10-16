import SCUWire

/// P0 的原始树输出。**不是**最终的元素表格式（见 docs/interfaces/element_addressing.md）：
/// 此时还没有句柄，目的是让人能检查真实应用的树结构与字段覆盖率。
public enum TreeFormatter {
    public static func text(_ root: AXNode) -> String {
        var lines: [String] = []
        render(root, depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    static func render(_ n: AXNode, depth: Int, into lines: inout [String]) {
        var line = String(repeating: "  ", count: depth) + "[\(n.role)]"
        if let s = n.subrole { line += " subrole=\(s)" }
        if let t = n.title { line += " title=\(quote(t))" }
        if let d = n.description { line += " desc=\(quote(d))" }
        if let i = n.identifier { line += " id=\(quote(i))" }
        if let v = n.value { line += " value=\(quote(v))" }
        if n.enabled == false { line += " disabled" }
        lines.append(line)
        for c in n.children { render(c, depth: depth + 1, into: &lines) }
    }

    static func quote(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "\\n")
        let clipped = flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
        return "\"\(clipped)\""
    }
}

/// 字段覆盖率统计：回答 element_identity.md「待验证项」第 1、2 问。
// @project-doc docs/architecture/element_identity.md#open_questions
public struct FieldCoverage: Equatable, Sendable {
    public var total = 0
    public var withIdentifier = 0
    public var withTitle = 0
    public var withDescription = 0

    public init() {}

    public init(_ root: AXNode) {
        add(root)
    }

    mutating func add(_ n: AXNode) {
        total += 1
        if n.identifier != nil { withIdentifier += 1 }
        if n.title != nil { withTitle += 1 }
        if n.description != nil { withDescription += 1 }
        for c in n.children { add(c) }
    }

    public var summary: String {
        func pct(_ x: Int) -> String { total == 0 ? "-" : String(format: "%.1f%%", Double(x) * 100 / Double(total)) }
        return "元素 \(total)；有 AXIdentifier \(withIdentifier)（\(pct(withIdentifier))）；有 title \(withTitle)（\(pct(withTitle))）；有 description \(withDescription)（\(pct(withDescription))）"
    }
}
