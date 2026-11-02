@testable import FeatureMatching
import MoyeotaDomain
import PresentationCore
import Testing

/// 21 매칭 대기의 **방장 분기** — 「합승 완료」를 누구에게 보이고, 못 보는 사람에게 무엇을 말하고,
/// 멤버 목록에 배지를 누구에게 붙이는가.
///
/// 서버가 이 API 를 방장 전용으로 좁히고(Backend #237) 그게 운영에 배포된 뒤, 앱은 한동안 **전원에게**
/// 버튼을 보여 주고 있었다 — 비방장은 확인 다이얼로그까지 거친 끝에 403 `NOT_PARTY_HOST` 를 맞았다.
/// 노출을 고칠 근거는 서버가 멤버마다 `host` 를 내려 주기 시작하며 생겼다(Backend #240).
///
/// **여기서 지키는 것은 「추정하지 않는다」다.** 2026-08-30 에 지운 방장 로직은 앱이 `joinedAt`
/// 최소값으로 방장을 **추정**하던 것이었고(`_workspace/33_api-integrator_no_host.md`), 되살린 지금은
/// 서버 값만 본다. 그 구분이 무너지는 자리가 둘 있어 각각 못 박는다:
/// ① 매퍼의 fail-open 폴백(`host ?? isMe`)이 **내 줄만** true 로 만드는 것 → 배지에 쓰면 거짓이 된다
/// ② 안내문이 방장을 **이름으로** 부를 때 → 부를 수 없는 경우를 지어내면 거짓이 된다
struct WaitingHostNoticeTest {
    private func member(
        _ id: String,
        nickname: String? = nil,
        isMe: Bool = false,
        isHost: Bool = false
    ) -> User {
        User(
            id: id,
            nickname: nickname ?? "승객\(id)",
            verifiedLabel: "",
            rating: 0.0,
            rideCount: 0,
            isMe: isMe,
            isHost: isHost
        )
    }

    /// **탈퇴(soft delete) 모양** — 서버는 행을 지우지 않는다. `publicId` 는 **그대로 오고** 닉네임만
    /// 서버 상수로 가려진다(`user/users/domain/User` 의
    /// `return isDeleted() ? DELETED_DISPLAY_NAME : nickname`).
    ///
    /// 예전 헬퍼는 여기에 `id = ""` 를 넣어 **서버가 내지 않는 모양**을 만들고 있었다 — 그래서 빈 id
    /// 검사(`isWithdrawn`)에 걸려 테스트는 통과했지만, 실제 응답은 식별자가 살아 있어 그 검사를 그냥
    /// 통과했고 안내문에 「탈퇴한 사용자」가 찍혔다.
    private func softDeleted(id: String = "u2", isHost: Bool = false) -> User {
        member(id, nickname: WithdrawnMemberNames.SERVER_DELETED, isHost: isHost)
    }

    /// **요약이 없는 멤버** — 서버가 publicId·nickname 을 전부 null 로 주고 매퍼가 이렇게 접는다.
    private func noSummary(isHost: Bool = false) -> User {
        member("", nickname: WithdrawnMemberNames.NO_SUMMARY, isHost: isHost)
    }

    private func fullParty(_ members: [User]) -> Ride {
        Ride(
            id: "1",
            origin: "부산대",
            destination: "서면",
            departureLabel: "지금 출발",
            capacity: members.count,
            members: members,
            farePerPerson: 0,
            totalFare: 0,
            status: .matched // 서버 COMPLETED = 손으로 닫는 단계
        )
    }

    // ─── 노출 조건 ───────────────────────────────────────────────────────────

    @Test("방장에게는 합승 완료 버튼이 보인다")
    func hostSeesButton() {
        let ride = fullParty([member("me", isMe: true, isHost: true), member("u2")])

        #expect(canFinishParty(ride: ride, taxiEnabled: false))
    }

    /// **이 테스트가 이번 변경의 핵심이다.** 예전에는 여기서도 true 가 나와, 비방장이 확인
    /// 다이얼로그를 거친 뒤 403 을 맞았다.
    @Test("비방장에게는 합승 완료 버튼을 보이지 않는다")
    func nonHostDoesNotSeeButton() {
        let ride = fullParty([member("me", isMe: true), member("u2", isHost: true)])

        #expect(!canFinishParty(ride: ride, taxiEnabled: false))
        // 단계 자체는 그대로다 — 헤드라인·나가기 문구는 비방장에게도 「정원이 찼다」로 보여야 한다.
        #expect(isFinishStage(status: ride.status, taxiEnabled: false))
    }

