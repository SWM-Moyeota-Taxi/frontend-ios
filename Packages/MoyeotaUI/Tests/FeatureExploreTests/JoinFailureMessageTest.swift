@testable import FeatureExplore
import MoyeotaDomain
import Testing

/// 20 합류 확인의 실패 안내.
///
/// 실패마다 **다음 행동이 다르다** — 가득 찬 방은 다른 방을 고르면 되고, 다른 방에 참여 중이면 그 방을
/// 먼저 정리해야 하고, 네트워크면 그냥 다시 누르면 된다. 예전에는 전부 "합류하지 못했어요" 하나였다.
///
/// 그리고 하나는 **실패가 아니다**: `PartyJoinException.isAlreadyInThisParty` 는 서버에 내가 이미 그 방
/// 멤버로 들어가 있다는 뜻이라 성공과 같은 길로 가야 한다. 그걸 실패로 다루면 재시도도 409, 다른 방도 409 라
/// 30분 스윕 전까지 그 계정이 어떤 방에도 못 들어간다.
struct JoinFailureMessageTest {
    private func failure(
        code: String?,
        httpStatus: Int? = 409,
        isNetwork: Bool = false,
        joinedStatus: PartyStatus? = nil
    ) -> PartyJoinException {
        PartyJoinException(
            code: code,
            serverMessage: nil,
            httpStatus: httpStatus,
            isNetwork: isNetwork,
            joinedStatus: joinedStatus
        )
    }

    @Test("이미 이 방 멤버면 실패가 아니다 - 문구가 아니라 성공 경로로 가야 한다")
    func alreadyInThisPartyIsNotAFailure() {
        let recovered = failure(
            code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY,
            joinedStatus: PartyStatus(status: .recruiting, currentMembers: 2)
        )

        #expect(recovered.isAlreadyInThisParty)
        // 「다른 방」과 섞이지 않는지 — 섞이면 복구 분기가 안내 문구로 떨어진다
        #expect(!recovered.isAlreadyInAnotherParty)
    }

    @Test("가득 찬 방 - 다른 방을 찾으라고 말한다")
    func fullParty() {
        #expect(joinFailureMessage(e: failure(code: "PARTY_FULL")) == "방이 가득 찼어요. 다른 방을 찾아 주세요")
    }

    @Test("모집이 끝난 방")
    func closedParty() {
        #expect(joinFailureMessage(e: failure(code: "PARTY_CLOSED")) == "모집이 끝난 방이에요. 다른 방을 찾아 주세요")
    }

    @Test("사라진 방 - 코드가 없는 404 도 같게 다룬다")
    func missingParty() {
        let expected = "사라진 방이에요. 목록을 다시 불러와 주세요"
        #expect(joinFailureMessage(e: failure(code: "PARTY_NOT_FOUND", httpStatus: 404)) == expected)
        #expect(joinFailureMessage(e: failure(code: nil, httpStatus: 404)) == expected)
    }

    @Test("다른 방에 참여 중 - 그 방을 먼저 정리하라고 말한다")
    func inAnotherParty() {
        // 확인 결과 내가 이 방 멤버가 아니었을 때(또는 확인 자체가 실패했을 때) 여기로 떨어진다.
        let message = joinFailureMessage(e: failure(code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY))
        #expect(message == "이미 참여 중인 방이 있어요. 그 방에서 나온 뒤 합류해 주세요")
    }

    @Test("이미 참여한 방 코드 - 확인은 못 했지만 재시도를 권하지는 않는다")
    func alreadyJoinedCode() {
        // 서버에 있지만 join 경로에서는 사실상 오지 않는 코드(ALREADY_JOINED_OTHER_PARTY 에 가린다).
        // 와도 "다시 시도"로 떨어지지 않게 자리를 만들어 둔다 — 다시 눌러도 같은 409 다.
        let message = joinFailureMessage(e: failure(code: PartyJoinException.ALREADY_JOINED_PARTY))
        #expect(message == "이미 참여 중이에요. 홈에서 진행 중인 방을 확인해 주세요")
    }

    @Test("네트워크 실패 - 연결을 확인하고 다시 시도하라고 말한다")
    func networkFailure() {
        let message = joinFailureMessage(e: failure(code: nil, httpStatus: nil, isNetwork: true))
        #expect(message == "네트워크가 불안정해요. 연결을 확인하고 다시 시도해 주세요")
    }

    @Test("원인을 가릴 수 없으면 재시도 안내로 떨어진다")
    func unknownFailure() {
        #expect(
            joinFailureMessage(e: failure(code: "NOT_PARTY_MEMBER", httpStatus: 403))
                == "합류하지 못했어요. 잠시 후 다시 시도해 주세요"
        )
        #expect(
            joinFailureMessage(e: failure(code: nil, httpStatus: 500))
                == "합류하지 못했어요. 잠시 후 다시 시도해 주세요"
        )
    }

    @Test("실패마다 다른 말을 한다 - 같은 문구가 두 갈래에 쓰이면 분기한 의미가 없다")
    func everyFailureSaysSomethingDifferent() {
        let messages = [
            failure(code: "PARTY_FULL"),
            failure(code: "PARTY_CLOSED"),
            failure(code: "PARTY_NOT_FOUND", httpStatus: 404),
            failure(code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY),
            failure(code: PartyJoinException.ALREADY_JOINED_PARTY),
            failure(code: nil, httpStatus: nil, isNetwork: true),
        ].map { joinFailureMessage(e: $0) }

        #expect(messages.count == Set(messages).count)
    }
}
