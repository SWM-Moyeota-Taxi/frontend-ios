import Foundation

/// 방 합류 실패를 화면이 **복구할 수 있는 형태**로 좁힌 예외
/// (`RideRepository.joinParty` 전용).
///
/// 합류에만 따로 예외를 둔 이유는 실패의 **대가가 유독 크기** 때문이다. 서버는 멤버 추가를 먼저 커밋하고
/// 응답을 만드는데, 그 응답 처리에서 앱이 넘어지면 **그 계정은 어떤 방에도 못 들어간다** — 같은 방에
/// 다시 합류해도, 다른 방에 합류해도 409 로 막히고(아래 `isAlreadyJoined` 참고) 30분 스윕 전까지 그대로다.
/// 그래서 "이미 내가 그 방 멤버다"를 **성공으로 되돌릴 수 있는 신호**가 필요하다.
///
/// 분기 근거를 프로퍼티로 노출하는 건 `ChatException` 과 같은 이유다 — 서버 코드 문자열 비교가 화면으로
/// 새어 나가면 서버가 enum 이름을 바꿀 때 조용히 어긋난다.
public struct PartyJoinException: Throwable {
    /// 서버 `MatchingErrorCode` 이름(`ALREADY_JOINED_OTHER_PARTY` 등). 본문이 없거나 파싱 실패면 null.
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 응답 자체가 없으면(네트워크 실패) null.
    public let httpStatus: Int?
    /// 응답을 받지 못한 실패(연결 거부·타임아웃·DNS). 사용자에게는 재시도를 안내한다.
    public let isNetwork: Bool
    /// **이미 내가 그 방 멤버였을 때** 저장소가 확인해 담아 주는 그 방의 현재 상태.
    ///
    /// 데이터 계층이 방 상세를 읽어 내 publicId 가 members 에 있는지 **확인한 뒤에만** 채운다 —
    /// 추측이 아니라 증거다. 채워져 있으면 화면은 이 실패를 성공처럼 다뤄도 된다
    /// (합류 성공과 똑같이 대기 화면으로 넘기면 된다). 그 밖에는 null.
    public let joinedStatus: PartyStatus?
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        isNetwork: Bool = false,
        joinedStatus: PartyStatus? = nil,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.isNetwork = isNetwork
        self.joinedStatus = joinedStatus
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "방에 합류하지 못했습니다." }

    /// **이미 내가 이 방의 멤버다** — 합류는 "실패"가 아니라 "이미 됨"이다.
    /// `joinedStatus` 가 그 방의 현재 상태이므로, 화면은 합류 성공과 같은 길로 보내면 된다.
    public var isAlreadyInThisParty: Bool { joinedStatus != nil }

    /// **다른 방에 진행 중이다** — 그 방을 먼저 정리(나가기·종료)해야 이 방에 들어갈 수 있다.
    ///
    /// 서버는 "이 방"과 "다른 방"을 **코드로 구분해 주지 않는다**(둘 다 `ALREADY_JOINED_OTHER_PARTY`).
    /// 가른 건 데이터 계층이다 — 방 상세에 내가 없을 때만 여기로 떨어진다.
    public var isAlreadyInAnotherParty: Bool { code == Self.ALREADY_JOINED_OTHER_PARTY && joinedStatus == nil }

    /// 어느 쪽이든 "이미 참여 중"이라 서버가 막은 것. 같은 요청을 다시 보내도 결과가 같다
    public var isAlreadyJoined: Bool { Self.isAlreadyJoinedCode(code: code) }

    /// 409 `PARTY_FULL` — 정원이 가득 찼다(내가 보던 목록이 낡았다).
    public var isPartyFull: Bool { code == "PARTY_FULL" }

    /// 409 `PARTY_CLOSED` — 모집이 끝난 방이다(이미 매칭·종료로 넘어갔다).
    public var isPartyClosed: Bool { code == "PARTY_CLOSED" }

    /// 404 `PARTY_NOT_FOUND` — 방이 사라졌다. 목록에서 빼야 한다.
    public var isPartyNotFound: Bool { code == "PARTY_NOT_FOUND" || (code == nil && httpStatus == 404) }

    /// 서버가 **재합류에도 이 코드를 준다.** `PartyService.join` 이 `party.join()` 보다 먼저
    /// `existsOngoingByMemberId` 를 보고, 그 질의가 합류 대상 방을 제외하지 않기 때문이다 —
    /// 그래서 "이미 참여한 방"을 뜻하는 `ALREADY_JOINED_PARTY` 는 사실상 오지 않는다.
    public static let ALREADY_JOINED_OTHER_PARTY = "ALREADY_JOINED_OTHER_PARTY"

    /// 서버에는 있지만 합류 경로에서는 위 코드에 가려 사실상 오지 않는다 — 와도 같게 다룬다.
    public static let ALREADY_JOINED_PARTY = "ALREADY_JOINED_PARTY"

    /// 「이미 참여 중」을 뜻하는 409 인가 — 이때만 "혹시 그게 이 방인가"를 확인할 가치가 있다.
    ///
    /// 두 코드를 함께 보는 건 `ALREADY_JOINED_OTHER_PARTY` 의 사정 때문이다: 코드만으로는
    /// 이 방인지 다른 방인지 가릴 수 없어, 데이터 계층이 방 상세로 확인한다.
    /// 서버 코드 문자열을 아는 곳을 여기 하나로 묶어 둔다 — 데이터 계층이 같은 문자열을
    /// 또 들고 있으면 한쪽만 서버 변경을 따라간다.
    public static func isAlreadyJoinedCode(code: String?) -> Bool {
        code == ALREADY_JOINED_OTHER_PARTY || code == ALREADY_JOINED_PARTY
    }
}

