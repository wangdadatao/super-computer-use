import Testing

@testable import SCUCore
@testable import SCUWire

@Suite struct ElementTableTests {
    @Test func handlesAreOnePerElementInPreorderStartingAtOne() {
        let tree = AXNode(role: "AXWindow", children: [
            AXNode(role: "AXGroup", children: [AXNode(role: "AXButton"), AXNode(role: "AXButton")]),
            AXNode(role: "AXButton"),
        ])
        let r = ElementTable.render(tree)
        let lines = r.text.split(separator: "\n").map(String.init)
        #expect(lines == [
            "[AXWindow#1]", "  [AXGroup#2]", "    [AXButton#3]", "    [AXButton#4]", "  [AXButton#5]",
        ])
        #expect(r.total == 5 && r.shown == 5 && r.depth == 2)
    }

    @Test func attributesAppearInFixedOrderAndOmitWhenEmpty() {
        let n = AXNode(
            role: "AXButton", subrole: "AXCloseButton", title: "关闭", identifier: "close",
            value: "v", description: "d", enabled: false)
        #expect(ElementTable.line(n, handle: 7, depth: 1)
            == #"  [AXButton#7] "关闭" subrole=AXCloseButton desc="d" value="v" id="close" state=disabled"#)

        // 空字符串与 enabled=true/nil 都省略
        let plain = AXNode(role: "AXButton", title: "", identifier: "", value: "", description: "", enabled: true)
        #expect(ElementTable.line(plain, handle: 1, depth: 0) == "[AXButton#1]")
    }

    @Test func textCannotBreakTheOneLinePerElementStructure() {
        let n = AXNode(role: "AXStaticText", title: "a\nb\r\nc\td\"e\\f")
        let line = ElementTable.line(n, handle: 1, depth: 0)
        #expect(line == #"[AXStaticText#1] "a\nb\nc\td\"e\\f""#)
        #expect(!line.contains("\n") && !line.contains("\r"))
    }

    @Test func longFieldsAreClipped() {
        let n = AXNode(role: "AXStaticText", value: String(repeating: "长", count: 500))
        let line = ElementTable.line(n, handle: 1, depth: 0)
        #expect(line.hasSuffix("…\""))
        #expect(line.count < 200)
    }

    @Test func maxElementsCutsOutputButStillCountsEverything() {
        let tree = AXNode(role: "AXGroup", children: (0..<20).map { _ in AXNode(role: "AXButton") })
        let r = ElementTable.render(tree, maxElements: 5)
        #expect(r.total == 21 && r.shown == 5)
        #expect(r.text.split(separator: "\n").count == 5)
        #expect(r.text.hasSuffix("[AXButton#5]") || r.text.hasSuffix("  [AXButton#5]"))
    }
}
