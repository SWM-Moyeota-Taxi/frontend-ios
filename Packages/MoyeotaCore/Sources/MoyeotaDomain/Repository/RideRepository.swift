public protocol RideRepository: Sendable {
    func getNearbyParties() -> [Ride]

    // 조회 — GET /api/v1/matching/rooms, /rooms/{partyId}
    /// 목록 응답에는 좌표·요금·경로가 없다(partyId/출발/도착/인원/정원/상태만). 상세는 `getPartyDetail`.
    func getParties() async throws -> [Ride]

    /// 지도 범위(남서 `swLat`/`swLng` ~ 북동 `neLat`/`neLng`) 안의 모집 중 방 목록.
    /// GET /api/v1/matching/rooms?swLat=&swLng=&neLat=&neLng=
    ///
    /// `getParties` 와 같은 `Ride` 목록을 돌려주되, **출발 좌표(originLat/originLng)가 채워져 있다**
    /// — 지도 핀을 찍는 데 쓴다. 도착 좌표·요금·경로는 여전히 없으니 `getPartyDetail` 로 받는다.
    func getPartiesWithin(
        swLat: Double,
        swLng: Double,
        neLat: Double,
        neLng: Double
    ) async throws -> [Ride]

    /// GET /api/v1/matching/rooms/{partyId} — 방 상세. 참여자가 아니어도 되고(403 없음),
    /// 방이 없으면 404 PARTY_NOT_FOUND.
    ///
    /// **주기 조회가 필요한 화면(25 배차 상태·26 운행 중)은 이걸 부른다.** 예전에는 상태·인원·지문만
    /// 담은 가벼운 `GET /rooms/{id}/status` 를 읽고 지문이 달라진 주기에만 상세를 읽었지만,
    /// 그 엔드포인트가 백엔드에서 사라졌다(Backend `04f6be7` — 매칭방 변화는 SSE 가 유일한 전달 경로가
    /// 되면서 폴링용으로 만든 상태 조회와 지문이 쓰이지 않게 됐다).
    ///
    /// 그래서 **이 호출은 비싸다**: 서버가 쿼리 3개(방 + 멤버 요약 + 탑승 횟수)를 돌리고 경로 폴리라인까지
    /// 실어 온다. 부하테스트에서 방 상세 폴링이 전체 요청의 45% 였다(Backend #177). 주기 조회에 쓰는
    /// 화면은 **간격을 충분히 벌리고**(25·26 은 7·8초), 받은 `Ride` 가 들고 있던 것과 `==` 로 같으면
    /// 화면 상태를 갱신하지 않아야 한다(불필요한 화면 갱신 방지).
    func getPartyDetail(partyId: Int64) async throws -> Ride

    /// `getPartyDetail` 과 **같은 요청**이되 방 순번(`PartyDetail.version`)까지 돌려준다.
    ///
    /// 왜 따로 두는가: 상세를 읽는 곳은 8군데인데 순번이 필요한 건 **SSE 변경분을 병합하는 21 대기
    /// 화면 하나**다. 반환 타입을 바꾸면 나머지 일곱 곳이 쓰지도 않을 `.ride` 를 붙여야 한다.
    /// 순번은 방의 성질이 아니라 **프레임의 순서 표식**이라 `Ride` 안에 넣을 수도 없다 — 넣으면
    /// 25·26 이 "바뀌었나"를 보는 `Ride` 끼리의 `==` 비교가 순번 때문에 매번 달라진다.
    ///
    /// 쓰는 곳은 `PartyEvent` 의 틈(gap) 메우기다. 변경분이 `PartyEvent.snapshot` 보다 먼저 왔거나
    /// 중간 프레임을 놓쳤을 때 이걸로 다시 읽고, 읽어 온 순번을 기준으로 삼는다.
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail

    /// 내 출발·도착 좌표로 **걸어서 가까운 방**을 추천받는다(`POST /matching/rooms/realtime`).
    ///
    /// `getPartiesWithin` 과 목적이 다르다 — 저쪽은 "지도에 보이는 방 전부"(뷰포트), 이쪽은
    /// "양쪽에서 걸어갈 만한 방 몇 개"다. 서버가 출발지·도착지 **각각** 300m 안에서 고른 뒤
    /// 도보 시간 합으로 정렬해 **0~5개**를 준다.
    ///
    /// - **빈 목록은 정상이다.** 양쪽 300m 를 동시에 만족해야 해서 초기에는 그게 기본 상태다.
    ///   에러로 다루지 말 것.
    /// - **재정렬하지 말 것.** 받은 순서가 서버의 도보 시간 순이다.
    /// - **주기 조회에 쓰지 말 것.** 후보마다 서버가 OSRM 을 2번 부른다. 좌표가 확정된 순간 1회다.
    ///
    /// 실패는 `RealtimeMatchException` 으로 좁혀 던진다 — 사유마다 화면이
    /// 달라야 하기 때문이다(엔진 장애는 방 만들기로 흘리고, 이미 방이 있으면 섹션 자체를 숨긴다).
    func findRealtimeCandidates(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> [MatchCandidate]

    /// 이 방의 **변경분(delta) 스트림**(SSE `GET /api/v1/matching/rooms/{partyId}/events`).
    ///
    /// 수집하는 동안만 연결되고, 끊기면 알아서 다시 붙는다. 멤버가 아니거나(403) 방이 없으면(404)
    /// 스트림이 끝난다(재시도하지 않는다). 방이 닫히면 `PartyEvent.closed` 뒤에 끝난다.
    ///
    /// **받는 순서는 늘 `PartyEvent.snapshot` → 그 뒤의 변경분이다.** 구독하자마자 서버가 방 상세 전체를
    /// 스냅샷으로 주고, 그 뒤로 `PartyEvent.memberJoined`·`PartyEvent.memberLeft` 만 온다. 끊겨 다시
    /// 붙을 때도 **스냅샷이 먼저** 오므로, 그동안 놓친 변화는 거기서 전부 보정된다.
    ///
    /// 그래서 **화면은 평상시 폴링도, 재연결 직후의 catch-up 조회도 하지 않아야 한다** — 이번 설계의 핵심이다.
    /// 신호마다 `getPartyDetail` 을 다시 읽던 예전 구조(서버 `changed` 이벤트)는 **없어졌다**:
    /// 대기 화면의 상세 폴링이 서버 요청의 45% 였고(Backend #177), 변경분이 오는 지금은 그 재조회가
    /// 같은 내용을 다시 받는 낭비다. 폴링은 `PartyEvent.disconnected` 동안의 **폴백**으로만 남긴다
    /// (채팅 소켓과 같은 정책 — 살아 있으면 0회, 죽었을 때만).
    ///
    /// 다시 읽어야 하는 경우는 하나뿐이다: `PartyEvent.memberLeft` 의 publicId 가 null 일 때
    /// (누가 나갔는지 서버도 모른다).
    ///
    /// ⚠️ **같은 방을 두 곳에서 동시에 수집하지 말 것.** 서버가 구독을 받을 때 **같은 사용자의 기존 연결을
    /// 먼저 끊는다**(`PartySseRegistry.closeMember`) — 한 화면이 두 번 수집하면 두 연결이 서로를 끊고
    /// 번갈아 재연결하는 무한 루프가 된다. 수집은 화면(ViewModel)당 **정확히 한 번**이다.
    ///
    /// ⚠️ **이 스트림은 best-effort 다.** 서버가 커밋 후 단일 스레드 큐로 발행하고 **실패하면 재발행하지
    /// 않는다**(Redis Pub/Sub 도 at-most-once). 그래서 "SSE 가 유일한 근거"인 화면은 만들지 않는다 —
    /// 끊김 동안의 폴백 폴링과, 재연결 `PartyEvent.snapshot` 의 전체 보정이 반드시 함께 있어야 한다.
    ///
    /// **배차·운행 전이는 이 스트림에 오지 않는다** — 서버 발행처가 참여·퇴장·종료뿐이라
    /// MATCHING→DRIVER_ASSIGNED→IN_RIDE→FINISHED 는 신호가 없다(FCM 도 `DRIVER_ARRIVED` 하나뿐).
    /// 그 단계의 화면(25·26)은 폴링을 유지하며, 읽는 대상은 `getPartyDetail` 이다 — 그 화면들이 쓰던
    /// 가벼운 상태 조회가 없어졌기 때문이다(Backend `04f6be7`).
    ///
    /// **흐름은 SSE 403 `NOT_PARTY_MEMBER` 에서 `PartyMembershipLostException` 으로 예외 종료한다.**
    /// 「스트림이 끝났다」와 반드시 구분해야 한다 — 전자는 호출부가 **화면을 떠나야** 하고, 후자는
    /// 폴백 폴링으로 넘어가면 된다. 둘을 뭉개면 내가 멤버가 아닌 방을 「같이 탈 사람을 찾고 있어요」로
    /// 영원히 그린다(상세 조회에는 참여자 검사가 없어 계속 성공한다).
    ///
    /// ⚠️ **수집을 취소해도 `for try await` 는 오류 없이 끝난다.** 원본 `collect` 는
    /// `CancellationException` 을 던져 다음 줄을 지나지 않지만, 여기서는 루프 뒤로 그대로 내려가 종결과 똑같아
    /// 보인다. 루프 뒤의 코드가 「스트림이 종결로 끝났다」를 뜻하면 먼저 `try Task.checkCancellation()` 을 부른다.
    /// 안 그러면 대기 화면이 가려질 때마다 `streamEnded` 가 서서 복귀해도 SSE 를 다시 붙이지 않고 폴백 폴링에 머문다.
    ///
    /// 기본 구현은 아무것도 내지 않는다(더미·테스트 저장소).
    func observePartyEvents(partyId: Int64) -> AsyncThrowingStream<PartyEvent, any Error>

    // 액션 — 성공 후 화면이 갱신해야 하는 대상은 아래 주석 참고.
    /// POST /api/v1/matching/rooms. 생성된 방을 그대로 돌려주므로 MatchWaiting 으로 바로 넘길 수 있다.
    ///
    /// 생성자는 **로그인 토큰이 정한다**(@CurrentUser) — 합류·나가기와 같다. 요청 본문에 사용자 id 를
    /// 싣지 않는다. 생성 응답에는 멤버 목록이 없어 인원 수만큼 자리 표시용 멤버가 채워지므로,
    /// 실제 멤버 식별자가 필요하면 `getPartyDetail` 로 다시 읽는다.
    ///
    /// 앱이 정하는 조건은 **좌표·라벨·정원뿐**이다(`NewParty`) — 반경은 서버가 고정값으로 정한다.
    ///
    /// 실패는 모두 `PartyOpenException` 으로 올라온다(409 `ALREADY_JOINED_OTHER_PARTY` /
    /// 400 `SAME_DEPARTURE_DESTINATION`·`OUT_OF_SERVICE_AREA`·`INVALID_CAPACITY`·`INVALID_ROUTE_ESTIMATE` /
    /// 502 `ROUTE_SEARCH_FAILED` / 네트워크). 화면은 그 프로퍼티로 분기한다 — **한 문구로 뭉개면 안 된다.**
    /// 409 는 「잠시 후 다시 시도」가 **영구히 거짓**이고(아무도 합류하지 않은 ACTIVE 방은 서버 스윕
    /// 대상이 아니라 계정이 계속 막힌다), 400 좌표·정원은 사용자가 **고쳐야** 하는 값이다.
    func createParty(request: NewParty) async throws -> Ride

    /// 합류. POST /api/v1/matching/rooms/{partyId}/join.
    /// 합류자는 **로그인 토큰이 정한다**(@CurrentUser) — memberId 를 넘기지 않는다.
    ///
    /// **돌려주는 것은 방 상세가 아니라 합류 직후의 `PartyStatus`(상태·인원)다**(Backend #213).
    /// 예전엔 응답이 곧 방 상세라 그대로 다음 화면에 넘길 수 있었지만, 이제 **동승자 목록이 오지 않는다** —
    /// 목록이 필요하면 `getPartyDetail` 을 따로 불러야 한다. 다만 합류 후 바로 대기 화면(21)으로 가는
    /// 흐름이라면 그 화면이 구독하는 `observePartyEvents` 의 첫 `PartyEvent.snapshot` 이 상세 전체를
    /// 주므로, 재조회를 거기에 맡기는 선택도 가능하다.
    ///
    /// 돌려주는 `PartyStatus.status` 로 "내가 마지막 자리를 채웠는지"를 알 수 있다 — 정원이 차면 서버가
    /// 그 자리에서 정원 충족 처리까지 끝낸다(COMPLETED, 기사 모드면 이어서 MATCHING). 앱은 트리거하지 않는다.
    ///
    /// 실패는 모두 `PartyJoinException` 으로 올라온다(401 미로그인 / 409 `ALREADY_JOINED_OTHER_PARTY`·
    /// `PARTY_FULL`·`PARTY_CLOSED` / 404 `PARTY_NOT_FOUND` / 네트워크). 화면은 그 프로퍼티로 분기한다.
    ///
    /// **그중 하나는 실패가 아니다.** `PartyJoinException.isAlreadyInThisParty` 가 true 면 **서버에는
    /// 내가 이미 그 방 멤버로 들어가 있다** — 데이터 계층이 방 상세로 확인한 결과이고,
    /// `PartyJoinException.joinedStatus` 에 그 방의 현재 상태가 담겨 온다. 화면은 이 경우를
    /// **합류 성공과 같은 길로** 보내야 한다. 그러지 않으면 그 계정은 재시도도 409, 다른 방도 409 라
    /// 30분 스윕 전까지 아무 방에도 못 들어간다(합류는 서버가 멤버 추가를 먼저 커밋한다).
    func joinParty(partyId: Int64) async throws -> PartyStatus

    /// 나가기. DELETE /api/v1/matching/leave/{partyId}. 나가는 주체는 토큰이 정한다.
    /// 성공 시 Explore 목록 재조회 필요.
    ///
    /// 마지막 멤버가 나가면 방은 CANCELED 로 닫힌다(실측).
    ///
    /// 그 방의 멤버가 아니면 서버는 403 `NOT_PARTY_MEMBER` 를 주는데, **그 403 은 실패로 올라오지
    /// 않는다** — 데이터 계층이 성공으로 되돌린다. 「이미 나갔다」와 「나가기 성공」은 사용자가 할 일이
    /// 같기 때문이다(204 응답이 터널에서 유실되고 재시도하면 바로 이 경우가 된다). `joinParty` 의
    /// `PartyJoinException.isAlreadyInThisParty` 복구와 대칭이다.
    ///
    /// 나머지 실패는 `PartyLeaveException` 이다(409 `PARTY_NOT_RECRUITING` — 매칭이 시작돼 나갈 수 없다 /
    /// 404 `PARTY_NOT_FOUND` / 네트워크).
    func leaveParty(partyId: Int64) async throws

    /// POST /api/v1/matching/rooms/{partyId}/finish (204) — **기사 없이** 합승을 끝낸다.
    /// 1차 배포 모드(`AppConfig.taxiEnabled` = false)에서
    /// 정원이 찬(`COMPLETED`) 방을 닫는다 — 한 명이 닫으면 **모두의** 방이 `FINISHED` 가 된다.
    ///
    /// **방장 전용이다**: Backend #237 이 이 API 를 방장에게만 허용했고, 2026-10-15 **운영에 배포됐다**.
    /// 방장은 저장되는 값이 아니라 **지금 멤버 중 가장 먼저 합류한 사람**이고(`Party.hostId()` =
    /// `min(joinedAt, memberId)`), 방장이 나가면 자동 승계된다.
    ///
    /// **앱은 방장을 식별할 수 있다** — 서버가 멤버마다 `members[].host` 를 내려 준다(Backend #240,
    /// 반영 완료). 내부 PK `hostId` 는 응답에서 제거됐다. 그래서 호출부는 **버튼 노출을 먼저 막고**
    /// (`canFinishParty` = 손으로 닫는 단계 && `Ride.isHostedByMe`), 실패 사유 안내는 그 뒤에 남는
    /// 틈을 받는다 — 승계 신호를 놓치거나 순서가 역전돼 **내 스냅샷이 낡았을** 때 403 이 온다.
    /// **「앱은 방장을 알 수 없다」로 되돌리지 말 것**: 그 서술은 `host` 가 붙기 전의 사실이고,
    /// 그대로 믿으면 방장 게이팅이 근거 없는 추정으로 읽혀 지워진다.
    ///
    /// 실패는 모두 `PartyFinishException` 으로 올라온다 — **403·409 가 각각 두 가지 뜻**이라
    /// (403 `NOT_PARTY_HOST`·`NOT_PARTY_MEMBER` / 409 `PARTY_NOT_COMPLETED`·`DRIVER_ALREADY_ASSIGNED`)
    /// 화면은 상태 코드가 아니라 그 예외의 프로퍼티로 분기한다. 모르는 코드·본문 없음은 code = null 이고
    /// 화면이 일반 문구로 떨어진다.
    func finishParty(partyId: Int64) async throws

    /// GET /api/v1/matching/rooms/{partyId}/driver — 배정된 기사 요약.
    /// 기사 미배정(taxiDriverId == null)이면 서버가 예외를 던지므로 status 가
    /// DRIVER_ASSIGNED/IN_RIDE 일 때만 호출한다. 기사명·별점은 서버에 아직 없다.
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver

    // 긴급 신고 — POST /api/v1/reports, PATCH /api/v1/reports/call-result

    /// 긴급 신고 접수 — 서버가 파티·위치를 저장하고 신고 id 를 반환한다.
    /// 위치는 데이터 계층이 채운다 (주입된 측위 소스에서 실측 — 실패 시 null 전송, 서버가 허용).
    /// 저장 실패 시 한국어 메시지의 `IllegalStateException` 을 던진다 —
    /// 화면은 실패 여부와 무관하게 112 다이얼을 먼저 열어야 한다 (통화 최우선).
    ///
    /// - Parameter partyId: 신고 대상 파티. 화면에서 알 수 없으면 null (서버는 REPORT_NOT_ALLOWED
    ///   응답 — 저장 실패로 처리된다)
    /// - Returns: 서버가 발급한 신고 id (reportId)
    func reportEmergency(partyId: Int64?) async throws -> Int64

    /// 112 다이얼에서 앱 복귀 후 "실제로 통화했는지" 결과를 저장한다.
    /// reportId 는 보내지 않는다 — 서버가 토큰 주체(@CurrentUser)의 신고에 기록한다.
    /// 실패 시 한국어 메시지의 `IllegalStateException` 을 던진다.
    func confirmEmergencyCall(called: Bool) async throws

    /// POST /api/v1/matching/routes — 방을 만들기 전 좌표만으로 보는 경로 미리보기.
    ///
    /// 예상 요금·소요시간과 인코딩 폴리라인(`RouteEstimate.encodedPath`)을 돌려준다.
    /// 이미 만들어진 방의 경로는 `getPartyDetail` 의 `routePolyline` 으로 얻는다.
    func previewRoute(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> RouteEstimate
}

// Kotlin 인터페이스의 기본 구현 자리.
extension RideRepository {
    public func observePartyEvents(partyId: Int64) -> AsyncThrowingStream<PartyEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
