import Testing

@testable import SCUWire

/// 标题当窗口身份时的解析：0/1/≥2、去重、候选清单（T-019 第二批 §2.3 U1）。
@Suite struct WindowTitleMatchTests {
    private func resolve(
        _ elements: [Int], _ titles: [String?], _ title: String
    ) -> WindowTitleMatch.Resolution<Int> {
        WindowTitleMatch.resolve(elements: elements, titles: titles, matching: title, same: ==)
    }

    @Test func noMatchIsNotFound() {
        switch resolve([1, 2], ["甲", "乙"], "同名") {
        case .notFound: break
        default: Issue.record("0 个同名应是 notFound")
        }
    }

    @Test func oneMatchReturnsThatElement() {
        switch resolve([1, 2], ["同名", "其他"], "同名") {
        case .unique(let element): #expect(element == 1)
        default: Issue.record("1 个同名应是 unique")
        }
    }

    @Test func twoMatchesAreAmbiguous() {
        switch resolve([1, 2], ["同名", "同名"], "同名") {
        case .ambiguous(let count): #expect(count == 2)
        default: Issue.record("2 个同名应是 ambiguous")
        }
    }

    @Test func duplicateElementCountsOnce() {
        // AX 把同一个窗口返回两次，不是两个窗口。
        switch resolve([1, 1, 2], ["同名", "同名", "其他"], "同名") {
        case .unique(let element): #expect(element == 1)
        default: Issue.record("同一元素出现两次仍是 unique")
        }
    }

    @Test func ambiguityCountsOnlyMatchingTitles() {
        switch resolve([1, 2, 3, 4, 5], ["同名", "同名", "甲", "乙", "丙"], "同名") {
        case .ambiguous(let count): #expect(count == 2)
        default: Issue.record("只有同名的两个参与计数")
        }
    }

    @Test func matchingIsCaseSensitiveAndExact() {
        switch resolve([1], ["同名 "], "同名") {
        case .notFound: break
        default: Issue.record("标题严格相等，不做模糊匹配")
        }
    }

    @Test func candidateListSortsByVisualOrderAndCapsAtFive() {
        let candidates: [WindowTitleMatch.Candidate] = [
            .init(windowID: 3, frame: Rect(x: 0, y: 700, width: 80, height: 20)),
            .init(windowID: 1, frame: Rect(x: 0, y: 0, width: 80, height: 20)),
            .init(windowID: 2, frame: Rect(x: 900, y: 0, width: 80, height: 20)),
            .init(windowID: 4, frame: nil),
            .init(windowID: 5, frame: Rect(x: 0, y: 400, width: 80, height: 20)),
            .init(windowID: 6, frame: Rect(x: 500, y: 400, width: 80, height: 20)),
        ]
        let text = WindowTitleMatch.candidateList(candidates)
        #expect(text.hasPrefix("#1 (0,0,80,20)、#2 (900,0,80,20)、#5 (0,400,80,20)"))
        #expect(text.contains("#6 (500,400,80,20)、#3 (0,700,80,20)"))
        #expect(text.hasSuffix("、等 6 个"))
        #expect(text.contains("#4") == false)  // 超过 5 个不列；读不到 frame 的排最后
    }

    @Test func candidateListKeepsMissingWindowIDAsDash() {
        let text = WindowTitleMatch.candidateList([
            .init(windowID: nil, frame: Rect(x: 1, y: 2, width: 3, height: 4))
        ])
        #expect(text == "#- (1,2,3,4)")
    }
}
