@testable import FeatureExplore
import MoyeotaDomain
import Testing

/// 17 탐색 목록에서 **내가 이미 참여 중인 방**을 빼는 판정.
///
/// 왜 거르는가: 서버 목록은 내 방을 빼지 않아서 내가 속한 방이 남의 방과 **똑같은 「합류」 카드**로
/// 섞여 보였다. 그 카드는 거짓말을 한다 — 「합류」가 활성이고 인원 배지는 내가 들어가기 **전**의
/// 수처럼 읽힌다. 눌러 20 에 가면 `joinGate` 가 `ALREADY_JOINED` 로 받아 「방으로 돌아가기」를
/// 주므로 막힌 길은 아니지만, **같은 화면 맨 위의 진행 중 방 배너**가 한 번 눌러 21/25/26 으로
/// 바로 가는 더 짧고 정확한 길이다. 돌아갈 길이 이미 있으니 그 카드는 소음이다.
///
/// 이 테스트가 잡는 것:
/// - 내 방이 목록에 남는 회귀(= 거르기가 풀린 경우)
/// - **남의 방이 함께 사라지는** 사고(id 비교가 느슨해지면 생긴다)
/// - 빈 목록 문구의 근거(`ExploreList.myPartyHidden`)가 **거른 실적이 있을 때만** 켜지는지 —
///   늘 켜지면 방이 원래 없던 동네에서 「지금은 내 방뿐이에요」라는 거짓말을 한다
/// - 숫자 id 의 문자열 모양이 어긋났을 때(목록 `partyId` ↔ 상세 `id`) 비교가 깨지지 않는지
///
/// 볼 수 없는 것: 지도 마커가 실제로 함께 사라지는지. 마커와 카드가 `ExploreScreen` 의 `parties`
/// **한 파라미터**에서 나오는 구조라 소스로는 함께 움직이지만, 눈으로는 실기에서만 확인된다.
struct ExploreListFilterTest {
    private func ride(_ id: String) -> Ride {
        Ride(
            id: id,
            origin: "부산대 정문",
            destination: "서면역",
            departureLabel: "",
            capacity: 3,
            members: [User(id: "m0", nickname: "멤버 1", verifiedLabel: "", rating: 0.0, rideCount: 0)],
            farePerPerson: 0,
            totalFare: 0,
            status: .recruiting
        )
    }

    /// 내 방 하나만 빠지고 나머지는 **순서까지** 그대로다(서버가 준 순서를 다시 정렬하지 않는다).
    @Test("내 방만 빠진다")
    func onlyMyPartyIsRemoved() {
        let result = exploreList(parties: [ride("11"), ride("22"), ride("33")], myPartyId: "22")
        #expect(result.parties.map(\.id) == ["11", "33"])
        #expect(result.myPartyHidden)
    }

    /// 진행 중인 방이 없으면(미참여) 목록을 **그대로 통과**시킨다.
    @Test("참여 중인 방이 없으면 그대로다")
    func noActivePartyPassesThrough() {
        let parties = [ride("11"), ride("22")]
        let result = exploreList(parties: parties, myPartyId: nil)
        #expect(result.parties == parties)
        #expect(!result.myPartyHidden)
    }

    /// 내 방이 **이 범위에 없으면**(다른 동네를 보고 있다) 아무것도 빼지 않고 플래그도 켜지지 않는다.
    /// 여기서 플래그가 켜지면 방이 원래 없던 동네에서 「지금은 내 방뿐이에요」가 뜬다 — 거짓말이다.
    @Test("내 방이 이 범위에 없으면 플래그가 꺼진다")
    func myPartyOutsideBounds() {
        let result = exploreList(parties: [ride("11"), ride("22")], myPartyId: "99")
        #expect(result.parties.count == 2)
        #expect(!result.myPartyHidden, "이 범위에서 아무것도 안 걸렀는데 플래그가 켜졌다")
    }

    /// 빈 목록도 마찬가지다 — 걸러낼 것이 없으면 플래그는 꺼진 채다.
    @Test("빈 목록에서는 플래그가 꺼진다")
    func emptyListKeepsFlagOff() {
        let result = exploreList(parties: [], myPartyId: "22")
        #expect(result.parties.isEmpty)
        #expect(!result.myPartyHidden)
    }

