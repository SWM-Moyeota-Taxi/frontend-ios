import Testing
@testable import FeatureHome

/// 16 도착지 확인의 **「1명」 안내**.
///
/// 왜 테스트가 필요한가: 「인원(나 포함)」 칩은 1/2/3 이고 1 은 **의도적으로 남긴** 선택지다
/// (혼자 타기를 상품으로 인정한 결정). 그 결정이 성립하는 조건은 하나뿐이다 — 1 을 고르면 만든
/// 즉시 꽉 찬 방이 되어 아무도 합류하지 못한다는 사실을 **고르는 자리에서** 말해 주는 것.
/// 안내가 없으면 「1명」은 「나 외 1명」처럼 읽히고, 사용자는 「같이 탈 사람 찾기」를 눌렀는데
/// 혼자 출발한다.
///
/// 이 테스트가 잡는 것:
/// - 안내가 **1에서만** 뜬다(2·3 에서 남으면 늘 켜진 경고가 되고, 1 에서 사라지면 원래 결함으로 돌아간다)
/// - 문구가 「동승자를 받지 않는다」와 「혼자 출발한다」 **둘 다** 말한다(하나만 말하면 나머지를 추측하게 된다)
/// - 내부 용어(정원·1/1·꽉 찬 방)가 새지 않는다
///
/// 화면 배치(칩 행 **아래**, `GrayMute` 13pt, 빨강·아이콘 없음)는 여기서 볼 수 없다 — 그쪽은 실기로 본다.
@Suite struct SoloCapacityNoticeTest {

    /// 1명을 고른 순간에만 뜬다.
    @Test("1명을 고르면 안내가 있다")
    func noticeForOne() {
        #expect(soloCapacityNotice(capacity: 1) != nil)
    }

    /// 2·3명에서는 **사라진다.** 정원 2 이상이면 실제로 동승자를 받으므로 이 안내는 틀린 말이 된다.
    @Test("2명 이상이면 안내가 없다")
    func noNoticeForTwoOrMore() {
        #expect(soloCapacityNotice(capacity: 2) == nil)
        #expect(soloCapacityNotice(capacity: 3) == nil)
    }

    /// 칩에 없는 값(0·음수·4 이상)도 nil 이다 — 「1이 아니면 없다」가 규칙이고, 그래야 나중에
    /// 칩이 4명까지 늘어도 이 안내가 엉뚱한 자리에 붙지 않는다.
    @Test("칩에 없는 값에는 안내가 없다")
    func noNoticeOutsideChips() {
        #expect(soloCapacityNotice(capacity: 0) == nil)
        #expect(soloCapacityNotice(capacity: -1) == nil)
        #expect(soloCapacityNotice(capacity: 4) == nil)
    }

    /// 문구가 **두 가지를 다 말한다.** 「혼자 출발」만 쓰면 「그래도 누군가 들어올 수 있나?」가 남고,
    /// 「받지 않는다」만 쓰면 그래서 어떻게 되는지(그대로 출발)가 안 보인다.
    @Test("동승자를 받지 않는다와 혼자 출발한다를 함께 말한다")
    func saysBoth() throws {
        let notice = try #require(soloCapacityNotice(capacity: 1))
        #expect(notice.contains("받지 않"), "「받지 않는다」가 없다: \(notice)")
        #expect(notice.contains("혼자 출발"), "「혼자 출발」이 없다: \(notice)")
    }

    /// **사용자 말로 쓴다.** 서버 규약 용어가 새면(정원·1/1·capacity) 그 말을 아는 사람만 읽을 수
    /// 있는 안내가 된다 — 안내를 붙인 이유가 사라진다.
    @Test("내부 용어를 쓰지 않는다")
    func noInternalTerms() throws {
        let notice = try #require(soloCapacityNotice(capacity: 1))
        for banned in ["정원", "1/1", "capacity", "꽉"] {
            #expect(!notice.contains(banned), "내부 용어 「\(banned)」가 새어 있다: \(notice)")
        }
    }

    /// 화면 CTA 와 **같은 단어**를 쓴다. CTA 가 「같이 탈 사람 찾기」인데 안내가 「동승자」라고 쓰면
    /// 같은 대상인지 한 번 더 생각해야 한다(이 파일의 다른 문구들도 같은 규칙을 지킨다).
    @Test("CTA 와 같은 말을 쓴다")
    func sameWordAsCta() throws {
        let notice = try #require(soloCapacityNotice(capacity: 1))
        #expect(notice.contains("같이 탈 사람"), "「같이 탈 사람」이 없다: \(notice)")
    }

    /// 1명일 때 **1인 요금 = 총 요금**이라는 것 — 안내와 요금 표시가 모순되지 않는다는 근거다.
    /// 칩은 「총 7,900원」, 푸터는 「예상 요금 1인 7,900원」이 되고, 그건 혼자 타는 방의 사실이다.
    /// 그래서 안내는 요금을 다시 말하지 않는다(`soloCapacityNotice` 설명).
    @Test("1명이면 1인 요금이 총 요금과 같다")
    func soloFareIsTotal() {
        #expect(farePerPersonWon(totalFare: 7_900, people: 1) == 7_900)
        #expect(farePerPersonWon(totalFare: 12_340, people: 1) == 12_340)
        // 2명 이상에서는 나뉘므로 같은 안내를 쓸 수 없다(= 안내가 1에서만 뜨는 또 하나의 이유)
        #expect(farePerPersonWon(totalFare: 7_900, people: 2) == 3_950)
    }
}
