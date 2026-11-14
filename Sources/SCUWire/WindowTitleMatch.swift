import Foundation

/// 标题被当作窗口身份时的唯一解析规则（T-019 第二批 §2）。
///
/// 严格相等（大小写敏感，与 `==` 一致）；同一个 AX 元素在列表里出现多次只算一个窗口。
/// 调用方负责把 `Resolution` 翻译成行为：`notFound` / `unique` 保持今天的行为，
/// `ambiguous` 拒绝执行并给出候选。
public enum WindowTitleMatch {
    /// 错误文案里的候选。窗口号可能读不到（CoreGraphics 没匹配上时为 nil）。
    public struct Candidate: Sendable, Equatable {
        public var windowID: UInt32?
        public var frame: Rect?

        public init(windowID: UInt32?, frame: Rect?) {
            self.windowID = windowID
            self.frame = frame
        }
    }

    public enum Resolution<Element> {
        case notFound
        case unique(Element)
        /// 去重后仍有多个匹配。
        case ambiguous(count: Int)
    }

    /// `elements` 与 `titles` 一一对应；`same` 判断两个元素是不是同一个窗口
    /// （原生层传 `CFEqual`）。
    public static func resolve<Element>(
        elements: [Element], titles: [String?], matching title: String,
        same: (Element, Element) -> Bool
    ) -> Resolution<Element> {
        var matched: [Element] = []
        for (element, candidateTitle) in zip(elements, titles) where candidateTitle == title {
            if !matched.contains(where: { same($0, element) }) {
                matched.append(element)
            }
        }
        switch matched.count {
        case 0: return .notFound
        case 1: return .unique(matched[0])
        default: return .ambiguous(count: matched.count)
        }
    }

    /// 候选清单：按 frame 的 y、x 排序（视觉顺序），读不到 frame 的排最后；
    /// 最多列 `limit` 个，其余写“等 N 个”（N 是总数）。
    public static func candidateList(_ candidates: [Candidate], limit: Int = 5) -> String {
        let ordered =
            candidates.enumerated().sorted { lhs, rhs in
                switch (lhs.element.frame, rhs.element.frame) {
                case (nil, nil): return lhs.offset < rhs.offset
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?):
                    if a.y != b.y { return a.y < b.y }
                    if a.x != b.x { return a.x < b.x }
                    return lhs.offset < rhs.offset
                }
            }.map { $0.element }
        let shown = ordered.prefix(max(1, limit)).map(describe)
        var text = shown.joined(separator: "、")
        if ordered.count > limit { text += "、等 \(ordered.count) 个" }
        return text
    }

    private static func describe(_ candidate: Candidate) -> String {
        let id = candidate.windowID.map { "#\($0)" } ?? "#-"
        guard let frame = candidate.frame else { return "\(id) (位置未知)" }
        return "\(id) (\(number(frame.x)),\(number(frame.y)),\(number(frame.width)),\(number(frame.height)))"
    }

    private static func number(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0005 { return String(format: "%.0f", rounded) }
        return String(format: "%.3f", value)
    }
}