/// 「합승 완료」 실패를 화면이 **사유별로 안내할 수 있는 형태**로 좁힌 예외
/// (`RideRepository.finishParty` 전용).
///
/// 따로 둔 이유는 이 액션의 실패가 **서로 다른 네 가지 뜻**을 갖는데 **HTTP 상태로는 갈리지 않기**
/// 때문이다 — 403 이 둘(`NOT_PARTY_MEMBER`·`NOT_PARTY_HOST`), 409 가 둘(`PARTY_NOT_COMPLETED`·
/// `DRIVER_ALREADY_ASSIGNED`)이다(서버 `Party.finishWithoutDriver` 의 검사 순서가 그대로
/// 이 순서다). 예전에는 넷 다 「합승을 완료하지 못했어요」 하나로 떨어져서, **방장이 아니라서 막힌
/// 사람이 다음에 뭘 해야 하는지 알 수 없었다** — 같은 버튼을 다시 눌러도 같은 403 이다.
///
/// 그래서 **상태 코드로는 폴백하지 않는다.** 403 을 「방장만 할 수 있어요」로 뭉개면 방 멤버가 아닌
/// 사람에게 방장을 찾으라고 말하게 되고, 409 를 「정원이 안 찼어요」로 뭉개면 기사가 배정된 방에
/// 거짓을 말하게 된다. 코드를 모르면 `code` 는 null 이고 화면은 **일반 문구**로 떨어진다 —
/// 서버가 코드를 늘려도 앱이 틀린 말을 하지 않는다.
///
/// 분기 근거를 프로퍼티로 노출하는 건 `PartyJoinException` 과 같은 이유다 — 서버 코드 문자열 비교가
/// 화면으로 새어 나가면 서버가 enum 이름을 바꿀 때 조용히 어긋난다.
public struct PartyFinishException: Throwable {
    /// 서버 `MatchingErrorCode` 이름(`NOT_PARTY_HOST` 등). 본문이 없거나 파싱 실패면 null.
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 응답 자체가 없으면(네트워크 실패) null. 문구 분기에는 쓰지 않는다 — 위 주석 참고.
    public let httpStatus: Int?
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "합승을 완료하지 못했습니다." }

    /// 403 `NOT_PARTY_HOST` — **방장만** 완료할 수 있다(Backend #237).
    ///
    /// 방장은 서버가 저장하는 값이 아니라 **지금 멤버 중 가장 먼저 합류한 사람**이다
    /// (`Party.hostId()` = `min(joinedAt, memberId)`). 그래서 방장이 나가면 다음으로 이른 멤버에게
    /// 자동 승계된다.
    ///
    /// 그 승계는 **SSE 변경분에 실려 온다**(`member-left` 의 `hostPublicId` = 이벤트를 반영한 뒤의
    /// 방장). 그래도 이 403 은 **남는다** — 그 신호는 한 번뿐이고 재발행되지 않아(SSE at-most-once),
    /// 프레임이 유실되거나 순서가 역전되면 내 스냅샷이 낡은 채로 버튼을 보여 줄 수 있다. 화면은
    /// **누가 눌러야 하는지**를 말해 줘야 하고, 그 순간에는 방장이 누구인지 확신할 수 없으므로
    /// 이름이 아니라 **조건**으로 말한다.
    public var isNotHost: Bool { code == Self.NOT_PARTY_HOST }

    /// 403 `NOT_PARTY_MEMBER` — 이 방의 멤버가 아니다. `isNotHost` 와 **같은 403 이지만 뜻이 다르다**.
    public var isNotMember: Bool { code == Self.NOT_PARTY_MEMBER }

    /// 409 `PARTY_NOT_COMPLETED` — 정원이 아직 다 차지 않았다(서버는 COMPLETED 방만 닫아 준다).
    public var isNotCompleted: Bool { code == Self.PARTY_NOT_COMPLETED }

    /// 409 `DRIVER_ALREADY_ASSIGNED` — 기사가 배정됐다. 이 방은 기사 없이 끝낼 방이 아니다.
    public var isDriverAssigned: Bool { code == Self.DRIVER_ALREADY_ASSIGNED }

    /// 404 `PARTY_NOT_FOUND` — 방이 사라졌다.
    public var isPartyNotFound: Bool { code == Self.PARTY_NOT_FOUND }

    /// 서버 `MatchingErrorCode` 중 **이 엔드포인트가 실제로 던지는** 코드만 둔다
    /// (`PartyService.finish` → `Party.finishWithoutDriver`). 문자열을 아는 곳을 여기 하나로 묶어
    /// 데이터 계층과 화면이 각자 들고 있지 않게 한다.
    public static let NOT_PARTY_MEMBER = "NOT_PARTY_MEMBER"
    public static let NOT_PARTY_HOST = "NOT_PARTY_HOST"
    public static let PARTY_NOT_COMPLETED = "PARTY_NOT_COMPLETED"
    public static let DRIVER_ALREADY_ASSIGNED = "DRIVER_ALREADY_ASSIGNED"
    public static let PARTY_NOT_FOUND = "PARTY_NOT_FOUND"
}

