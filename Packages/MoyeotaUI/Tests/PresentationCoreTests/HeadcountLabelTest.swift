import Testing
@testable import PresentationCore

/// 16 「걸어서 가까운 방」 카드와 **17 탐색 카드·지도 마커 캡션**이 함께 쓰는 인원 문구.
///
/// **카드에서 가장 중요한 숫자다.** 2/3 방은 내가 들어가면 바로 출발하고 1/3 방은 한 명을 더
/// 기다려야 한다 — 정원만 보여 주면 그 둘이 똑같아 보여서, 걸어서 3분인 1/3 방을 고르고 한참
/// 기다리는 일이 생긴다.
@Suite struct HeadcountLabelTest {
    /// 17 탐색 카드와 같은 모양이다 — 같은 숫자를 두 화면이 다르게 쓰면 사용자가 헷갈린다.
    @Test("참여 인원과 정원을 함께 쓴다")
    func joinedAndCapacity() {
        #expect(headcountLabel(joined: 2, capacity: 3) == "2/3명")
        #expect(headcountLabel(joined: 1, capacity: 4) == "1/4명")
    }

    /// **0 은 「빈 방」이 아니라 「모른다」다.** 서버가 `currentMembers` 를 안 주는 옛 배포를 보고
    /// 있을 때만 0 이 되는데, 후보는 모집 중인 방만 오고 거기엔 최소 방장 1명이 있으므로 0명인
    /// 방은 존재할 수 없다. 모를 때 「0/3명」을 쓰면 빈 방이 있다고 거짓말하는 셈이다.
    @Test("인원을 모르면 정원만 쓴다")
    func unknownJoined() {
        #expect(headcountLabel(joined: 0, capacity: 3) == "최대 3명")
        #expect(headcountLabel(joined: -1, capacity: 3) == "최대 3명")
    }

    /// 정원까지 없으면 **줄 자체를 지운다** — 「최대 0명」은 사용자에게 아무 뜻도 없다.
    @Test("정원이 없으면 빈 문자열이다")
    func noCapacity() {
        #expect(headcountLabel(joined: 0, capacity: 0) == "")
        #expect(headcountLabel(joined: 2, capacity: 0) == "")
    }

    /// 정원이 찬 방은 후보에 오지 않는다(서버가 `status = 'ACTIVE'` 로 거른다). 그래도 경합으로
    /// 스쳐 오면 **있는 그대로 3/3 을 보여 준다** — 감추면 탭했을 때 「마감」이 뜬 이유를 모른다.
    @Test("정원이 찬 방도 숫자를 그대로 쓴다")
    func fullRoom() {
        #expect(headcountLabel(joined: 3, capacity: 3) == "3/3명")
    }
}
