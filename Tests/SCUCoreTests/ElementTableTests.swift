import Testing

@testable import SCUCore
@testable import SCUWire

@Suite struct ElementTableTests {
    @Test func handlesAreOnePerElementInPreorderStartingAtOne() {
        let tree = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXGroup", children: [AXNode(role: "AXButton"), AXNode(role: "AXButton")]),
                AXNode(role: "AXButton"),
            ])
        let r = ElementTable.render(tree)
        let lines = r.text.split(separator: "\n").map(String.init)
        #expect(
            lines == [
                "[AXWindow#1]", "  [AXGroup#2]", "    [AXButton#3]", "    [AXButton#4]", "  [AXButton#5]",
            ])
        #expect(r.total == 5 && r.shown == 5 && r.depth == 2)
    }

    @Test func attributesAppearInFixedOrderAndOmitWhenEmpty() {
        let n = AXNode(
            role: "AXButton", subrole: "AXCloseButton", title: "关闭", identifier: "close",
            value: "v", description: "d", enabled: false)
        #expect(
            ElementTable.line(n, handle: 7, depth: 1)
                == #"  [AXButton#7] "关闭" subrole=AXCloseButton desc="d" value="v" id="close" state=disabled"#)

        // 空字符串与 enabled=true/nil 都省略
        let plain = AXNode(role: "AXButton", title: "", identifier: "", value: "", description: "", enabled: true)
        #expect(ElementTable.line(plain, handle: 1, depth: 0) == "[AXButton#1]")
    }

    @Test func interactiveElementsGetLabelsAndFrames() {
        let tree = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXButton", title: "确定", frame: Rect(x: 10, y: 20, width: 80, height: 24)),
                AXNode(role: "AXStaticText", value: "说明", frame: Rect(x: 10, y: 50, width: 200, height: 18)),
                AXNode(role: "AXTextField", frame: Rect(x: 10, y: 80, width: 200, height: 24)),
            ])
        let r = ElementTable.render(tree)
        let lines = r.text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "[AXWindow#1]")
        #expect(lines[1].hasPrefix("  [a] [AXButton#2]"))
        #expect(lines[1].hasSuffix("frame=(10,20,80,24)"))
        // 静态文本不标；但它仍然带 frame，便于截图定位。
        #expect(!lines[2].contains("[a]") && lines[2].hasSuffix("frame=(10,50,200,18)"))
        #expect(lines[3].hasPrefix("  [b] [AXTextField#4]"))
        #expect(r.labels.map(\.text) == ["a", "b"])
        #expect(r.labels.map(\.handle) == [2, 4])
        #expect(r.labelTotal == 2)
    }

    @Test func labelsSkipDisabledAndZeroSizedElements() {
        let tree = AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXButton", title: "禁用", enabled: false, frame: Rect(x: 0, y: 0, width: 40, height: 20)),
                AXNode(role: "AXButton", title: "零宽", frame: Rect(x: 0, y: 30, width: 0, height: 20)),
                AXNode(role: "AXButton", title: "可用", frame: Rect(x: 0, y: 60, width: 40, height: 20)),
            ])
        let r = ElementTable.render(tree)
        #expect(r.labels.map(\.text) == ["a"])
        #expect(r.labels.first?.title == "可用")
        #expect(r.labelTotal == 1)
    }

    @Test func pressableGroupsAreLabeledButNotWhenTheyContainRoleTargets() {
        let sidebar = AXNode(
            role: "AXGroup", actions: ["AXPress"], frame: Rect(x: 0, y: 0, width: 160, height: 36),
            children: [AXNode(role: "AXStaticText", value: "推荐", frame: Rect(x: 20, y: 9, width: 28, height: 18))])
        let card = AXNode(
            role: "AXGroup", actions: ["AXPress"], frame: Rect(x: 200, y: 0, width: 200, height: 200),
            children: [
                AXNode(role: "AXButton", title: "播放", frame: Rect(x: 210, y: 10, width: 20, height: 20))
            ])
        let tree = AXNode(role: "AXWindow", children: [sidebar, card])
        let r = ElementTable.render(tree)
        #expect(r.labels.map(\.text) == ["a", "b"])
        #expect(r.labels.map(\.role) == ["AXGroup", "AXButton"])
        #expect(r.labels.map(\.handle) == [2, 5])
        let groupLine = r.text.split(separator: "\n").first { $0.contains("[AXGroup#2]") }
        #expect(groupLine?.contains("actions=[AXPress]") == true)
        // 外层卡片包含按钮时不重复标；只标卡片里的按钮。
        let cardLine = r.text.split(separator: "\n").first { $0.contains("[AXGroup#4]") }
        #expect(cardLine?.hasPrefix("  [AXGroup#4]") == true)
    }

    @Test func nestedPressableGroupsOnlyLabelTheOutermost() {
        let inner = AXNode(
            role: "AXGroup", actions: ["AXPress"], frame: Rect(x: 10, y: 10, width: 80, height: 30),
            children: [AXNode(role: "AXStaticText", value: "内层", frame: Rect(x: 20, y: 15, width: 40, height: 18))])
        let outer = AXNode(
            role: "AXGroup", actions: ["AXPress"], frame: Rect(x: 0, y: 0, width: 160, height: 60),
            children: [inner])
        let r = ElementTable.render(AXNode(role: "AXWindow", children: [outer]))
        #expect(r.labels.map(\.handle) == [2])
        #expect(r.labelTotal == 1)
    }

    @Test func labelCapKeepsTheRestAddressableByHandle() {
        let tree = AXNode(
            role: "AXGroup",
            children: (0..<(ElementTable.maxLabels + 5)).map { i in
                AXNode(role: "AXButton", title: "b\(i)", frame: Rect(x: 0, y: Double(i), width: 10, height: 10))
            })
        let r = ElementTable.render(tree, maxElements: ElementTable.maxLabels + 10)
        #expect(r.labels.count == ElementTable.maxLabels)
        #expect(r.labelTotal == ElementTable.maxLabels + 5)
        #expect(r.text.contains("[AXButton#\(ElementTable.maxLabels + 6)]"))
        // 第 301 个按钮之后不再有标签，但仍可用句柄寻址。
        let unlabeled = r.text.split(separator: "\n").first { $0.contains("[AXButton#302]") }
        #expect(unlabeled?.contains("] [AXButton#302]") == false)
    }

    @Test func frameCoordinatesAreRoundedForDisplay() {
        let n = AXNode(role: "AXButton", frame: Rect(x: 1.4, y: 2.6, width: 3.5, height: 4.4))
        #expect(ElementTable.line(n, handle: 1, depth: 0) == "[AXButton#1] frame=(1,3,4,4)")
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

    // MARK: - 层级优先

    /// 根 → [A（50 个叶子）, B, C]。先序截断会让 A 的叶子占满配额，看不到 B 与 C。
    static func bigFirstSubtree() -> AXNode {
        AXNode(
            role: "AXWindow",
            children: [
                AXNode(role: "AXGroup", title: "A", children: (0..<50).map { _ in AXNode(role: "AXButton") }),
                AXNode(role: "AXToolbar", title: "B"),
                AXNode(role: "AXGroup", title: "C"),
            ])
    }

    @Test func levelFirstShowsSiblingsBeforeDescendants() {
        let r = ElementTable.render(Self.bigFirstSubtree(), maxElements: 6)
        let lines = r.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 6 && r.shown == 6 && r.total == 54)
        // B、C 是第 1 层，必须可见；句柄按完整树先序编号（B 是 #53，C 是 #54），与是否显示无关。
        #expect(lines.contains { $0.contains("[AXToolbar#53]") })
        #expect(lines.contains { $0.contains("[AXGroup#54]") })
        // A 下的 50 个叶子只显示了 2 个，其余 48 个折叠，并在 A 行尾标出。
        let a = lines.first { $0.contains("[AXGroup#2]") }
        #expect(a?.hasSuffix("(折叠 48)") == true)
    }

    @Test func fullyFittingTreeHasNoCollapseMarkers() {
        let r = ElementTable.render(Self.bigFirstSubtree(), maxElements: 54)
        #expect(r.shown == 54 && !r.text.contains("折叠"))
    }

    @Test func collapsedCountMakesTheTotalAddUp() {
        for cap in [1, 2, 3, 10, 53] {
            let r = ElementTable.render(Self.bigFirstSubtree(), maxElements: cap)
            let root = r.text.split(separator: "\n").first.map(String.init) ?? ""
            let hidden = root.range(of: "(折叠 ").flatMap { Int(root[$0.upperBound...].dropLast()) } ?? 0
            #expect(r.shown + hidden == r.total && r.shown == cap, "cap=\(cap)")
        }
    }

    @Test func levelFirstRespectsCapAndKeepsParentsVisibleForArbitraryTrees() {
        var seed: UInt64 = 0xC0FFEE
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        func tree(_ depth: Int) -> AXNode {
            let kids = depth == 0 ? 0 : next(5)
            return AXNode(role: "AXGroup", children: (0..<kids).map { _ in tree(depth - 1) })
        }
        for _ in 0..<200 {
            let t = tree(5)
            let cap = 1 + next(40)
            let r = ElementTable.render(t, maxElements: cap)
            let lines = r.text.split(separator: "\n").map(String.init)
            #expect(r.shown == min(cap, r.total))
            #expect(lines.count == r.shown)
            // 缩进只会比前一行深一级：显示的元素一定带着它的祖先（父节点必已显示）。
            var prev = -1
            for l in lines {
                let indent = (l.prefix { $0 == " " }.count) / 2
                #expect(indent <= prev + 1)
                prev = indent
            }
        }
    }

    // MARK: - focus

    static func sample() -> AXNode {
        AXNode(
            role: "AXWindow", title: "主窗口",
            children: [
                AXNode(
                    role: "AXToolbar",
                    children: [
                        AXNode(role: "AXButton", description: "返回"),
                        AXNode(role: "AXButton", description: "前进"),
                    ]),
                AXNode(
                    role: "AXScrollArea",
                    children: [
                        AXNode(
                            role: "AXOutline", description: "边栏",
                            children: [
                                AXNode(role: "AXRow", children: [AXNode(role: "AXStaticText", value: "边栏项目一")]),
                                AXNode(
                                    role: "AXRow",
                                    children: [AXNode(role: "AXStaticText", identifier: "side-2", value: "项目二")]),
                            ])
                    ]),
            ])
    }

    @Test func focusTextMatchesAnyFieldCaseInsensitivelyAndShowsAncestorPath() {
        let r = ElementTable.render(Self.sample(), focus: .init(text: "SIDE-2"))
        #expect(r.matches == 1)
        let lines = r.text.split(separator: "\n").map(String.init)
        #expect(lines[0] == #"@ AXWindow "主窗口" > AXScrollArea > AXOutline "边栏" > AXRow"#)
        // 缩进相对命中的子树根，从 0 开始；句柄仍是完整树里的编号。
        #expect(lines[1] == #"[AXStaticText#10] value="项目二" id="side-2""#)
    }

    @Test func focusReturnsOutermostMatchOnlyAndExpandsItsWholeSubtree() {
        // "边栏" 同时命中 AXOutline（desc）与其内的 AXStaticText（value），只取最外层，子树整体展开。
        let r = ElementTable.render(Self.sample(), focus: .init(text: "边栏"))
        #expect(r.matches == 1)
        #expect(r.scope == 5 && r.shown == 5)
        #expect(r.text.contains("[AXOutline#"))
        #expect(r.text.contains("边栏项目一"))
    }

    @Test func focusRoleNormalizesAxPrefixAndCombinesWithText() {
        #expect(ElementTable.render(Self.sample(), focus: .init(role: "Button")).matches == 2)
        #expect(ElementTable.render(Self.sample(), focus: .init(role: "AXButton")).matches == 2)
        #expect(ElementTable.render(Self.sample(), focus: .init(text: "返回", role: "Button")).matches == 1)
        #expect(ElementTable.render(Self.sample(), focus: .init(text: "返回", role: "Row")).matches == 0)
    }

    @Test func focusWithNoMatchIsEmptyNotAnError() {
        let r = ElementTable.render(Self.sample(), focus: .init(text: "不存在"))
        #expect(r.matches == 0 && r.text.isEmpty && r.shown == 0 && r.total == 10)
    }

    @Test func focusHandlesAgreeWithTheUnfocusedTable() {
        let full = ElementTable.render(Self.sample()).text
        let part = ElementTable.render(Self.sample(), focus: .init(text: "前进")).text
        let handle = part.split(separator: "\n").last.flatMap { l in
            l.split(separator: "#").last?.split(separator: "]").first
        }
        #expect(handle != nil)
        #expect(full.contains("#\(handle ?? "")]") && full.contains("desc=\"前进\""))
    }

    @Test func focusExpandsAtMostTwentyMatchesButCountsAll() {
        let many = AXNode(role: "AXGroup", children: (0..<30).map { _ in AXNode(role: "AXButton", title: "x") })
        let r = ElementTable.render(many, focus: .init(role: "Button"))
        #expect(r.matches == 30)
        #expect(r.text.split(separator: "\n").filter { $0.hasPrefix("@") }.count == ElementTable.maxFocusMatches)
    }

    @Test func focusSharesTheCapAcrossMatchesLevelFirst() {
        let groups = AXNode(
            role: "AXWindow",
            children: (0..<3).map { i in
                AXNode(
                    role: "AXGroup", title: "g",
                    children: (0..<10).map { _ in AXNode(role: "AXButton", title: "b\(i)") })
            })
        let r = ElementTable.render(groups, maxElements: 6, focus: .init(text: "g", role: "Group"))
        #expect(r.matches == 3 && r.scope == 33 && r.shown == 6)
        // 3 个子树根都显示（第 0 层先放满），其余配额按先序分给下一层。
        #expect(r.text.split(separator: "\n").filter { $0.contains("[AXGroup#") }.count == 3)
    }
}