/// 「걸어서 가까운 방」 추천 조회가 실패했다(`POST /matching/rooms/realtime`).
///
/// **빈 목록은 여기로 오지 않는다** — 후보가 없는 건 정상이고 성공이다. 이 예외는 조회 자체가
/// 안 된 경우뿐이다.
public struct RealtimeMatchException: Throwable {
    /// 서버 `MatchingErrorCode` 이름. 본문이 없거나 파싱 실패면 null.
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 응답 자체가 없으면(네트워크 실패) null.
    public let httpStatus: Int?
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "추천을 가져오지 못했습니다." }

    /// 502 `ROUTE_SEARCH_FAILED` — 서버가 도보 경로 엔진(OSRM)에 닿지 못했다.
    ///
    /// **이게 평소에는 숨는다.** 300m 안에 후보가 한 건도 없으면 서버가 OSRM 을 아예 호출하지 않고
    /// 빈 배열을 돌려주기 때문이다. 즉 엔진이 죽어 있어도 눌러 보면 정상으로 보이다가, **후보가
    /// 처음 잡히는 순간** — 기능이 처음 쓸모 있어지는 그때 — 502 가 터진다. 화면은 이걸 사용자
    /// 잘못처럼 말하지 말고 방 만들기로 흘려야 한다.
    public var isRouteUnavailable: Bool { code == "ROUTE_SEARCH_FAILED" || httpStatus == 502 }

    /// 409 `ALREADY_JOINED_OTHER_PARTY` — 이미 진행 중인 방이 있다.
    ///
    /// 그 사람은 새 방을 만들 수도, 다른 방에 합류할 수도 없다. 추천을 보여 줄 이유가 없으므로
    /// 화면은 **섹션 자체를 숨긴다**(에러 문구를 띄우지 않는다).
    public var isAlreadyInParty: Bool { code == PartyJoinException.ALREADY_JOINED_OTHER_PARTY }

    /// 400 `OUT_OF_SERVICE_AREA` — 좌표가 서비스 지역(위 33~39 / 경 124~132) 밖이다.
    ///
    /// **요청 필드명을 먼저 의심할 것.** 서버 요청 record 가 전부 primitive double 이라 필드가
    /// 빠지면 0.0 이 들어가고, (0,0) 은 서비스 지역 밖이라 같은 400 으로 떨어진다. 요청 쪽 이름은
    /// `destLat`/`destLng` 이고 응답 쪽만 `destinationLat`/`destinationLng` 이다.
    public var isOutOfServiceArea: Bool { code == "OUT_OF_SERVICE_AREA" }
}

