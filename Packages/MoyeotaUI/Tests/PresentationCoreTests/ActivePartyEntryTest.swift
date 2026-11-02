import MoyeotaDomain
import Testing
@testable import PresentationCore

/// 21 진입 한 번에 방 상세를 몇 번 읽는가(QA 119 D-2).
///
/// 진입 경로에는 같은 조회를 거는 곳이 여럿 있다 — `init`, 앱 재개 효과, 14·17 의 `refresh()`,
/// 그리고 합류·생성 직후의 `rememberParty`. 겹침만 막던 예전 플래그는 **순서대로** 들어오는 중복(몇십 ms 차)을
/// 그대로 통과시켰다.
///
/// 이 테스트가 보는 건 억제 **방향**이다. 「방금 끝난 조회」를 재사용해도 되는 쪽(화면 복귀)과
/// 절대 재사용하면 안 되는 쪽(합류·생성 — 직전 조회는 합류 이전의 사실이다)을 뒤섞으면,
/// 방금 들어간 방을 홀더가 못 보고 배너·채팅 헤더가 빈 채로 남는다.
@Suite struct ActivePartyEntryTest {
    private final class Clock {
        var now: Int64 = 0
    }

    private let clock = Clock()

    private func gate(windowMs: Int64 = 500) -> ResolveGate {
        let clock = self.clock
        return ResolveGate(windowMs: windowMs) { clock.now }
    }

    @Test("진행 중인 조회가 있으면 두 번째 재조회는 들어오지 못한다")
    func secondEntryBlockedWhileInFlight() {
        let gate = gate()

        #expect(gate.tryEnter())
        #expect(!gate.tryEnter(), "같은 조회가 날아가 있는데 또 걸었다")
    }

    @Test("방금 끝난 조회가 있으면 창 안에서는 들어오지 못한다")
    func blockedInsideWindow() {
        let gate = gate(windowMs: 500)

        #expect(gate.tryEnter())
        gate.leave()

        clock.now += 25 // QA 가 잰 실제 중복 간격
        #expect(!gate.tryEnter(), "25ms 뒤 같은 조회가 또 나갔다")

        clock.now += 400 // 합쳐서 425ms — 아직 창 안이다
        #expect(!gate.tryEnter())
    }

    @Test("창이 지나면 다시 조회한다")
    func entersAfterWindow() {
        let gate = gate(windowMs: 500)

        #expect(gate.tryEnter())
        gate.leave()

        clock.now += 500
        #expect(gate.tryEnter(), "창이 지났는데도 조회를 막았다 — 끝난 방이 배너에 남는다")
    }

    /// 조회 자체가 오래 걸려도 창은 **끝난 시각**부터 센다. 응답을 기다리는 동안은 겹침 규칙이 막는다.
    @Test("창은 조회가 끝난 시각부터 센다")
    func windowStartsAtFinish() {
        let gate = gate(windowMs: 500)

        #expect(gate.tryEnter())
        clock.now += 2_000 // 느린 응답
        gate.leave()

        #expect(!gate.tryEnter())
        clock.now += 500
        #expect(gate.tryEnter())
    }

    /// 실패한 조회도 창에 들어간다 — 같은 실패를 몇십 ms 뒤에 반복해 봐야 결과가 같다.
    @Test("실패한 조회도 창을 만든다")
    func failureAlsoOpensWindow() {
        let gate = gate(windowMs: 500)

        #expect(gate.tryEnter())
        gate.leave() // reload 가 던지든 nil 을 주든 닫힌다

        #expect(!gate.tryEnter())
    }

    /// 합류·방 생성 직후는 창을 무시한다. 직전 조회는 **합류 이전**의 사실이라,
    /// 재사용하면 방금 들어간 방을 홀더가 못 보고 14·17 배너와 24 채팅 헤더가 빈 채로 남는다.
    @Test("합류 직후의 조회는 창을 무시한다")
    func enterNowIgnoresWindow() {
        let gate = gate(windowMs: 500)

        #expect(gate.tryEnter())
        gate.leave()
        #expect(!gate.tryEnter(), "화면 복귀 쪽은 막혀야 한다")

        gate.enterNow() // rememberParty 경로 — 무조건 읽는다
        gate.leave()
    }

    /// 다만 그 조회도 끝난 시각을 남겨, 전이 도중 재구성으로 뒤따라 들어오는 refresh 는 흡수한다.
    @Test("합류 직후의 조회도 뒤따르는 재조회를 흡수한다")
    func enterNowAbsorbsFollowers() {
        let gate = gate(windowMs: 500)

        gate.enterNow()
        gate.leave()

        clock.now += 25
        #expect(!gate.tryEnter(), "합류 재조회 직후의 탭 진입이 같은 조회를 또 걸었다")
    }

    /// 홀더가 이미 그 방을 들고 있으면(서버가 「이미 이 방 멤버」라고 답해 합류 교착에서 복구된 경로)
    /// 상세를 다시 읽지 않는다 — 21 이 곧바로 자기 상세를 읽고, 배너가 보는 값은 이미 그 방이다.
    @Test("이미 들고 있는 방이면 합류 직후에도 상세를 읽지 않는다")
    func heldRoomNeedsNoDetail() {
        #expect(!needsDetailAfterRemember(held: ride(id: "7"), partyId: 7))
    }

    @Test("모르는 방이거나 홀더가 비어 있으면 읽는다")
    func unknownRoomNeedsDetail() {
        #expect(needsDetailAfterRemember(held: ride(id: "7"), partyId: 8), "다른 방인데 예전 방을 그대로 들고 있다")
        #expect(needsDetailAfterRemember(held: nil, partyId: 7), "홀더가 비어 있으면 읽어야 배너가 뜬다")
        // 서버가 준 적 없는 모양의 id 를 들고 있어도 같다 — 비교가 조용히 참이 되면 안 된다
        #expect(needsDetailAfterRemember(held: ride(id: "ride-7"), partyId: 7))
    }

    private func ride(id: String) -> Ride {
        Ride(
            id: id,
            origin: "성결대",
            destination: "안양역",
            departureLabel: "지금 출발",
            capacity: 4,
            members: [],
            farePerPerson: 2_000,
            totalFare: 8_000,
            status: .recruiting
        )
    }
}
