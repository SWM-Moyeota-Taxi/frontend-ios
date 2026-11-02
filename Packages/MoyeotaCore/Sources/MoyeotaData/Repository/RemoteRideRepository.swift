import MoyeotaDomain

/// 매칭·신고 도메인만 서버 연동 — 나머지는 더미로 위임한다.
///
/// `session` 이 필요한 이유는 하나다: 방 상세의 멤버 중 **누가 나인지**는 서버가 표시해 주지 않는다.
/// `MemberInfo.publicId` 가 JWT `sub` 와 같은 값이라 앱이 직접 비교해야 하고, 비교 대상인
/// 현재 사용자 UUID 의 단일 출처가 `session` 이다. 매퍼에 세션을 들려 보내지 않으면 화면마다
/// "나 찾기"를 다시 구현하게 된다.
///
/// `reportApi` 기본값 null: 신고 배선이 없는 생성 호출(테스트 등)을 깨지 않기 위함.
/// 배선 전 신고 호출은 한국어 `IllegalStateException` 으로 실패한다 (화면은 다이얼을 우선 연다).
/// `currentLocation`: 신고 시점의 실측 좌표 공급자(앱 타깃이 `CLLocationManager` 로 주입).
/// 못 얻으면 null — 서버 ReportRequest 는 좌표 null 을 허용하므로 가짜 좌표를 지어내지 않는다.
public final class RemoteRideRepository: RideRepository {
    private let api: any MatchingApi
    private let session: any UserSession
    private let local: any RideRepository
    private let reportApi: (any ReportApi)?
    private let currentLocation: @Sendable () async throws -> (Double, Double)?
    /// 매칭방 변화 신호(SSE). null 이면 신호 없이 폴링만 한다(테스트·더미)
    private let partyEvents: PartyEventSource?

    public init(
        api: any MatchingApi,
        session: any UserSession,
        local: any RideRepository = DummyRideRepository(),
        reportApi: (any ReportApi)? = nil,
        currentLocation: @escaping @Sendable () async throws -> (Double, Double)? = { nil },
        partyEvents: PartyEventSource? = nil
    ) {
        self.api = api
        self.session = session
        self.local = local
        self.reportApi = reportApi
        self.currentLocation = currentLocation
        self.partyEvents = partyEvents
    }

