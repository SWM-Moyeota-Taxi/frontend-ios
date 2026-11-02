/// 경로 기준: matching/interfaces/PartyController.java
/// (@RequestMapping("/api/v1") + 메서드별 "/matching/...").
/// 주의: backend/http/matching.http 는 v1 이 없는 옛 경로 + 옛 필드명(hostId)이라 신뢰하지 않는다.
///
/// **여기 전부가 토큰 필수다.** 목록·상세 조회까지 포함해 예외가 없다
/// (Security 가 `/api/v1/auth/` 하위를 뺀 전 경로에 `anyRequest().authenticated()` 를 건다).
/// 미로그인 상태에서 부르면 화면에 데이터 대신 401 에러가 뜨므로,
/// 이 API 를 쓰는 화면은 로그인 뒤에만 열려야 한다.
public protocol MatchingApi: Sendable {
    func getParties() async throws -> PartyListResponse

    /// 지도 화면 범위(남서·북동 모서리) 안의 ACTIVE 방 목록.
    /// 전체 목록과 **경로가 같고** 서버(PartyController.listWithin)가 `params={swLat,swLng,neLat,neLng}`
    /// 유무로 핸들러를 고른다 — 4개 중 하나라도 빠지면 전체 목록 핸들러로 떨어진다.
    /// 응답 아이템에는 departureLat/departureLng 가 포함된다.
    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> PartyListResponse

    /// 방 상세. 멤버 목록·요금·경로 폴리라인까지 전부 담긴다(`PartyController.detail`).
    /// SSE `connected` 이벤트의 data 와 **같은 모양**이라 DTO·매퍼를 공유한다.
    ///
    /// 서버 메서드에 `@CurrentUser` 가 없지만 **토큰은 필수다** — Security 가 `/api/v1/auth/` 밖
    /// 전 경로에 `anyRequest().authenticated()` 를 건다. 참여자 검사는 없다.
    ///
    /// **주기 조회(25 배차 상태·26 운행 중)가 부르는 것도 이 호출이다.** 전용 상태 조회
    /// `GET /rooms/{partyId}/status` 는 백엔드에서 **삭제됐다**(`04f6be7`) — 지금 부르면 404 다.
    /// 그 호출은 서버 쿼리 1개였고 이건 **3개**(방 + 멤버 요약 + 탑승 횟수)에 route 까지 실으므로,
    /// 부르는 화면은 간격을 벌려야 한다(부하테스트에서 상세 폴링이 전체 요청의 45% — Backend #177).
    func getPartyDetail(partyId: Int64) async throws -> PartyDetailResponse

    /// 방 생성. **방장은 이제 Bearer 토큰이 정한다**
    /// (`PartyController.open(@CurrentUser Long memberId, @RequestBody OpenPartyRequest request)`).
    ///
    /// 서버 record 에 `creatorId` 필드가 남아 있긴 하지만 `toCommand(creatorMemberId)` 가 이를 버리고
    /// 토큰 주체를 쓴다 — 구버전 호환용 잔재다. 그래서 앱은 아예 보내지 않는다
    /// (실측: creatorId 없이 200, 토큰 주체가 방장으로 기록됨).
    /// 리포트 22번 D-5("내가 만든 방에 내가 없는" 상태)는 이것으로 해소됐다.
    ///
    /// **반경도 요청에 없다** — 서버가 `OpenPartyRequest` 에서 빼고 고정값(500m)을 쓴다
    /// (Backend `a668aee`, Swagger 「반경은 서버 고정값(500m)」). 400 목록에서 `INVALID_RADIUS` 도 빠졌다.
    func openParty(request: OpenPartyRequestDto) async throws -> OpenPartyResponse

