@testable import FeatureExplore
import MoyeotaDesignSystem
import MoyeotaDomain
import Testing

/// 20 합류 확인이 **방 상태를 읽는지**.
///
/// 왜 테스트가 필요한가: 고치기 전의 화면은 `ride.status` 를 전혀 보지 않았다(배지가 문자열
/// 리터럴 「모집 중」이었고, `RideStatus` 는 Preview 에서만 쓰였다). 17 탐색 목록은 4초 주기라 방을
/// 고르는 사이에 마지막 멤버가 나가 방이 닫힐 수 있는데(`Party.leave` → `members.isEmpty()` →
/// `cancel()`), 그때 20 은 **「모집 중」 배지 + "0명 참여 · 목표 3명 · 내가 1번째" + 활성 CTA** 를
/// 그렸다. 누르면 409 `PARTY_CLOSED` 로만 사실을 알 수 있었다 — 그 **이전에** 거짓을 보여 주는 것이
/// 결함이라, 화면 없이 판정만 떼어 여기서 고정한다.
struct JoinGateTest {
    // ─── 상태 배지 ──────────────────────────────────────────────────────────

    @Test("모집 중인 방만 모집 중이라고 쓴다")
    func onlyRecruitingSaysRecruiting() {
        #expect(joinStatusBadge(status: .recruiting).text == "모집 중")
        #expect(joinStatusBadge(status: .recruiting).kind == NoticeKind.success)
    }

    /// 모집 중이 아닌 **모든** 단계가 다른 문구를 쓴다 — 하나라도 「모집 중」으로 새면 그 단계에서
    /// 다시 거짓을 말하게 된다. 단계가 늘어나면 `switch` 가 컴파일을 막고, 이 테스트가 문구를 묻는다.
    @Test("모집 중이 아닌 단계는 모집 중이라고 쓰지 않는다")
    func otherStagesDoNotSayRecruiting() {
        for status in RideStatus.allCases where status != .recruiting {
            let badge = joinStatusBadge(status: status)
            #expect(badge.text != "모집 중", "\(status) 가 「모집 중」으로 샜다")
            #expect(!badge.text.isBlank, "\(status) 배지 문구가 비었다")
        }
    }

    /// 취소된 방은 가장 센 색으로 — 다른 방을 골라야 한다는 뜻이다.
    @Test("취소된 방은 오류 색으로 표시한다")
    func canceledUsesErrorColor() {
        #expect(joinStatusBadge(status: .canceled).kind == NoticeKind.error)
    }

    // ─── 합류 가능 판정 ─────────────────────────────────────────────────────

    @Test("모집 중이고 자리가 있으면 합류할 수 있다")
    func recruitingWithSeatIsJoinable() {
        #expect(joinGate(status: .recruiting, joinedCount: 1, capacity: 3, iAmMember: false) == .joinable)
        #expect(joinGateMessage(gate: .joinable) == nil)
    }

    /// **이 테스트가 이 파일의 핵심이다.** 취소된 방은 멤버가 0명이라 정원만 보면 「자리 있음」으로
    /// 읽힌다 — 상태를 보지 않던 화면이 활성 CTA 를 그린 바로 그 경우다.
    @Test("취소된 방은 자리가 남아 보여도 막는다")
    func canceledIsBlockedEvenWithSeats() {
        let gate = joinGate(status: .canceled, joinedCount: 0, capacity: 3, iAmMember: false)

        #expect(gate == .notRecruiting)
        #expect(joinGateMessage(gate: gate) != nil, "막힌 이유를 말하지 않는다")
    }

    @Test("모집 중이 아닌 모든 단계에서 합류를 막는다")
    func allOtherStagesAreBlocked() {
        for status in RideStatus.allCases where status != .recruiting {
            #expect(
                joinGate(status: status, joinedCount: 0, capacity: 3, iAmMember: false) == .notRecruiting,
                "\(status) 에서 합류가 열려 있다"
            )
        }
    }

    /// 상태는 모집 중인데 목록이 낡아 자리가 없는 경우 — 고치기 전에도 막던 유일한 경우다.
    @Test("정원이 찼으면 막는다")
    func fullIsBlocked() {
        #expect(joinGate(status: .recruiting, joinedCount: 3, capacity: 3, iAmMember: false) == .full)
    }

    /// 내가 이미 멤버면 **합류가 아니다.** 서버 목록은 내 방을 빼지 않고(17 도 걸러내지 않는다)
    /// 「합류」 버튼도 활성이라, 내 방을 다시 여는 건 정상 경로다. 그때 합류를 시도해도 409 뿐이다.
    @Test("이미 참여 중이면 합류가 아니라 돌아가기다")
    func memberReturnsInsteadOfJoining() {
        #expect(joinGate(status: .recruiting, joinedCount: 1, capacity: 3, iAmMember: true) == .alreadyJoined)
    }

    /// 멤버 판정이 상태·정원보다 앞이다 — 내가 들어가 있는 방이 마감된 경우(MATCHED)가 흔하다.
    @Test("이미 참여 중인 방이 마감돼도 돌아가기다")
    func memberReturnsEvenWhenClosed() {
        #expect(joinGate(status: .matched, joinedCount: 3, capacity: 3, iAmMember: true) == .alreadyJoined)
    }

    // ─── 인원 문구 ──────────────────────────────────────────────────────────

    @Test("아직 멤버가 아니면 내가 다음 순서다")
    func nonMemberIsNextInLine() {
        #expect(joinHeadcountLine(joinedCount: 1, capacity: 3, iAmMember: false) == "1명 참여 · 목표 3명 · 내가 2번째")
    }

    /// **이미 멤버면 순서를 말하지 않는다.** `joinedCount` 는 방 상세의 멤버 수라 나를 포함하므로,
    /// 내 방을 열었을 때 +1 을 더하면 「1명 참여 · 내가 2번째」처럼 한 칸 밀린 거짓이 됐다
    /// (실제로는 내가 1번째다). 「내가 1번째」로 고쳐 쓰는 것도 답이 아니다 — 지금 새로 합류하는
    /// 것처럼 읽힌다.
    @Test("이미 멤버면 순서를 지어내지 않는다")
    func memberDoesNotInventOrder() {
        let line = joinHeadcountLine(joinedCount: 1, capacity: 3, iAmMember: true)

        #expect(line == "1명 참여 · 목표 3명 · 이미 참여 중")
        #expect(!line.contains("번째"), "내 방에서도 순서를 말했다")
    }
}
