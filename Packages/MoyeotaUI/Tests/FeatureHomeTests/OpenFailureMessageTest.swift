import MoyeotaDomain
import Testing
@testable import FeatureHome

/// 16 방 생성의 실패 안내.
///
/// 생성만 오래 **모든 실패가 「동승 방을 만들지 못했어요. 잠시 후 다시 시도해 주세요」 하나**였다.
/// 합류는 6갈래(`joinFailureMessage`), 완료는 5갈래(`finishFailureMessage`)인데 생성만 없었다.
///
/// 그게 특히 나쁜 자리였던 까닭은 이 엔드포인트의 실패가 **기다려서 풀리는 것과 사용자가 고쳐야 하는
/// 것으로 갈리기** 때문이다:
/// - 409 「이미 참여 중인 방」 — 아무도 합류하지 않은 ACTIVE 방은 서버 30분 스윕
///   (`CompletedPartySweeper` 는 COMPLETED 만 쓸어낸다)에도 남아 **영구 교착**이다. 「잠시 후」는 거짓이다.
/// - 400 「출발지와 도착지가 같다」 — 16 의 핀 조정은 15 의 50m 검사를 **다시 거치지 않으므로** 실제로
///   벌어진다. 핀을 옮겨야 풀리는데 「잠시 후」로 안내하면 영원히 같은 400 을 맞는다.
@Suite struct OpenFailureMessageTest {

    private func failure(_ code: String?, httpStatus: Int? = 400) -> PartyOpenException {
        PartyOpenException(code: code, serverMessage: nil, httpStatus: httpStatus)
    }

    @Test("이미 참여 중인 방 - 홈에서 그 방을 확인하라고 말한다")
    func alreadyInOtherParty() {
        let message = openFailureMessage(
            e: failure(PartyJoinException.ALREADY_JOINED_OTHER_PARTY, httpStatus: 409)
        )

        #expect(message == ALREADY_IN_PARTY_MESSAGE)
        // 「잠시 후 다시」류가 섞이면 영구 교착을 기다리라고 말하는 셈이다.
        #expect(!message.contains("잠시 후"), "409 안내에 재시도 문구가 섞였다")
    }

    /// 서버에는 있지만 생성 경로에서는 위 코드에 가려 사실상 오지 않는다 — 와도 같게 다룬다.
    @Test("이미 참여한 방 코드도 같은 안내로 떨어진다")
    func alreadyJoinedCode() {
        #expect(
            openFailureMessage(e: failure(PartyJoinException.ALREADY_JOINED_PARTY, httpStatus: 409))
                == ALREADY_IN_PARTY_MESSAGE
        )
    }

    @Test("출발지와 도착지가 같다 - 핀을 옮기라고 말한다")
    func sameDepartureDestination() {
        let message = openFailureMessage(e: failure(PartyOpenException.SAME_DEPARTURE_DESTINATION))

        #expect(message == "출발지와 도착지가 같아요. 핀을 옮겨 조금 떨어뜨려 주세요")
    }

    @Test("서비스 지역 밖 좌표 - 다시 고르라고 말한다")
    func outOfServiceArea() {
        #expect(
            openFailureMessage(e: failure(PartyOpenException.OUT_OF_SERVICE_AREA))
                == "서비스 지역을 벗어난 위치예요. 출발지와 도착지를 다시 골라 주세요"
        )
    }

    @Test("정원이 범위를 벗어났다")
    func invalidCapacity() {
        #expect(openFailureMessage(e: failure(PartyOpenException.INVALID_CAPACITY)) == "인원은 1~3명까지만 정할 수 있어요")
    }

    /// 경로 관련 세 코드(+본문 없는 502)는 **한 갈래**다 — 사용자가 할 수 있는 일이 같다.
    @Test("경로를 못 받은 세 가지와 본문 없는 502 는 같은 안내다")
    func routeUnavailable() {
        let expected = "경로를 찾지 못했어요. 잠시 후 다시 시도하거나 출발·도착지를 조금 옮겨 주세요"

        #expect(openFailureMessage(e: failure(PartyOpenException.ROUTE_SEARCH_FAILED, httpStatus: 502)) == expected)
        #expect(openFailureMessage(e: failure(PartyOpenException.INVALID_ROUTE_ESTIMATE)) == expected)
        #expect(openFailureMessage(e: failure(PartyOpenException.ROUTE_NOT_FOUND)) == expected)
        #expect(openFailureMessage(e: failure(nil, httpStatus: 502)) == expected)
    }

    /// **서버가 코드를 늘려도 앱이 틀린 말을 하면 안 된다.** 400 이 네 가지라 상태 코드로 폴백하면
    /// 「핀을 옮겨 주세요」가 거짓이 될 수 있다 — 모르는 코드·본문 없는 응답(503 HTML 등)은 일반 문구다.
    @Test("모르는 코드와 코드 없는 실패는 일반 문구로 떨어진다")
    func generalMessage() {
        let general = "동승 방을 만들지 못했어요. 잠시 후 다시 시도해 주세요"

        #expect(openFailureMessage(e: failure("PARTY_SOMETHING_NEW")) == general)
        #expect(openFailureMessage(e: failure(nil, httpStatus: 503)) == general)
        // 네트워크 실패(응답 자체가 없다)도 여기다.
        #expect(openFailureMessage(e: failure(nil, httpStatus: nil)) == general)
        // 400 이라고 좌표 문제로 **추측하지 않는다**.
        #expect(openFailureMessage(e: failure(nil, httpStatus: 400)) == general)
    }

    @Test("실패마다 다른 말을 한다 - 같은 문구가 두 갈래에 쓰이면 분기한 의미가 없다")
    func everyBranchDiffers() {
        let messages = [
            failure(PartyJoinException.ALREADY_JOINED_OTHER_PARTY, httpStatus: 409),
            failure(PartyOpenException.SAME_DEPARTURE_DESTINATION),
            failure(PartyOpenException.OUT_OF_SERVICE_AREA),
            failure(PartyOpenException.INVALID_CAPACITY),
            failure(PartyOpenException.ROUTE_SEARCH_FAILED, httpStatus: 502),
            failure(nil, httpStatus: 500),
        ].map { openFailureMessage(e: $0) }

        #expect(messages.count == Set(messages).count)
    }
}
