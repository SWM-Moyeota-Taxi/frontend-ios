import Testing
@testable import FeatureChat

/// 검색 결과 본문에서 어느 구간을 강조하는가. 서버 LIKE 와 같은 규칙(부분 일치, 대소문자 무시)이어야 한다
@Suite struct KeywordRangesTest {

    @Test("나오는 자리 전부를 찾는다")
    func findsEveryOccurrence() {
        #expect(keywordRanges(text: "역에 역에", keyword: "역에") == [0...1, 3...4])
    }

    @Test("대소문자를 가리지 않는다")
    func ignoresCase() {
        #expect(keywordRanges(text: "Taxi 탑니다", keyword: "taxi") == [0...3])
    }

    @Test("겹치는 후보는 앞의 것만 잡는다")
    func overlapKeepsFirst() {
        #expect(keywordRanges(text: "aaa", keyword: "aa") == [0...1])
    }

    @Test("없으면 빈 목록")
    func noneIsEmpty() {
        #expect(keywordRanges(text: "부산역", keyword: "서면") == [])
        #expect(keywordRanges(text: "부산역", keyword: "") == [])
    }
}
