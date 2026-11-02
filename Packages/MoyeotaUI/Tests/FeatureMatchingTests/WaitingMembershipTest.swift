@testable import FeatureMatching
import MoyeotaDomain
import Testing

/// 21 대기 화면이 **「나는 이 방 멤버가 아니다」를 알아채는지** — 유령 대기방 회귀 방지.
///
/// 멤버십을 알려 주는 창구는 **SSE 403 `NOT_PARTY_MEMBER` 하나뿐이다.**
/// `GET /matching/rooms/{partyId}`(방 상세)에는 참여자 검사가 **없어** 멤버가 아니어도 조회가 계속
/// 성공하기 때문이다(서버 `PartySseController` 는 그 403 을 `@ApiResponse` 로 계약 문서화해 두었다).
///
/// 그 403 을 「스트림이 끝났다」와 똑같이 뭉개면 이렇게 된다:
/// 1. 폴백 판정이 `READ_NOW` 라 **6초마다 방 상세를 영원히** 읽는다.
/// 2. 화면은 **내가 들어 있지 않은 방**을 「같이 탈 사람을 찾고 있어요」로 보여 준다.
/// 3. 인원 문구가 자기모순을 말한다 — 내가 없으니 「나 외 N명」이 전체 인원과 같아진다.
/// 4. 거기서 「그만 찾기」를 누르면 다시 403 이라 **벗어날 길이 없다.**
///
/// 그래서 고정하는 것은 셋이다: **403 이 스트림 종료와 다르게 다뤄지는가**(폴백이 멈추는가),
/// **상세만 보고도 알아채는가**(SSE 가 붙지 않는 망 대비), **인원 문구가 모순을 말하지 않는가.**
struct WaitingMembershipTest {
    private func user(_ id: String, isMe: Bool = false) -> User {
        User(id: id, nickname: "승객\(id)", verifiedLabel: "", rating: 0.0, rideCount: 0, isMe: isMe)
    }

    private func ride(_ members: [User], status: RideStatus = .recruiting) -> Ride {
        Ride(
            id: "1",
            origin: "부산대",
            destination: "서면",
            departureLabel: "지금 출발",
            capacity: 3,
            members: members,
            farePerPerson: 0,
            totalFare: 0,
            status: status
        )
    }

    private var me: User { user("me", isMe: true) }

    // ─── 폴백 게이트: 403 은 스트림 종료와 다르게 다뤄진다 ──────────────────

    /// **이 테스트가 결함의 본체다.** 둘은 403 에서 **같은 순간에** 서는데, 뜻이 달라 판정도 달라야 한다:
    /// 「스트림이 끝났다」는 "폴백이 유일한 갱신 수단이니 지금 읽어라"(READ_NOW)고,
    /// 「내가 멤버가 아니다」는 "읽어도 남의 방이다"(STOP)다.
    @Test("폴백 - 멤버십 상실은 멈추고 스트림 종료는 즉시 읽는다")
    func lostStopsEndedReads() {
        let ended = fallbackPollStep(
            visible: true,
            partyClosed: false,
            fallbackDone: false,
            streamEnded: true,
            membershipLost: false
        )
        let lost = fallbackPollStep(
            visible: true,
            partyClosed: false,
            fallbackDone: false,
            streamEnded: true,
            membershipLost: true
        )

        #expect(ended == .readNow)
        #expect(lost == .stop, "내가 없는 방을 6초마다 영원히 읽는다")
    }