/// 방 **생성** 실패를 화면이 **사유별로 안내할 수 있는 형태**로 좁힌 예외
/// (`RideRepository.createParty` 전용).
///
/// 생성만 오래 예외가 없었다. 합류는 `PartyJoinException` 으로 6갈래, 완료는 `PartyFinishException` 으로
/// 5갈래인데 생성은 **모든 실패가 「잠시 후 다시 시도해 주세요」 하나**였다. 그게 특히 나쁜 까닭은 이
/// 엔드포인트의 실패가 **기다려서 풀리는 것과 사용자가 고쳐야 하는 것으로 갈리기** 때문이다:
///
/// | 사유 | 서버 코드(HTTP) | 기다리면 풀리나 |
/// |---|---|---|
/// | 이미 참여 중인 방이 있다 | `ALREADY_JOINED_OTHER_PARTY` (409) | **아니다.** 그 방을 먼저 정리해야 한다 |
/// | 출발지와 도착지가 같다 | `SAME_DEPARTURE_DESTINATION` (400) | **아니다.** 핀을 옮겨야 한다 |
/// | 서비스 지역 밖 좌표 | `OUT_OF_SERVICE_AREA` (400) | **아니다.** 다른 곳을 골라야 한다 |
/// | 정원이 1~3 이 아니다 | `INVALID_CAPACITY` (400) | **아니다.** 앱이 잘못 보냈다 |
/// | 경로 엔진 장애·경로 없음 | `ROUTE_SEARCH_FAILED` (502) · `INVALID_ROUTE_ESTIMATE`·`ROUTE_NOT_FOUND` (400) | 장애면 그렇다 |
///
/// **409 가 이 예외를 만든 직접적인 이유다.** 서버 `PartyService.open` 의 첫 줄이
/// `validateNotInOngoingParty(creatorId)` 이고, 거기서 보는 「진행 중」은
/// `PartyStatus.isOngoing()` = `!(CANCELED || FINISHED)` 다. 그런데 서버의 30분 스윕
/// (`CompletedPartySweeper`)은 **COMPLETED 만** 쓸어내므로 **아무도 합류하지 않은 ACTIVE 방은 영구히
/// 남아** 그 계정의 생성·합류를 계속 막는다. 유일한 탈출구가 홈 배너 → 21 → 「그만 찾기」인데, 그 배너는
/// `ActivePartyRepository.resolve()` 가 방을 찾아야 뜬다 — 그래서 화면은 이 409 를 받으면 **문구로
/// 안내하는 동시에 진행 중 방 조회를 되살려야** 한다. 그 둘 다 「잠시 후 다시 시도」 아래에서는 할 수 없다.
///
/// 분기 근거를 프로퍼티로 노출하는 건 `PartyJoinException`·`PartyFinishException` 과 같은 이유다 —
/// 서버 코드 문자열 비교가 화면으로 새어 나가면 서버가 enum 이름을 바꿀 때 조용히 어긋난다.
/// 그리고 **상태 코드로 폴백하지 않는다**(400 이 네 가지, 502 가 한 가지다): 코드를 모르면 `code` 는
/// null 이고 화면은 **일반 문구**로 떨어진다. 서버가 코드를 늘려도 앱이 틀린 말을 하지 않는다.
public struct PartyOpenException: Throwable {
    /// 서버 `MatchingErrorCode` 이름(`SAME_DEPARTURE_DESTINATION` 등). 본문이 없거나 파싱 실패면 null.
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 응답 자체가 없으면(네트워크 실패) null. 문구 분기에는 `isRouteUnavailable` 만 쓴다.
    public let httpStatus: Int?
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "방을 만들지 못했습니다." }

    /// 409 — **이미 참여 중인 방이 있다.** 그 방을 정리하지 않으면 새 방도, 다른 방 합류도 막힌다.
    ///
    /// 합류와 달리 「이 방인가」를 가릴 필요가 없다 — 만들려는 방은 아직 없으므로 **언제나 다른 방**이다.
    /// 그래서 `PartyJoinException.isAlreadyInThisParty` 같은 복구 분기가 없고, 대신 화면은 진행 중 방
    /// 조회를 되살려 홈 배너로 돌아갈 길을 만들어야 한다(위 주석).
    ///
    /// 두 코드를 함께 보는 건 `PartyJoinException.isAlreadyJoinedCode` 와 같은 이유다 — 서버 코드 문자열을
    /// 아는 곳을 늘리지 않는다.
    public var isAlreadyInAnotherParty: Bool { PartyJoinException.isAlreadyJoinedCode(code: code) }

    /// 400 `SAME_DEPARTURE_DESTINATION` — 출발지와 도착지가 **같은 좌표**다(서버 `Party.open` 첫 검사).
    ///
    /// 15 목적지 화면의 50m 검사를 통과한 뒤에도 생긴다: 16 의 핀 조정은 그 검사를 **다시 거치지 않으므로**
    /// 두 핀을 겹쳐 놓으면 그대로 여기로 떨어진다. 사용자가 **고쳐야 하는** 실패라 「잠시 후 다시」로
    /// 안내하면 영원히 같은 400 을 맞는다.
    public var isSameDepartureDestination: Bool { code == Self.SAME_DEPARTURE_DESTINATION }

    /// 400 `OUT_OF_SERVICE_AREA` — 좌표가 서비스 지역(위 33~39 / 경 124~132) 밖이다.
    /// `RealtimeMatchException.isOutOfServiceArea` 와 같은 코드이고, **요청 필드명을 먼저 의심할 것**도 같다.
    public var isOutOfServiceArea: Bool { code == Self.OUT_OF_SERVICE_AREA }

    /// 400 `INVALID_CAPACITY` — 정원이 1~3 이 아니다(서버 `Capacity` record).
    /// 16 모달의 칩이 1~3 뿐이고 앱이 한 번 더 `coerceIn` 하므로 **앱 버그일 때만** 온다 —
    /// 그래도 「잠시 후 다시」로 뭉개지 않는다: 기다려서 풀리지 않는다.
    public var isInvalidCapacity: Bool { code == Self.INVALID_CAPACITY }

    /// 경로를 받지 못했다 — 서버가 방을 만들기 **전에** 경로를 추정하므로(`routeService.estimate`)
    /// 그 단계의 실패가 곧 생성 실패다.
    ///
    /// 세 코드를 한 갈래로 묶는다. 502 `ROUTE_SEARCH_FAILED`(엔진 장애)와 400
    /// `INVALID_ROUTE_ESTIMATE`·`ROUTE_NOT_FOUND`(받아온 추정이 쓸 수 없다/경로가 없다)는 원인이 다르지만
    /// **사용자가 할 수 있는 일이 같다** — 잠시 뒤 다시 시도하거나 핀을 조금 옮기는 것뿐이다.
    /// 502 를 상태 코드로도 받는 건 `RealtimeMatchException.isRouteUnavailable` 과 같은 선례다
    /// (게이트웨이가 본문 없이 502 만 돌려주는 경우).
    public var isRouteUnavailable: Bool {
        code == Self.ROUTE_SEARCH_FAILED ||
            code == Self.INVALID_ROUTE_ESTIMATE ||
            code == Self.ROUTE_NOT_FOUND ||
            httpStatus == 502
    }

    /// 서버 `MatchingErrorCode` 중 **이 엔드포인트가 실제로 던지는** 코드만 둔다
    /// (`PartyService.open` → `routeService.estimate` → `Party.open` → `Capacity`/`Location`).
    /// 「이미 참여 중」 두 코드는 `PartyJoinException` 이 이미 들고 있으므로 여기서 또 적지 않는다.
    public static let SAME_DEPARTURE_DESTINATION = "SAME_DEPARTURE_DESTINATION"
    public static let OUT_OF_SERVICE_AREA = "OUT_OF_SERVICE_AREA"
    public static let INVALID_CAPACITY = "INVALID_CAPACITY"
    public static let INVALID_ROUTE_ESTIMATE = "INVALID_ROUTE_ESTIMATE"
    public static let ROUTE_NOT_FOUND = "ROUTE_NOT_FOUND"
    public static let ROUTE_SEARCH_FAILED = "ROUTE_SEARCH_FAILED"
}