    /// SSE 프레임을 도메인 이벤트로 옮긴다. 세션 uuid 는 **이벤트가 올 때마다** 읽는다 — 스냅샷·입장 신호의
    /// "나" 판정이 상세 조회와 같은 근거를 쓰게 하고, 구독 중 재로그인이 있어도 다음 이벤트부터 맞게 한다.
    public func observePartyEvents(partyId: Int64) -> AsyncThrowingStream<PartyEvent, any Error> {
        guard let partyEvents else { return AsyncThrowingStream { $0.finish() } }
        return AsyncThrowingStream { continuation in
            let task = Task { [session] in
                do {
                    for try await event in partyEvents.events(partyId: partyId) {
                        continuation.yield(event.toPartyEvent(currentUuid: session.currentUserUuid))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func getNearbyParties() -> [Ride] { local.getNearbyParties() }

    public func getParties() async throws -> [Ride] {
        try await api.getParties().list.map { $0.toRide() }
    }

    // 전체 목록과 같은 경로 + 쿼리 파라미터 4개. 매퍼가 departureLat/Lng 를 originLat/Lng 로 옮긴다.
    public func getPartiesWithin(
        swLat: Double,
        swLng: Double,
        neLat: Double,
        neLng: Double
    ) async throws -> [Ride] {
        try await api.getPartiesWithin(swLat: swLat, swLng: swLng, neLat: neLat, neLng: neLng).list.map { $0.toRide() }
    }

    // currentUserUuid 는 호출 시점에 읽는다 — 재로그인으로 주체가 바뀌어도 다음 조회부터 바로 반영된다.
    public func getPartyDetail(partyId: Int64) async throws -> Ride {
        let detail = try await api.getPartyDetail(partyId: partyId)
        return detail.toRide(currentUuid: session.currentUserUuid)
    }

    // 같은 엔드포인트를 한 번만 때리고 순번까지 함께 넘긴다 — 두 번 읽지 않는다.
    public func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail {
        let detail = try await api.getPartyDetail(partyId: partyId)
        return PartyDetail(ride: detail.toRide(currentUuid: session.currentUserUuid), version: detail.version)
    }

    /// 생성자는 서버가 토큰에서 정한다 — 요청 본문에도 응답에도 id 가 없다.
    ///
    /// 실패는 전부 `PartyOpenException` 으로 좁힌다(`joinParty` 와 같은 모양·같은 이유) — 이 액션의
    /// 실패는 **기다리면 풀리는 것과 사용자가 고쳐야 하는 것으로 갈리는데**(409 진행 중인 방 · 400
    /// 좌표/정원 · 502 경로 엔진) 예전에는 전부 한 문구로 떨어져 **그중 어느 것도 다음 행동을 말해
    /// 주지 못했다.** 특히 409 는 아무도 합류하지 않은 ACTIVE 방이 30분 스윕에도 남아 영구 교착이 된다
    /// (그 예외 주석 참고).
    ///
    /// 에러 본문은 한 번 읽어 들고 넘긴다(`readApiError`).
    /// 복구 조회는 없다: 서버는 검사를 **먼저** 하고 방을 만들므로, 실패했으면 만들어진 방이 없다
    /// (확인할 것이 없다 — `finishParty` 와 같은 사정이다).
    public func createParty(request: NewParty) async throws -> Ride {
        do {
            return try await api.openParty(request: request.toRequestDto()).toRide()
        } catch where isCancellation(throwable: error) {
            // 취소는 되던져 화면 이탈이 에러로 보이지 않게 한다.
            throw error
        } catch {
            throw partyOpenException(failure: error, error: error.readApiError())
        }
    }

    /// 합류 응답은 더 이상 방 상세가 아니다(Backend #213) — 상태·인원만 담긴 `PartyStatus` 다
    /// (지문 필드는 `04f6be7` 에서 빠졌다).
    ///
    /// 성공 경로에서는 세션을 보지 않는다: 응답에 멤버 목록이 없어 "누가 나인지"를 판정할 거리가 없다.
    /// 동승자 목록은 `getPartyDetail` 이나 `observePartyEvents` 의 첫 스냅샷으로 받는다.
    ///
    /// 실패는 전부 `PartyJoinException` 으로 좁힌다 — 그중 **「이미 참여 중」 409 는 복구를 시도한다**
    /// (`recoverMembership`).
    public func joinParty(partyId: Int64) async throws -> PartyStatus {
        do {
            return try await api.joinParty(partyId: partyId).toPartyStatus()
        } catch where isCancellation(throwable: error) {
            // 취소는 되던져 화면 이탈이 에러로 보이지 않게 한다.
            throw error
        } catch {
            // 에러 본문은 한 번 읽어 들고 다닌다.
            let apiError = error.readApiError()
            let joined = PartyJoinException.isAlreadyJoinedCode(code: apiError?.code)
                ? try await recoverMembership(partyId: partyId)
                : nil
            throw partyJoinException(failure: error, error: apiError, joinedStatus: joined)
        }
    }

    /// 「이미 참여 중입니다」 409 가 **이 방**을 가리키는지 확인해, 그렇다면 그 방의 현재 상태를 돌려준다.
    ///
    /// 이 확인이 필요한 이유는 두 가지다.
    /// 1. 서버가 두 경우를 **구분해 주지 않는다** — 재합류도, 다른 방에 있는 것도 똑같이
    ///    `ALREADY_JOINED_OTHER_PARTY` 다(`PartyJoinException.isAlreadyJoinedCode` 주석).
    /// 2. 합류는 서버가 **멤버 추가를 먼저 커밋**하고 응답을 만든다. 그 응답을 앱이 놓치면(역직렬화 실패·
    ///    네트워크 끊김) 서버에는 들어가 있는데 화면은 실패로 끝나고, 재시도는 409 로 막힌다 —
    ///    그대로 두면 **30분 스윕 전까지 그 계정이 어떤 방에도 못 들어간다.**
    ///
    /// 판정 근거는 추측이 아니라 증거다: 방 상세의 members 에 내 publicId 가 있는지 본다
    /// (`isMe` 판정은 `getPartyDetail` 과 같은 매퍼·같은 세션 uuid 를 쓴다). 상세 조회까지 실패하면
    /// 복구를 포기하고 null 을 돌려준다 — 없는 멤버십을 있다고 하면 더 나쁘다.
    ///
    /// 취소는 실패가 아니라 되던진다(이 파일의 다른 호출과 같은 규칙) — 화면을 떠난 합류가
    /// 「합류 실패」로 보이면 안 된다.
    private func recoverMembership(partyId: Int64) async throws -> PartyStatus? {
        let ride: Ride
        do {
            ride = try await getPartyDetail(partyId: partyId)
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            return nil
        }
        if !ride.members.contains(where: { $0.isMe }) { return nil }
        return PartyStatus(status: ride.status, currentMembers: ride.members.count)
    }

    /// 나가기. **403 `NOT_PARTY_MEMBER` 는 성공으로 되돌린다** — `recoverMembership` 과 대칭인 처방이다.
    ///
    /// 되돌리는 근거: 서버 `Party.leave` 는 「멤버인가」를 먼저 보므로 그 403 은 **내가 이 방에 없다**는
    /// 뜻이고, 나가기의 목표가 정확히 그 상태다. 되돌리지 않으면 204 응답이 유실된 사용자가(터널·타임아웃)
    /// 「나가지 못했어요」를 보고 다시 눌러 **같은 문구의 403** 을 맞는다 — 로컬 기억과 홈 배너는 그 방을
    /// 계속 들고 있으니 화면상 나는 아직 그 방에 있고, 벗어날 길이 없다.
    ///
    /// 합류와 달리 **상세 조회로 확인하지 않는다**: 합류는 「이 방인가 다른 방인가」를 서버가 구분해 주지
    /// 않아 증거가 필요했지만, 이 403 은 그 자체로 「이 방에 내가 없다」를 말한다. 덧붙여 방 상세에는
    /// 참여자 검사가 없어(`PartyMembershipLostException` 주석) 읽어도 멤버십을 되묻지 못한다.
    ///
    /// 나머지 실패는 `PartyLeaveException` 으로 좁힌다 — 409 `PARTY_NOT_RECRUITING` 은 「매칭이 시작돼
    /// 나갈 수 없다」라서 재시도 안내와 **다음 행동이 다르다**.
    public func leaveParty(partyId: Int64) async throws {
        do {
            try await api.leaveParty(partyId: partyId)
        } catch where isCancellation(throwable: error) {
            // 취소는 되던져 화면 이탈이 에러로 보이지 않게 한다.
            throw error
        } catch {
            // 에러 본문은 한 번 읽어 들고 다닌다.
            let apiError = error.readApiError()
            // 이미 나갔다 = 나가기는 "실패"가 아니라 "이미 됨"이다.
            if apiError?.code == PartyLeaveException.NOT_PARTY_MEMBER { return }
            throw partyLeaveException(failure: error, error: apiError)
        }
    }

    /// 실패를 전부 `PartyFinishException` 으로 좁힌다 — **403 과 409 가 각각 두 가지 뜻**이라
    /// 화면이 상태 코드만으로는 안내 문구를 가를 수 없다(그 예외 주석 참고).
    ///
    /// 에러 본문은 한 번 읽어 들고 넘긴다(`readApiError`).
    /// 합류와 달리 멤버십 복구 조회는 없다: 완료는 서버가 **검사를 먼저** 하고 상태를 바꾸므로,
    /// 실패했으면 방은 그대로다(확인할 것이 없다).
    public func finishParty(partyId: Int64) async throws {
        do {
            try await api.finishParty(partyId: partyId)
        } catch where isCancellation(throwable: error) {
            // 취소는 되던져 화면 이탈이 에러로 보이지 않게 한다.
            throw error
        } catch {
            throw partyFinishException(failure: error, error: error.readApiError())
        }
    }

    // 빈 목록은 성공이다 — 양쪽 300m 를 동시에 만족하는 방이 없다는 사실일 뿐이라 예외로 올리지 않는다.
    // summary 가 없는 항목만 버린다(방 id 가 없으면 탭해도 갈 곳이 없다).
    public func findRealtimeCandidates(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> [MatchCandidate] {
        let request = RealTimeMatchingRequestDto(
            departureLat: departureLat,
            departureLng: departureLng,
            // 요청 쪽 필드명은 destLat/destLng 다 — 응답 쪽(destinationLat)과 다르다.
            destLat: destinationLat,
            destLng: destinationLng
        )
        do {
            return try await api.getRealtimeCandidates(request: request).compactMap { $0.toMatchCandidate() }
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            throw realtimeMatchException(failure: error, error: error.readApiError())
        }
    }

    public func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver {
        try await api.getAssignedDriver(partyId: partyId).toAssignedDriver()
    }

    public func reportEmergency(partyId: Int64?) async throws -> Int64 {
        guard let report = reportApi else {
            throw IllegalStateException("신고 API가 아직 연결되지 않았어요 (AppContainer 배선 필요)")
        }
        // 실측 좌표. 측위 실패(권한 없음·타임아웃)는 신고를 막지 않는다 — 좌표만 null 로 보낸다.
        let location: (Double, Double)?
        do {
            location = try await currentLocation()
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            location = nil
        }
        return try await runReportCall("긴급 신고 저장에 실패했어요") {
            try await report.report(
                request: ReportRequestDto(
                    partyId: partyId,
                    latitude: location?.0,
                    longitude: location?.1
                )
            ).reportId
        }
    }

    public func confirmEmergencyCall(called: Bool) async throws {
        guard let report = reportApi else {
            throw IllegalStateException("신고 API가 아직 연결되지 않았어요 (AppContainer 배선 필요)")
        }
        try await runReportCall("112 통화 결과 저장에 실패했어요") {
            try await report.confirmCallResult(request: CallResultRequestDto(called: called))
        }
    }

    // 신고 흐름의 계약: 어떤 원인(HTTP 4xx/5xx, 네트워크, 직렬화)이든 한국어 메시지의
    // IllegalStateException 하나로 전파한다. 화면은 이 실패를 "저장 실패 플래그"로만 다루고
    // 112 다이얼은 무조건 연다 (통화 최우선). 취소는 삼키지 않고 그대로 올린다.
    private func runReportCall<T>(_ message: String, _ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            throw IllegalStateException(message, cause: error)
        }
    }

    // 백엔드가 POST 로 바뀌어 열린 엔드포인트. 응답 폴리라인 필드는 route 가 아니라 path 다.
    public func previewRoute(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> RouteEstimate {
        try await api.previewRoute(
            request: routeRequestDto(
                departureLat: departureLat,
                departureLng: departureLng,
                destinationLat: destinationLat,
                destinationLng: destinationLng
            )
        ).toRouteEstimate()
    }
}

/// 방 생성 실패 → `PartyOpenException`. presentation 이 HTTP 를 알 필요가 없게 하는 경계다.
///
/// `PartyMappers.swift` 의 `partyJoinException`·`partyFinishException` 과 **같은 모양**이지만 그 파일이
/// 아니라 여기 있다 — 원본의 파일 배치를 따랐다. 나중에 세 함수를 한곳에 모으는 쪽이 낫다.
///
/// `error` 는 이미 읽어 둔 본문(`readApiError`)이다 — 여기서 다시 읽지 않는다. 합류의 `isNetwork` 같은
/// 구분은 두지 않는다: 이 액션은 응답을 못 받은 실패와 모르는 코드의 **대응이 같다**(일반 문구 = 잠시 후
/// 다시 시도). 쓰지 않을 구분을 노출하면 나중에 네트워크 실패에 「핀을 옮겨 주세요」가 붙는 식으로 어긋난다.
private func partyOpenException(
    failure: any Error,
    error: ApiErrorDto?
) -> PartyOpenException {
    if let failure = failure as? PartyOpenException { return failure }

    if let http = failure as? HttpException {
        return PartyOpenException(
            code: error?.code,
            serverMessage: error?.message,
            httpStatus: http.code(),
            cause: failure
        )
    }

    // 응답 자체를 못 받았다(연결 거부·타임아웃·DNS) 또는 그 밖의 실패. 서버가 말해 준 사유가 없으므로
    // code 는 null 이고, 화면은 일반 문구로 안내한다.
    return PartyOpenException(code: nil, serverMessage: nil, cause: failure)
}

/// 나가기 실패 → `PartyLeaveException`. `partyOpenException` 과 같은 자리·같은 이유의 경계다.
///
/// **403 `NOT_PARTY_MEMBER` 는 여기까지 오지 않는다** — 호출부가 그 전에 성공으로 되돌린다
/// (`RemoteRideRepository.leaveParty`). 그 되돌림을 이 함수 안으로 옮기지 말 것: 예외를 만드는 자리가
/// "실패가 아님"까지 판정하면 호출부가 성공 경로로 빠질 길이 없다.
private func partyLeaveException(
    failure: any Error,
    error: ApiErrorDto?
) -> PartyLeaveException {
    if let failure = failure as? PartyLeaveException { return failure }

    if let http = failure as? HttpException {
        return PartyLeaveException(
            code: error?.code,
            serverMessage: error?.message,
            httpStatus: http.code(),
            cause: failure
        )
    }

    return PartyLeaveException(code: nil, serverMessage: nil, cause: failure)
}