    /// 내가 목록에 아예 없으면(식별자 없는 응답·요약 없는 멤버) 「내가 방장이다」라고 말해 주는 근거가
    /// 없다 — 그걸 「방장이 따로 있다」로 읽지 않더라도, **근거 없이 버튼을 주지는 않는다.**
    @Test("내가 목록에 없으면 버튼을 주지 않는다")
    func notInListNoButton() {
        let ride = fullParty([member("u1", isHost: true), member("u2")])

        #expect(!canFinishParty(ride: ride, taxiEnabled: false))
    }

    /// 매퍼의 fail-open 폴백(`host ?? isMe`)이 살아 있는 경로 — 옛 서버를 보고 있으면 내 줄만 true 다.
    /// 그때 **버튼은 보여야 한다**: 방장이 못 보면 방을 끝낼 길이 없어 30분 만료를 기다려야 하고,
    /// 아니었다면 서버 403 이 바로잡아 준다(`PartyMappers.toUser` 의 표).
    @Test("서버가 host 를 안 줘도 내 줄의 폴백은 버튼으로 이어진다")
    func fallbackShowsButton() {
        // 폴백 결과와 같은 모양: 내 줄만 isHost = true
        let ride = fullParty([member("me", isMe: true, isHost: true), member("u2"), member("u3")])

        #expect(canFinishParty(ride: ride, taxiEnabled: false))
    }

    // ─── 안내문 ──────────────────────────────────────────────────────────────

