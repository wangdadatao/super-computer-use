import Testing

@testable import SCUCore
@testable import SCUWire

@Suite struct ElementTableDiffTests {
    func entries(_ root: AXNode) -> [ElementTable.Entry] { ElementTable.flatten(root) }

    @Test func unchangedTreeIsReportedAsNoChange() {
        let tree = AXNode(role: "AXWindow", children: [AXNode(role: "AXButton", title: "确定")])
        let diff = ElementTable.diff(previous: entries(tree), current: entries(tree))
        #expect(diff.unchanged)
        #expect(diff.text.isEmpty)
        #expect(diff.added == 0 && diff.changed == 0 && diff.removed == 0)
    }

    @Test func valueChangeIsATildeLine() {
        let old = AXNode(role: "AXWindow", children: [AXNode(role: "AXTextField", value: "old")])
        let new = AXNode(role: "AXWindow", children: [AXNode(role: "AXTextField", value: "new")])
        let diff = ElementTable.diff(previous: entries(old), current: entries(new))
        #expect(diff.changed == 1)
        #expect(diff.added == 0 && diff.removed == 0)
        #expect(diff.text.contains("~ "))
        #expect(diff.text.contains("value=\"new\""))
    }

    @Test func insertionShiftsFollowingHandlesAndEmitsNewHandles() {
        let old = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXButton", title: "A"), AXNode(role: "AXButton", title: "B"),
            ])
        let new = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXButton", title: "X"), AXNode(role: "AXButton", title: "A"),
                AXNode(role: "AXButton", title: "B"),
            ])
        let diff = ElementTable.diff(previous: entries(old), current: entries(new))
        #expect(diff.added == 1)
        #expect(diff.changed == 2)  // A/B 的句柄从 2/3 变为 3/4
        #expect(diff.text.contains("+ "))
        #expect(diff.text.contains("#3"))
        #expect(diff.text.contains("#4"))
    }

    @Test func removalSummarizesOldHandleAndKeepsShiftedHandlesFresh() {
        let old = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXButton", title: "A"), AXNode(role: "AXButton", title: "B"),
                AXNode(role: "AXButton", title: "C"),
            ])
        let new = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXButton", title: "A"), AXNode(role: "AXButton", title: "C"),
            ])
        let diff = ElementTable.diff(previous: entries(old), current: entries(new))
        #expect(diff.removed == 1)
        #expect(diff.removedIDs == "3")
        #expect(diff.changed == 1)  // C 的句柄从 3 变为 2
        #expect(diff.text.contains("Removed element IDs: 3"))
        #expect(diff.text.contains("#3"))
        #expect(!diff.text.contains("- ["))
    }

    @Test func titleChangeIsRemovalPlusInsertion() {
        let old = AXNode(role: "AXWindow", children: [AXNode(role: "AXButton", title: "旧")])
        let new = AXNode(role: "AXWindow", children: [AXNode(role: "AXButton", title: "新")])
        let diff = ElementTable.diff(previous: entries(old), current: entries(new))
        #expect(diff.removed == 1 && diff.added == 1 && diff.changed == 0)
        #expect(diff.removedIDs == "2")
        #expect(diff.text.contains("+ "))
    }

    @Test func lineBudgetExceededDoesNotReturnPartialDiff() {
        let old = AXNode(role: "AXWindow", children: (0..<10).map { AXNode(role: "AXButton", value: "\($0)") })
        let new = AXNode(role: "AXWindow", children: (0..<10).map { AXNode(role: "AXButton", value: "v\($0)") })
        let diff = ElementTable.diff(previous: entries(old), current: entries(new), maxLines: 2)
        #expect(diff.budgetExceeded)
        #expect(diff.text.isEmpty)
        #expect(diff.changed == 10)
        #expect(diff.lineCount == 10)
    }

    @Test func handleRangesCompactsConsecutiveIDs() {
        #expect(ElementTable.handleRanges([1, 2, 3, 5, 8, 9]) == "1-3, 5, 8-9")
        #expect(ElementTable.handleRanges([4]) == "4")
        #expect(ElementTable.handleRanges([]) == "")
    }
}