    /// 합류. 요청 본문은 없다.
    ///
    /// **응답이 방 상세에서 `PartyStatusResponse{status, currentMembers}` 로 바뀌었다**
    /// (Backend #213, `PartyController.join` 의 반환 타입). 즉 **동승자 목록이 오지 않는다** —
    /// 필요하면 `getPartyDetail` 을 따로 불러야 한다(서버 Swagger 는 "동승자 목록은 SSE 구독(/events)의
    /// connected 로 받는다" 로 갱신됐다 — `04f6be7`).
    ///
    /// 그 `04f6be7` 에서 **`fingerprint` 필드도 빠졌다** — 응답은 이제 두 값뿐이다. 서버가 아직 옛
    /// 버전이라 지문을 실어 보내도 디코더가 모르는 키를 흘린다(`MoyeotaJSON`).
    ///
    /// 응답의 `status` 는 합류 **직후**의 방 상태다 — 내가 마지막 자리를 채웠으면 서버가 그 자리에서 정원 충족
    /// 처리까지 끝내고 `COMPLETED`(1차 배포) 또는 `MATCHING`(기사 모드)을 돌려준다.
    ///
    /// 합류자는 **Bearer 토큰에서 추출**된다(`PartyController.join(@PathVariable Long partyId, @CurrentUser Long memberId)`)
    /// — 경로의 memberId 는 사라졌다. 토큰 없이 호출하면 401 `{"code":"USER005","message":"로그인이 필요합니다."}`.
    func joinParty(partyId: Int64) async throws -> PartyStatusResponse

    /// 나가기. 204 No Content — 응답 본문이 없다. 나가는 주체는 Bearer 토큰이 정한다.
    ///
    /// 이전에 붙어 있던 더미 `/0` 세그먼트는 **사라졌다** — 백엔드가 매핑을
    /// `@DeleteMapping("/matching/leave/{partyId}")` 로 정리했다.
    /// 실측: `/leave/{id}` → 204, `/leave/{id}/0` → 404. 옛 형태를 되살리면 조용히 404 다.
    func leaveParty(partyId: Int64) async throws

    /// 기사 없이 합승 종료 — 1차 배포 모드 전용. 204. `PartyController.finish`.
    /// COMPLETED(정원 참) 방에서만 되고, 참여자 누구든 한 명이 부르면 방 전체가 FINISHED 다.
    func finishParty(partyId: Int64) async throws

    /// 200 / 404 `PARTY_NOT_FOUND`·`ASSIGNED_DRIVER_NOT_FOUND` / **409 `DRIVER_NOT_ASSIGNED`**(배정 전).
    /// 예전 주석의 「IllegalArgumentException → 500」은 옛 서버 얘기다 — 지금은 `PartyApplicationService.getAssignDriver`
    /// 가 `BusinessException(MatchingErrorCode.DRIVER_NOT_ASSIGNED)` 를 던지고 전역 핸들러가 409 로 답한다.
    /// 호출자는 배정 전에 부르지 말아야 한다(`shouldFetchDriverInfo`).
    func getAssignedDriver(partyId: Int64) async throws -> DriverSummaryResponse

    /// 방을 만들기 전 출발·도착 좌표만으로 예상 요금·소요시간·경로를 미리 본다.
    ///
    /// 백엔드가 `@PostMapping` + `@RequestBody RouteRequest` 로 바뀌어 열린 엔드포인트다
    /// (이전 `@GetMapping` + body 조합은 요청 자체를 만들 수 없어 호출 불가였다).
    /// 응답 폴리라인 필드명이 **path** 다 — 방 상세/생성 응답의 `route` 와 이름이 다르니 주의.
    func previewRoute(request: RouteRequestDto) async throws -> RouteEstimateResponse