    @Test("방장을 알면 이름으로 부른다")
    func callsHostByName() {
        let ride = fullParty([member("me", isMe: true), member("u2", nickname: "부산가자", isHost: true)])

        #expect(
            finishHostNotice(hostNickname: ride.members.hostDisplayNameOrNull())
                == "다 타면 방장 부산가자님이 「합승 완료」를 눌러 방을 끝내요"
        )
    }

    /// ### 이름을 못 쓰는 경우 ① 방장이 **탈퇴했다**(soft delete) ★
    ///
    /// 서버 탈퇴는 행을 지우지 않는다 — `publicId` 는 살아 있고 닉네임만 「탈퇴한 사용자」로 가려진다.
    /// 그래서 빈 id 검사(`isWithdrawn`)로는 **걸러지지 않고**, 공백 검사로도 걸러지지 않는다(멀쩡한
    /// 문자열이다). 그대로 통과하면 안내문이 이렇게 된다 — 「다 타면 방장 **탈퇴한 사용자**님이
    /// 「합승 완료」를 눌러 방을 끝내요」. 그 사람은 **영원히 누를 수 없다**(방은 30분 만료로만 닫힌다).
    @Test("방장이 탈퇴했으면 이름을 쓰지 않는다 - publicId 는 살아 있다")
    func softDeletedHostNotNamed() {
        let ride = fullParty([member("me", isMe: true), softDeleted(isHost: true)])

        let notice = finishHostNotice(hostNickname: ride.members.hostDisplayNameOrNull())

        #expect(!notice.contains("탈퇴한 사용자"), "사람 이름이 아니다")
        #expect(notice == "다 타면 방장(가장 먼저 참여한 분)이 「합승 완료」를 눌러 방을 끝내요")
    }

    /// **배지는 그대로 붙는다.** 서버가 그를 방장이라고 말한 건 사실이고, 그 사실이 방이 왜 끝나지
    /// 않는지를 설명해 준다 — 막는 것은 **이름으로 부르는 것** 하나뿐이다. 그래서 이 한 경우에만
    /// 「배지가 붙는 사람」과 「안내문이 부르는 사람」이 갈린다.
    @Test("탈퇴한 방장에게도 방장 배지는 붙는다 - 이름만 쓰지 않는다")
    func softDeletedHostHasBadge() {
        let host = softDeleted(isHost: true)

        #expect(host.showsHostBadge, "서버가 방장이라고 말한 건 사실이다")
        #expect([host].hostDisplayNameOrNull() == nil, "그래도 이름으로 부를 수는 없다")
    }

    /// ### 이름을 못 쓰는 경우 ② 방장의 **유저 요약이 없다**
    ///
    /// 서버가 `MemberSummary` 를 못 만든 경우다 — publicId·nickname 이 전부 null 로 와서 매퍼가
    /// `id = ""` · 닉네임 「탈퇴한 회원」으로 접는다. 탈퇴와 **다른 경우**이고(식별자가 없다), 역시
    /// 공백 검사로는 걸러지지 않는다.
    @Test("방장의 요약이 없으면 이름을 쓰지 않는다")
    func noSummaryHostNotNamed() {
        let ride = fullParty([member("me", isMe: true), noSummary(isHost: true)])

        let notice = finishHostNotice(hostNickname: ride.members.hostDisplayNameOrNull())

        #expect(!notice.contains("탈퇴한 회원"), "사람 이름이 아니다")
        #expect(notice == "다 타면 방장(가장 먼저 참여한 분)이 「합승 완료」를 눌러 방을 끝내요")
    }

    /// 아무도 방장으로 지목되지 않은 목록 — 지어내지 않고 조건을 말한다.
    @Test("방장을 지목할 줄이 없으면 조건으로 말한다")
    func noHostRow() {
        let ride = fullParty([member("me", isMe: true), member("u2")])

        #expect(ride.members.hostDisplayNameOrNull() == nil)
        #expect(
            finishHostNotice(hostNickname: ride.members.hostDisplayNameOrNull())
                == "다 타면 방장(가장 먼저 참여한 분)이 「합승 완료」를 눌러 방을 끝내요"
        )
    }

    /// 안내문은 **두 가지를 말해야 한다**: 누가 끝내는지(방장), 그리고 그게 방을 끝내는 행동이라는 것.
    /// 하나라도 빠지면 버튼을 숨긴 자리가 「왜 내가 할 일이 없는지」를 설명하지 못한다.
    @Test("안내문은 누가 끝내는지와 방이 끝난다는 것을 말한다")
    func noticeSaysWhoAndWhat() {
        for notice in [finishHostNotice(hostNickname: "부산가자"), finishHostNotice(hostNickname: nil)] {
            #expect(notice.contains("방장"), "\(notice)")
            #expect(notice.contains("합승 완료"), "\(notice)")
            #expect(notice.contains("방을 끝내요"), "\(notice)")
        }
    }

    /// 지키지 못할 약속을 넣지 않는다(`ProductClaimsTest` 주석 — 거짓 문구 19건을 들어낸 이력).
    /// 여기서 특히 위험한 건 **기다리라는 말**이다: 기다려서 풀리는 일이 아니다. 방장이 누르거나,
    /// 방장이 나가 내게 승계되어야 바뀐다.
    @Test("안내문은 기다리거나 다시 시도하라고 말하지 않는다")
    func noticeMakesNoPromise() {
        for notice in [finishHostNotice(hostNickname: "부산가자"), finishHostNotice(hostNickname: nil)] {
            for forbidden in ["잠시 후", "다시 시도", "다시 눌러", "기다려", "곧 "] {
                #expect(!notice.contains(forbidden), "지키지 못할 약속이다: \(notice)")
            }
        }
    }

    /// 403 문구와 **같은 표현**을 쓴다 — 두 자리가 방장을 다르게 설명하면 사용자가 다른 사람을 찾는다.
    @Test("이름을 모를 때의 표현은 403 안내와 같은 근거를 쓴다")
    func sameWordingAs403() {
        #expect(finishHostNotice(hostNickname: nil).contains("가장 먼저 참여한"))
    }

    // ─── 배지 ────────────────────────────────────────────────────────────────

    @Test("서버가 방장이라고 말한 남의 줄에 배지가 붙는다")
    func badgeOnOthers() {
        #expect(member("u2", isHost: true).showsHostBadge)
        #expect(!member("u2").showsHostBadge)
    }

    /// **폴백 비대칭 때문에 내 줄에는 붙이지 않는다.** 매퍼가 `host ?? isMe` 로 접으므로 옛 서버에서는
    /// 내 줄만 true 가 되고, 그걸 그대로 그리면 비방장이 자기 줄에서 「방장」을 읽는다 — 버튼의 거짓은
    /// 눌렀을 때 서버 403 이 바로잡지만 배지의 거짓은 **아무도 바로잡지 않는다.** 게다가 그 403 문구
    /// (「방장만 합승을 완료할 수 있어요」)와 정면으로 모순되는 화면이 된다.
    @Test("내 줄에는 방장 배지를 붙이지 않는다 - 폴백이 만든 true 일 수 있다")
    func noBadgeOnMine() {
        #expect(!member("me", isMe: true, isHost: true).showsHostBadge)
    }

    /// 배지와 안내문이 **같은 사람**을 가리킨다 — 판정이 갈리면 화면이 서로 다른 말을 한다.
    /// (갈리는 경우는 이름을 쓸 수 없을 때 하나뿐이고, 그때 안내문은 **아무도 부르지 않는다**.)
    @Test("배지가 붙는 사람과 안내문이 부르는 사람이 같다")
    func badgeAndNoticeAgree() {
        let members = [member("me", isMe: true), member("u2", nickname: "부산가자", isHost: true)]

        #expect(members.filter { $0.showsHostBadge }.map(\.nickname) == ["부산가자"])
        #expect(members.hostDisplayNameOrNull() == "부산가자")
    }
}
