import Testing
@testable import FeatureChat

/// 채팅 목록 안읽음 배지 — 서버 unreadCount 를 어떻게 적는가. nil(개수 모름)은 점으로 떨어진다.
@Suite struct UnreadBadgeLabelTest {

    @Test("개수를 모르면 라벨이 없다 - 점 배지")
    func unknownCountHasNoLabel() {
        #expect(unreadBadgeLabel(count: nil) == nil)
    }

    @Test("0 이하는 그리지 않는다")
    func zeroOrLessHasNoLabel() {
        #expect(unreadBadgeLabel(count: 0) == nil)
        #expect(unreadBadgeLabel(count: -1) == nil)
    }

    @Test("두 자리까지는 그대로, 그 위는 99+")
    func cappedAtNinetyNine() {
        #expect(unreadBadgeLabel(count: 1) == "1")
        #expect(unreadBadgeLabel(count: 99) == "99")
        #expect(unreadBadgeLabel(count: 100) == "99+")
        #expect(unreadBadgeLabel(count: 1234) == "99+")
    }
}
