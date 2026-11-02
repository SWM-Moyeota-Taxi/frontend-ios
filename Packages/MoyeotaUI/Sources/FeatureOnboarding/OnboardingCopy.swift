/// 01~03 온보딩 세 장의 헤드라인·본문.
///
/// 화면 파일에서 끌어낸 이유는 **이 문구가 서비스가 하는 일의 고지**이기 때문이다. 온보딩은 가입 전에
/// 유일하게 "모여타가 무엇을 해 주는가"를 말하는 자리라, 여기서 없는 기능을 약속하면 사용자는 그 약속을
/// 믿고 가입한다. 상수로 두면 `ProductClaimsTest` 가 지워진 거짓 주장이 되살아나는 것을 막는다
/// (37 탈퇴 경고를 `AccountDeleteRulesTest` 가 막는 것과 같다).
///
/// **여기 적을 수 있는 것은 코드로 확인한 사실뿐이다.** 2026-10-13 기준으로 참인 것:
/// - 같은 방향 사람과 택시비를 나눈다 — 1인 부담 = 예상 요금 / 정원 (`Ride.farePerPerson`)
/// - 휴대폰 인증을 마쳐야 가입이 된다 — 서버가 `USER207 PHONE_NOT_VERIFIED` 로 거절한다
/// - 합류하는 순간 채팅방이 열린다 — 서버 `ChatRoomMatchingListener.on(PartyMemberJoinedEvent)`
/// - 함께 탈 사람의 탑승 횟수가 보인다 — 서버 `PartyDetailResult.MemberInfo.rideCount`
///
/// 2026-10-13 에 지운 거짓 주장과 그 근거는 원본 저장소의 `_workspace/127_compose-builder_false-claims.md` 에 있다.
/// 요약: 성별 조건 매칭·위치 공유·긴급 신고·요금 정산은 **없다**.
struct OnboardingPageCopy: Equatable, Sendable {
    var headline: String
    var body: String

    init(headline: String, body: String) {
        self.headline = headline
        self.body = body
    }
}

/// 01 절약 — 1/N 로 줄어드는 요금. 「9,600 → 3,200」 예시는 3인 기준이다.
let OnboardingSavingCopy = OnboardingPageCopy(
    headline: "택시비, 혼자 다 내지 마요",
    body: "같은 방향 사람과 나눠 타면\n요금이 1/N로 줄어요"
)

/// 02 신뢰 — 가입 문턱과 상대에 대해 알 수 있는 것.
///
/// 예전 본문은 「같은 성별끼리만 함께 타요」였다. **성별 조건 매칭은 없다** — 성별은 가입 때 받아
/// `UserProfile` 에 저장될 뿐이고 백엔드 `matching` 패키지에 성별이 한 번도 등장하지 않는다.
let OnboardingTrustCopy = OnboardingPageCopy(
    headline: "믿을 수 있는 사람과",
    body: "휴대폰 인증을 마친 사람만 가입하고\n함께 탈 사람의 탑승 횟수를 보여드려요"
)

/// 03 만남 — 합류 직후 열리는 채팅방.
///
/// 예전 본문은 「운행 중 긴급 신고가 바로 되고 / 요금은 인원수대로 나눠 안내해요」였다. 둘 다 거짓이다:
/// 긴급 신고(27)는 26 운행 중에서만 들어가는데 **동승 모드는 26 에 닿지 않고**(`docs/MODE-ROUTES.md`)
/// 서버도 `isRidingMember` 가 아니면 403 을 준다. 요금 정산 기능은 아예 없다(28~32 삭제).
let OnboardingMeetingCopy = OnboardingPageCopy(
    headline: "모이면, 채팅으로 만나요",
    body: "합류하는 순간 채팅방이 열려요\n어디서 만날지 서로 정하면 돼요"
)
