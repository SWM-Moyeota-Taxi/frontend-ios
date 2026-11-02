import MoyeotaDomain
import Testing
@testable import FeatureHome

private struct SerializationFailure: Error {}

/// 16 「걸어서 가까운 방」 추천의 **실패와 「후보 0개」를 가르는** 판정.
///
/// 예전에는 둘이 같은 상태였다(`NearbyCandidatesViewModel.UiState.hidden`) — 그 설명이 「후보가
/// 없거나, 추천을 못 가져왔다. 셋 다 섹션을 숨긴다」고 **의도적으로 합쳤다**고 적어 두었다. 결과는
/// ①「주변에 방이 없다」와 ②「못 물어봤다」가 사용자에게 **구별되지 않는다**는 것이고, 둘의 올바른
/// 다음 행동은 정반대다(방 만들기 / 다시 시도).
///
/// 그래서 OSRM 이 죽거나 503 이면 300m 안에 방이 있어도 섹션이 그냥 사라지고 사용자는 새 방을 만든다 —
/// **합승 매칭이라는 제품의 핵심이 조용히 꺼지는 자리다.** 게다가 409 는 바로 뒤의 「방 만들기」 409
/// 교착을 예고하는 신호인데 그것까지 지워졌다.
@MainActor
@Suite struct NearbyCandidatesFailureTest {

    private func realtime(_ code: String?, httpStatus: Int? = 502) -> RealtimeMatchException {
        RealtimeMatchException(code: code, serverMessage: nil, httpStatus: httpStatus)
    }

    /// 409 는 「추천이 없다」가 아니라 **「당신은 이미 방에 있다」**다. 그 사람은 추천도 못 받고 방도
    /// 못 만든다(서버가 두 경로 모두 `validateNotInOngoingParty` 를 먼저 탄다) — 화면이 같은 사유를
    /// 같은 말로 안내하고 홈 배너를 되살릴 수 있어야 한다.
    @Test("이미 진행 중인 방이면 그 사유로 갈린다")
    func alreadyInParty() {
        #expect(
            candidatesFailure(cause: realtime(PartyJoinException.ALREADY_JOINED_OTHER_PARTY, httpStatus: 409))
                == .alreadyInParty
        )
    }

    /// 502 경로 엔진 장애 — 「주변에 방이 없다」로 위장되면 안 된다. 재시도 줄을 둘 상태로 떨어진다.
    @Test("경로 엔진 장애는 조회 실패로 갈린다")
    func routeEngineFailure() {
        #expect(candidatesFailure(cause: realtime("ROUTE_SEARCH_FAILED")) == .failed)
    }

    /// 서비스 지역 밖·모르는 코드·본문 없는 503 도 「조회 실패」다 — 재시도 말고는 안내할 게 없다.
    @Test("모르는 코드와 코드 없는 실패도 조회 실패다")
    func unknownCodes() {
        #expect(candidatesFailure(cause: realtime("OUT_OF_SERVICE_AREA", httpStatus: 400)) == .failed)
        #expect(candidatesFailure(cause: realtime(nil, httpStatus: 503)) == .failed)
    }

    /// 데이터 계층이 좁히지 못한 실패(직렬화 등)에 「진행 중인 방이 있어요」라고 **추측하지 않는다** —
    /// 그 말은 거짓일 때 사용자를 없는 방으로 찾아 보낸다.
    @Test("RealtimeMatchException 이 아닌 실패는 사유를 추측하지 않는다")
    func otherFailures() {
        #expect(candidatesFailure(cause: SerializationFailure()) == .failed)
    }

    /// **「조회 실패」와 「후보 0개」는 서로 다른 상태여야 한다.** 이 한 줄이 이번 수정의 본체다 —
    /// 같은 값으로 돌아가면 사용자는 둘을 다시 구별할 수 없다.
    @Test("조회 실패는 숨김과 다른 상태다")
    func failuresAreNotHidden() {
        let failures = [
            candidatesFailure(cause: realtime("ROUTE_SEARCH_FAILED")),
            candidatesFailure(cause: realtime(PartyJoinException.ALREADY_JOINED_OTHER_PARTY, httpStatus: 409)),
        ]

        for state in failures {
            #expect(state != .hidden, "조회 실패가 「후보 0개」와 같은 상태로 접혔다")
        }
        // 두 실패끼리도 갈린다 — 안내 문구가 다르다.
        #expect(failures[0] != failures[1])
    }
}