/// 방 **나가기** 실패를 화면이 **사유별로 안내할 수 있는 형태**로 좁힌 예외
/// (`RideRepository.leaveParty` 전용).
///
/// **403 `NOT_PARTY_MEMBER` 는 이 예외로 오지 않는다 — 데이터 계층이 그걸 성공으로 되돌린다.**
/// 그게 이 예외를 만든 이유다. 서버 `Party.leave` 의 검사 순서가 「멤버인가 → 모집 중인가」인데,
/// 204 응답이 유실되면(터널·타임아웃) 앱은 실패로 끝나고 **다시 누르면 403** 이다. 두 실패가 같은
/// 문구로 떨어지면 **이미 나간 사람이 영구 실패 화면에 갇힌다** — 로컬 기억과 홈 배너는 그 방을 계속
/// 들고 있으니 화면상 나는 아직 그 방에 있다. 합류가 409 를 성공으로 되돌리는 것
/// (`PartyJoinException.isAlreadyInThisParty`)과 **대칭**인 처방이다.
///
/// 그래서 화면까지 올라오는 실패는 둘뿐이다:
///
/// | 사유 | 서버 코드(HTTP) | 사용자가 할 일 |
/// |---|---|---|
/// | 모집 중이 아니다 | `PARTY_NOT_RECRUITING` (409) | 매칭이 시작돼 나갈 수 없다 — 기다린다 |
/// | 방이 없다 | `PARTY_NOT_FOUND` (404) | 홈으로 돌아간다(이미 닫힌 방이다) |
/// | 그 밖·네트워크 | 코드 없음 | 다시 시도한다 |
public struct PartyLeaveException: Throwable {
    /// 서버 `MatchingErrorCode` 이름(`PARTY_NOT_RECRUITING` 등). 본문이 없거나 파싱 실패면 null.
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 응답 자체가 없으면(네트워크 실패) null.
    public let httpStatus: Int?
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "방에서 나가지 못했습니다." }

    /// 409 `PARTY_NOT_RECRUITING` — 모집 단계를 벗어난 방이다(기사 매칭이 시작됐다).
    ///
    /// 화면은 이 단계에서 나가기 버튼을 이미 비활성으로 바꾸지만(21 의 `canLeaveParty`), 전이를
    /// 알아채기까지 한 주기가 비어 그 틈에 눌릴 수 있다 — 그때 「나가지 못했어요」가 아니라 **왜**
    /// 못 나가는지 말해 줘야 한다.
    public var isNotRecruiting: Bool { code == Self.PARTY_NOT_RECRUITING }

    /// 404 `PARTY_NOT_FOUND` — 방이 사라졌다. 나갈 방이 없으므로 홈으로 보내면 된다.
    public var isPartyNotFound: Bool { code == Self.PARTY_NOT_FOUND || (code == nil && httpStatus == 404) }

    /// 403 — 이 방의 멤버가 아니다 = **이미 나갔다**.
    ///
    /// 이 상수를 읽는 곳은 **데이터 계층 하나**다(`RemoteRideRepository.leaveParty` 가 성공으로
    /// 되돌린다). 화면이 이 코드를 보게 되면 그건 되돌림이 빠졌다는 뜻이다 — 위 주석 참고.
    public static let NOT_PARTY_MEMBER = "NOT_PARTY_MEMBER"
    public static let PARTY_NOT_RECRUITING = "PARTY_NOT_RECRUITING"
    public static let PARTY_NOT_FOUND = "PARTY_NOT_FOUND"
}

