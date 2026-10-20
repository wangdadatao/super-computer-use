import Foundation
import SCUWire

extension ElementTable {
    /// 差异输出的行数上限。超过时调用方回退到完整表；这是避免把一棵大树的变化全部塞进上下文。
    /// 取值是启发式：完整表默认最多 300 行，差异保留更小的预算。
    public static let defaultMaxDiffLines = 200

    /// 两个快照之间的可读差异。`text` 只含变化行；删除项只给旧句柄范围，不逐行打印。
    public struct Diff: Sendable, Equatable {
        public var text: String
        public var added: Int
        public var changed: Int
        public var removed: Int
        /// 被删除元素的旧句柄范围，例如 `3-5, 8`。旧句柄不可用于动作。
        public var removedIDs: String?
        /// 变化行超过预算；调用方应回退完整表。
        public var budgetExceeded: Bool
        /// 与上次快照完全相同。
        public var unchanged: Bool
        /// 变化行数（不含删除范围摘要）。
        public var lineCount: Int

        public init(
            text: String, added: Int, changed: Int, removed: Int, removedIDs: String?,
            budgetExceeded: Bool, unchanged: Bool, lineCount: Int
        ) {
            self.text = text
            self.added = added
            self.changed = changed
            self.removed = removed
            self.removedIDs = removedIDs
            self.budgetExceeded = budgetExceeded
            self.unchanged = unchanged
            self.lineCount = lineCount
        }

        public static let noChange = Diff(
            text: "", added: 0, changed: 0, removed: 0, removedIDs: nil,
            budgetExceeded: false, unchanged: true, lineCount: 0)
    }

    // @project-doc docs/decisions/adr_0028_incremental_tree_rendering.md#tree_diff_rendering
    /// 比较两个先序快照。匹配键是元素的语义字段（不含 value/frame），
    /// 因此值变化是 `~`，标题/标识变化会表现为删除 + 新增；这是保守但可解释的取舍。
    ///
    /// 句柄在 SCU 里是位置编号，不是稳定 ID：父级插入/删除后，未变元素的句柄也可能变化。
    /// 这类元素会作为 `~` 输出，确保调用方拿到新句柄；否则模型可能拿旧令牌的句柄继续操作。
    static func diff(
        previous: [Entry], current: [Entry], maxLines: Int = defaultMaxDiffLines
    ) -> Diff {
        let oldKeys = previous.map(identityKey)
        let newKeys = current.map(identityKey)
        let changes = newKeys.difference(from: oldKeys)

        var removedOld = Set<Int>()
        var addedNew = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removedOld.insert(offset)
            case .insert(let offset, _, _): addedNew.insert(offset)
            }
        }

        let oldSurvivors = previous.indices.filter { !removedOld.contains($0) }
        let newSurvivors = current.indices.filter { !addedNew.contains($0) }
        var changedNew = Set<Int>()
        if oldSurvivors.count == newSurvivors.count {
            for (oldIndex, newIndex) in zip(oldSurvivors, newSurvivors) {
                if oldIndex != newIndex
                    || contentKey(previous[oldIndex]) != contentKey(current[newIndex])
                {
                    changedNew.insert(newIndex)
                }
            }
        } else {
            // CollectionDifference 的删除/插入配对异常时，不做猜测：全部视为新增/变化。
            changedNew.formUnion(newSurvivors)
        }

        let removedIDs = removedOld.isEmpty
            ? nil : handleRanges(removedOld.map { $0 + 1 })
        if addedNew.isEmpty && changedNew.isEmpty && removedOld.isEmpty {
            return .noChange
        }

        var lines: [String] = []
        for index in current.indices {
            let prefix: String
            if addedNew.contains(index) {
                prefix = "+"
            } else if changedNew.contains(index) {
                prefix = "~"
            } else {
                continue
            }
            let entry = current[index]
            lines.append(
                prefix + " " + line(
                    entry.node, handle: index + 1, depth: entry.depth, label: entry.label))
        }
        let lineCount = lines.count
        if lineCount > maxLines {
            return Diff(
                text: "", added: addedNew.count, changed: changedNew.count,
                removed: removedOld.count, removedIDs: removedIDs,
                budgetExceeded: true, unchanged: false, lineCount: lineCount)
        }
        if let removedIDs {
            lines.append("Removed element IDs: \(removedIDs)（旧快照句柄，不可用于动作）")
        }
        return Diff(
            text: lines.joined(separator: "\n"), added: addedNew.count,
            changed: changedNew.count, removed: removedOld.count, removedIDs: removedIDs,
            budgetExceeded: false, unchanged: false, lineCount: lineCount)
    }

    /// 跨快照匹配用的语义键。刻意不含 value/frame/enabled：
    /// 这些字段变化应显示为 `~`，而不是把同一个元素当成删除后新增。
    private static func identityKey(_ entry: Entry) -> String {
        let n = entry.node
        return [n.role, n.subrole ?? "", n.identifier ?? "", n.title ?? "", n.description ?? ""]
            .joined(separator: "\u{1f}")
    }

    /// 判断“这一行是否变了”的内容键。包含句柄以外的展示字段与深度；
    /// 不含 frame，窗口移动不会让整棵树变成变化。
    private static func contentKey(_ entry: Entry) -> String {
        let n = entry.node
        return [
            String(entry.depth), n.role, n.subrole ?? "", n.title ?? "", n.description ?? "",
            n.value ?? "", n.identifier ?? "", n.actions?.joined(separator: ",") ?? "",
            n.enabled.map { $0 ? "1" : "0" } ?? "",
        ].joined(separator: "\u{1f}")
    }

    /// 把句柄集合压缩成范围文本，例如 `[3,4,5,8]` → `3-5, 8`。
    static func handleRanges(_ handles: [Int]) -> String {
        let sorted = Array(Set(handles)).sorted()
        guard !sorted.isEmpty else { return "" }
        var parts: [String] = []
        var start = sorted[0]
        var previous = sorted[0]
        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = value
            previous = value
        }
        parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return parts.joined(separator: ", ")
    }
}