    /// 내 출발·도착 좌표로 **걸어서 가까운 방**을 추천받는다(서버가 양쪽 300m 안에서 고르고 OSRM
    /// 도보 시간 합으로 정렬해 최대 5개).
    ///
    /// **조회인데 POST 다** — 좌표 4개를 바디로 받는 서버 설계라 캐시되지 않는다.
    /// 응답 **최상위가 배열**이고 빈 배열이 정상이다.
    ///
    /// 실패는 넷이다: 400 `OUT_OF_SERVICE_AREA`(좌표가 서비스 지역 밖 **또는 요청 필드명 오타**),
    /// 401, 409 `ALREADY_JOINED_OTHER_PARTY`(이미 방에 들어가 있으면 추천 자체가 막힌다),
    /// 502 `ROUTE_SEARCH_FAILED`(OSRM 실패).
    func getRealtimeCandidates(request: RealTimeMatchingRequestDto) async throws -> [MatchCandidateResponse]

    // 삭제된 엔드포인트: matching/ready(POST·DELETE), matching/start(POST).
    // 정원이 차면 서버가 스스로 매칭을 시작하므로 앱이 트리거하지 않는다.
}

enum MatchingApiRoute: String, CaseIterable, ApiRouteSet {
    case getParties, getPartiesWithin, getPartyDetail, openParty, joinParty, leaveParty, finishParty
    case getAssignedDriver, previewRoute, getRealtimeCandidates

    var route: ApiRoute {
        switch self {
        case .getParties: .GET("api/v1/matching/rooms")
        case .getPartiesWithin: .GET("api/v1/matching/rooms", query: ["swLat", "swLng", "neLat", "neLng"])
        case .getPartyDetail: .GET("api/v1/matching/rooms/{partyId}")
        case .openParty: .POST("api/v1/matching/rooms")
        case .joinParty: .POST("api/v1/matching/rooms/{partyId}/join")
        case .leaveParty: .DELETE("api/v1/matching/leave/{partyId}")
        case .finishParty: .POST("api/v1/matching/rooms/{partyId}/finish")
        case .getAssignedDriver: .GET("api/v1/matching/rooms/{partyId}/driver")
        case .previewRoute: .POST("api/v1/matching/routes")
        case .getRealtimeCandidates: .POST("api/v1/matching/rooms/realtime")
        }
    }
}

struct RestMatchingApi: MatchingApi {
    let rest: RestClient

    func getParties() async throws -> PartyListResponse {
        try await rest.call(MatchingApiRoute.getParties.route)
    }

    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> PartyListResponse {
        try await rest.call(
            MatchingApiRoute.getPartiesWithin.route,
            query: [
                "swLat": queryValue(swLat),
                "swLng": queryValue(swLng),
                "neLat": queryValue(neLat),
                "neLng": queryValue(neLng),
            ]
        )
    }

    func getPartyDetail(partyId: Int64) async throws -> PartyDetailResponse {
        try await rest.call(MatchingApiRoute.getPartyDetail.route, path: ["partyId": partyId])
    }

    func openParty(request: OpenPartyRequestDto) async throws -> OpenPartyResponse {
        try await rest.call(MatchingApiRoute.openParty.route, body: request)
    }

    func joinParty(partyId: Int64) async throws -> PartyStatusResponse {
        try await rest.call(MatchingApiRoute.joinParty.route, path: ["partyId": partyId])
    }

    func leaveParty(partyId: Int64) async throws {
        try await rest.callUnit(MatchingApiRoute.leaveParty.route, path: ["partyId": partyId])
    }

    func finishParty(partyId: Int64) async throws {
        try await rest.callUnit(MatchingApiRoute.finishParty.route, path: ["partyId": partyId])
    }

    func getAssignedDriver(partyId: Int64) async throws -> DriverSummaryResponse {
        try await rest.call(MatchingApiRoute.getAssignedDriver.route, path: ["partyId": partyId])
    }

    func previewRoute(request: RouteRequestDto) async throws -> RouteEstimateResponse {
        try await rest.call(MatchingApiRoute.previewRoute.route, body: request)
    }

    func getRealtimeCandidates(request: RealTimeMatchingRequestDto) async throws -> [MatchCandidateResponse] {
        try await rest.call(MatchingApiRoute.getRealtimeCandidates.route, body: request)
    }
}