/// **나는 이 방의 멤버가 아니다** — 방 변화 신호 구독(SSE)이 403 `NOT_PARTY_MEMBER` 로 거절됐다
/// (`RideRepository.observePartyEvents`).
///
/// 이 예외가 **멤버십을 알려 주는 유일한 창구**다. `GET /matching/rooms/{partyId}`(방 상세)에는 참여자
/// 검사가 **없어** 멤버가 아니어도 조회가 계속 성공하기 때문이다 — 서버가 403 을 말해 주는 자리는
/// `PartySseController` 뿐이고, 그쪽은 그 403 을 `@ApiResponse` 로 계약 문서화해 두었다.
///
/// ### 왜 「스트림 종료」와 갈라야 하는가 ★
/// 예전에는 이 403 이 그 밖의 종결(방 닫힘·404)과 **똑같이** 「스트림이 끝났다」로 뭉개졌다. 그러면
/// 21 대기 화면은 다시 붙지 않는 대신 6초마다 방 상세를 **영원히** 폴링하면서, **내가 들어 있지 않은
/// 방**을 「같이 탈 사람을 찾고 있어요」로 보여 준다. 인원 문구까지 자기모순을 말하고(내가 없으니
/// 「나 외 N명」이 전체 인원과 같아진다), 거기서 「그만 찾기」를 누르면 다시 403 이라 **벗어날 길이 없다.**
///
/// 그래서 신호를 **흐름의 정상 종료가 아니라 예외**로 올린다 — 「끝났다」와 「내가 있을 방이 아니다」는
/// 호출부가 할 일이 다르고(폴백 폴링 / 화면 떠나기), 정상 종료로는 그 둘을 구분할 자리가 없다.
///
/// 전파 경로에서 **흐름이 재연결을 멈춘다**: 403 은 다시 붙어 봐야 같은 답이다.
public struct PartyMembershipLostException: Throwable {
    /// 어느 방이었는지. 로그·디버깅용이고 화면 분기에는 쓰지 않는다
    public let partyId: Int64?
    public let cause: (any Error)?

    public init(partyId: Int64? = nil, cause: (any Error)? = nil) {
        self.partyId = partyId
        self.cause = cause
    }

    public var message: String? { "이 방의 참여자가 아닙니다. (partyId=\(partyId.map { String($0) } ?? "null"))" }
}
