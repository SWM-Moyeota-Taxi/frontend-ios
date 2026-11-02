@testable import FeatureMatching
import MoyeotaDomain
import Testing

/// 21 「그만 찾기」·「방 나가기」의 실패 안내.
///
/// 예전에는 모든 실패가 「방에서 나가지 못했어요」 하나였다. 그게 특히 나쁜 까닭은 **이미 나간
/// 상태가 영구 실패로 보였다**는 것이다: 서버가 204 로 처리했는데 응답이 유실되면(터널·타임아웃)
/// 앱은 그 문구를 띄우고, 다시 누르면 403 `NOT_PARTY_MEMBER` → **같은 문구**다. 로컬 기억과 홈 배너는
/// 그 방을 계속 들고 있으니 화면상 나는 아직 그 방에 있고, 벗어날 길이 없다.
///
/// 그래서 **그 403 은 이 함수에 오지 않는다** — 데이터 계층이 성공으로 되돌려 나가기 성공과 같은
/// 길(홈)로 보낸다(`RemoteRideRepository.leaveParty`, 합류의 409 복구와 대칭). 여기 남는 것은
/// 「지금은 나갈 수 없다」와 「이미 사라진 방」뿐이고, 둘은 다음 행동이 다르다.
struct LeaveFailureMessageTest {
    private func failure(_ code: String?, httpStatus: Int? = 409) -> PartyLeaveException {
        PartyLeaveException(code: code, serverMessage: nil, httpStatus: httpStatus)
    }

    /// 409 — 매칭이 시작돼 서버가 막는다(`Party.ensureRecruiting`). **「잠시 후 다시」를 붙이지 않는다**:
    /// 방이 모집 단계로 되돌아가는 길이 없어 다시 눌러도 같은 409 다. 대신 **왜** 못 나가는지 말한다.
    @Test("모집 단계가 아니면 왜 못 나가는지 말한다")
    func notRecruiting() {
        let message = leaveFailureMessage(e: failure(PartyLeaveException.PARTY_NOT_RECRUITING))

        #expect(message == "매칭이 시작돼 지금은 나갈 수 없어요")
    }

    @Test("사라진 방 - 코드가 없는 404 도 같게 다룬다")
    func partyNotFound() {
        let expected = "이미 사라진 방이에요. 홈으로 돌아가 주세요"

        #expect(leaveFailureMessage(e: failure(PartyLeaveException.PARTY_NOT_FOUND, httpStatus: 404)) == expected)
        #expect(leaveFailureMessage(e: failure(nil, httpStatus: 404)) == expected)
    }

    /// 모르는 코드·네트워크 실패는 일반 문구다 — 서버가 `MatchingErrorCode` 를 늘려도 앱이 틀린 말을
    /// 하지 않는다(409 라고 「매칭이 시작됐어요」로 **추측하지 않는다**).
    @Test("모르는 코드와 네트워크 실패는 일반 문구로 떨어진다")
    func unknownCode() {
        let general = "방에서 나가지 못했어요"

        #expect(leaveFailureMessage(e: failure("PARTY_SOMETHING_NEW")) == general)
        #expect(leaveFailureMessage(e: failure(nil, httpStatus: nil)) == general)
        #expect(leaveFailureMessage(e: failure(nil, httpStatus: 409)) == general)
        #expect(leaveFailureMessage(e: failure(nil, httpStatus: 500)) == general)
    }

    /// **403 이 일반 문구로 떨어지는 것 자체는 괜찮다** — 거기까지 오지 않는 것이 계약이기 때문이다
    /// (데이터 계층이 성공으로 되돌린다). 혹시 되돌림이 빠져 올라오더라도 「매칭이 시작됐어요」 같은
    /// 거짓말은 하지 않는다는 것만 못 박는다.
    @Test("멤버 아님 403 은 사유를 지어내지 않는다")
    func notMember() {
        let message = leaveFailureMessage(e: failure(PartyLeaveException.NOT_PARTY_MEMBER, httpStatus: 403))

        #expect(message == "방에서 나가지 못했어요")
    }

    @Test("실패마다 다른 말을 한다")
    func distinctMessages() {
        let messages = [
            failure(PartyLeaveException.PARTY_NOT_RECRUITING),
            failure(PartyLeaveException.PARTY_NOT_FOUND, httpStatus: 404),
            failure(nil, httpStatus: nil),
        ].map { leaveFailureMessage(e: $0) }

        #expect(Set(messages).count == messages.count)
    }
}