    /// **주변에 내 방뿐인 경우** — 이 상황 하나 때문에 빈 상태 문구를 갈랐다. 목록은 0건이지만
    /// 「이 근처엔 동승이 없어요」는 거짓이다(방은 있고, 그게 내 방이다).
    @Test("내 방뿐이면 목록이 비고 플래그가 켜진다")
    func onlyMyPartyEmptiesList() {
        let result = exploreList(parties: [ride("22")], myPartyId: "22")
        #expect(result.parties.isEmpty)
        #expect(result.myPartyHidden, "빈 목록 문구를 가를 근거가 꺼져 있다")
    }

    /// 숫자 id 는 **숫자로** 비교한다. 두 값은 서로 다른 응답에서 오고(목록 `partyId`, 상세 `id`)
    /// 문자열 모양이 어긋날 수 있다 — `needsDetailAfterRemember` 가 같은 이유로 숫자 비교를 쓴다.
    @Test("숫자 id 는 문자열 모양이 달라도 같은 방이다")
    func numericIdsCompareAsNumbers() {
        // 운영에서 두 값은 모두 숫자를 문자열로 옮긴 것이라 지금은 모양이 같다. 그래도 숫자로 비교하는
        // 건 방어다 — 한쪽 경로가 바뀌어도(앞자리 0·부호) 내 방이 조용히 다시 새지 않는다.
        #expect(exploreList(parties: [ride("22")], myPartyId: "022").myPartyHidden)
        #expect(exploreList(parties: [ride("022")], myPartyId: "22").myPartyHidden)
    }

    /// **남의 방은 절대 사라지지 않는다.** 이 테스트가 깨지는 쪽이 더 위험하다 — 거르기가 풀리면
    /// 예전처럼 카드 하나가 더 보일 뿐이지만, 비교가 느슨해지면 합류할 수 있는 방이 지도에서
    /// 사라져 사용자가 찾을 길이 없다.
    @Test("비슷한 id 의 남의 방은 남는다")
    func similarIdsRemain() {
        let parties = [ride("2"), ride("22"), ride("220"), ride("222")]
        let result = exploreList(parties: parties, myPartyId: "22")
        #expect(result.parties.map(\.id) == ["2", "220", "222"])
    }

    /// 빈 문자열 id 는 「모른다」다 — 그걸로 아무 방도 지우지 않는다.
    @Test("빈 id 로는 아무것도 지우지 않는다")
    func blankIdRemovesNothing() {
        let result = exploreList(parties: [ride("11"), ride("22")], myPartyId: "")
        #expect(result.parties.count == 2)
        #expect(!result.myPartyHidden)
        // 목록 쪽 id 가 빈 값인 방도 빈 id 와 짝지어지지 않는다
        #expect(exploreList(parties: [ride("")], myPartyId: "").parties.count == 1)
    }

    /// 숫자로 읽히지 않는 id 는 문자열로 비교한다.
    /// 숫자 id 와 문자열 id 가 섞여도 서로를 같은 방으로 보지 않는다.
    @Test("숫자가 아닌 id 는 문자열로 비교한다")
    func nonNumericIdsCompareAsStrings() {
        #expect(exploreList(parties: [ride("ride-1")], myPartyId: "ride-1").myPartyHidden)
        #expect(!exploreList(parties: [ride("ride-1")], myPartyId: "ride-2").myPartyHidden)
        #expect(!exploreList(parties: [ride("ride-1")], myPartyId: "1").myPartyHidden)
    }

    /// **목록 데이터로는 `isMe` 판정이 불가능하다**는 사실을 못 박는다 — 거르기 기준을
    /// `members.contains { $0.isMe }` 로 바꾸려는 시도를 여기서 막는다. 목록 응답에는 멤버 식별자가
    /// 없어 매퍼가 자리 표시용 멤버를 만들고(`PartyMappers.placeholderMembers`) 그 멤버의
    /// `User.isMe` 는 **항상 false** 다.
    @Test("목록의 멤버로는 나를 찾을 수 없다")
    func listMembersCannotIdentifyMe() {
        let fromList = ride("22") // 자리 표시용 멤버 = publicId 없음 = isMe false
        #expect(
            !fromList.members.contains { $0.isMe },
            "목록 멤버로 isMe 를 판정할 수 있다고 믿으면 거르기가 조용히 꺼진다"
        )
        // 그래서 기준은 activeRide 의 id 하나다
        #expect(exploreList(parties: [fromList], myPartyId: "22").myPartyHidden)
    }
}