    /// 상실은 「끝났다」는 사실이라 **다른 조건이 뭐든** 멈춘다 — 복귀로도 되살아나지 않는다.
    @Test("폴백 - 멤버십 상실은 어떤 조합에서도 멈춘다")
    func lostAlwaysStops() {
        for closed in [false, true] {
            for done in [false, true] {
                for ended in [false, true] {
                    #expect(
                        fallbackPollStep(
                            visible: true,
                            partyClosed: closed,
                            fallbackDone: done,
                            streamEnded: ended,
                            membershipLost: true
                        ) == .stop,
                        "멤버가 아닌 방에서 폴백이 돌았다 (closed=\(closed), done=\(done), ended=\(ended))"
                    )
                }
            }
        }
    }

    /// 기본값은 「상실 아님」이다 — 이 인자가 붙기 전의 판정이 그대로 유지돼야 한다.
    @Test("폴백 - 멤버십을 잃지 않았으면 예전 판정 그대로다")
    func defaultNotLost() {
        #expect(fallbackPollStep(visible: true, partyClosed: false, fallbackDone: false, streamEnded: false) == .waitThenRead)
        #expect(fallbackPollStep(visible: true, partyClosed: false, fallbackDone: false, streamEnded: true) == .readNow)
        #expect(fallbackPollStep(visible: false, partyClosed: false, fallbackDone: false, streamEnded: false) == .stop)
    }

    // ─── 상세만 보고 알아채는 2차 방어선 ──────────────────────────────────

    /// 전에는 목록에 있었는데 지금은 없다 — 그게 상실의 정의다(내가 나갔거나, 서버가 뺐다).
    @Test("나를 본 적이 있는데 목록에서 사라졌으면 멤버십을 잃었다")
    func sawThenGone() {
        #expect(hasLostMembership(sawMyself: true, ride: ride([user("u1"), user("u2")])))
    }

    @Test("목록에 내가 있으면 상실이 아니다")
    func stillInList() {
        #expect(!hasLostMembership(sawMyself: true, ride: ride([me, user("u1")])))
    }

    /// **이 가드가 없으면 멀쩡히 방에 들어 있는 사용자를 쫓아낸다.** `isMe` 는
    /// `publicId == 세션 uuid` 비교라, 세션 uuid 가 없으면(미로그인·복원 전) 아무도 나로 표시되지 않아
    /// 정상인 방에서도 「목록에 내가 없다」가 참이 된다. 그래서 **나를 한 번이라도 본 뒤에만** 판정한다.
    @Test("나를 본 적이 없으면 판정하지 않는다 - 내가 누군지 모르는 경우다")
    func neverSawMyself() {
        #expect(!hasLostMembership(sawMyself: false, ride: ride([user("u1"), user("u2")])))
        // 목록·생성 응답으로 만든 Ride(자리 표시용 멤버, publicId 없음)도 같은 자리로 떨어진다.
        #expect(!hasLostMembership(sawMyself: false, ride: ride([user("m0")])))
    }

    /// 멤버가 0명인 방은 **있을 수 없다**(마지막 멤버가 나가면 서버가 방을 닫는다). 빈 목록은 응답이
    /// 이상하다는 뜻이라 판정 근거가 되지 못한다 — 그걸로 화면을 떠나게 하면 안 된다.
    @Test("빈 목록으로는 판정하지 않는다")
    func emptyList() {
        #expect(!hasLostMembership(sawMyself: true, ride: ride([])))
    }

    /// **status 는 보지 않는다.** 내가 멤버가 아니라는 사실은 방이 어느 단계인지와 무관하고,
    /// ACTIVE 유령 방이 바로 이 결함의 본체였다(닫힌 방은 `PartyEvent.closed` 가 이미 잡는다).
    @Test("단계와 무관하게 판정한다")
    func anyStage() {
        for status in [RideStatus.recruiting, .matched, .dispatching] {
            #expect(
                hasLostMembership(sawMyself: true, ride: ride([user("u1")], status: status)),
                "status=\(status) 에서 상실을 놓쳤다"
            )
        }
    }

    // ─── 인원 문구가 모순을 말하지 않는다 ────────────────────────────────

    /// 내가 목록에 없으면 「나를 뺀 인원」이 전체 인원과 같아져 화면이
    /// **「지금 같은 방향 2명(나 외 2명)」** 이라는 자기모순을 그렸다. 0 이면 호출부가 괄호 없는
    /// 문구를 쓴다 — **문구 포맷 자체는 건드리지 않았다**(모르는 값을 말하지 않을 뿐이다).
    @Test("내가 멤버가 아니면 나를 뺀 인원을 세지 않는다")
    func notMemberNoCount() {
        #expect(otherMemberCount(ride: ride([user("u1"), user("u2")])) == 0)
    }

    @Test("내가 멤버면 나를 뺀 인원을 센다")
    func memberCounts() {
        #expect(otherMemberCount(ride: ride([me])) == 0)
        #expect(otherMemberCount(ride: ride([me, user("u1")])) == 1)
        #expect(otherMemberCount(ride: ride([me, user("u1"), user("u2")])) == 2)
    }

    /// 식별자가 없는 목록(목록·생성 응답의 자리 표시용 멤버)도 같다 — 모르면 말하지 않는다.
    @Test("식별자 없는 목록에서는 세지 않는다")
    func noIdentityNoCount() {
        #expect(otherMemberCount(ride: ride([user("m0"), user("m1")])) == 0)
        #expect(otherMemberCount(ride: ride([])) == 0)
    }
}
