import Foundation
import MoyeotaDomain

// 방 상세의 멤버는 이제 닉네임·프로필 이미지·탑승 횟수까지 서버가 준다(PartyDetailResult.MemberInfo).
// 다만 별점과 인증 배지는 여전히 서버에 값이 없어 0.0 / "" 로 채운다 — 지어내지 않는다.
public func partyStatusToRideStatus(status: String) -> RideStatus {
    switch status {
    case "ACTIVE": return .recruiting
    case "COMPLETED": return .matched
    case "MATCHING": return .dispatching
    // 기사 배정 완료 = 배차 확정. 아직 탑승 전이라 배차 단계로 본다.
    case "DRIVER_ASSIGNED": return .dispatching
    case "IN_RIDE": return .ongoing
    case "FINISHED": return .completed
    // 정상 종료(FINISHED)와 갈라 둔다 — 기사 매칭 3분 타임아웃도 여기로 떨어지는데,
    // 25b 가 「기사님을 찾지 못했어요」를 띄우려면 완료와 구분돼야 한다.
    case "CANCELED": return .canceled
    default: return .recruiting
    }
}

/// 정원으로 나눈 1인당 요금, **10원 단위 반올림**. `estimateFare` 는 경로 전체의 택시 요금이다.
/// 정원이 0 이하이거나 요금이 없으면 0 을 돌려준다(화면이 "-" 로 처리).
///
/// **왜 10원 단위인가.** 정수 나눗셈(절삭)으로 두면 7,900원 ÷ 3인 = 2,633원처럼 **실제로 낼 수 없는
/// 금액을 1원 단위까지 약속**한다. 택시 요금 표기는 10원 단위라 사용자가 기대하는 모양도 그쪽이다.
///
/// **같은 규칙이 16 도착지 확인(모달)에도 적혀 있다**(presentation 의 `farePerPersonWon`).
/// 모듈 경계(data ↔ presentation)를 넘어 이 함수를 부를 수 없어 규칙을 양쪽에 **같은 식으로** 적어
/// 두었다 — 예전에는 모달만 10원 단위로 반올림하고 이 함수는 절삭이라, 같은 방(7,900원·3인)을 16 은 2,630원,
/// 19·22·25 는 2,633원으로 보여 줬다. 두 값이 같아야 한다는 것은 `PartyMappersTest`(data)와
/// `FarePerPersonRuleTest`(presentation)가 **같은 표**로 못 박는다 — 한쪽만 고치면 다른 쪽 테스트가 깨진다.
func farePerPerson(estimateFare: Int?, capacity: Int) -> Int {
    guard let estimateFare, capacity > 0 else { return 0 }
    return roundToInt((Double(estimateFare) / Double(capacity)) / 10.0) &* 10
}

/// Kotlin `Double.roundToInt()` — 정확히 .5 는 양의 무한대 쪽으로 올린다. Swift `rounded()` 는 음수에서 0 의
/// 반대쪽으로 가서 어긋난다.
private func roundToInt(_ value: Double) -> Int {
    let floor = value.rounded(.down)
    return Int(value - floor >= 0.5 ? floor + 1 : floor)
}

/// 멤버 식별자가 없는 응답(목록·생성)에서 인원 수만큼 자리 표시용 멤버를 만든다.
private func placeholderMembers(count: Int) -> [User] {
    (0..<max(count, 0)).map { index in
        User(id: "m\(index)", nickname: "멤버 \(index + 1)", verifiedLabel: "", rating: 0.0, rideCount: 0)
    }
}

extension PartyDetailResponse.MemberInfo {
    /// 방 상세의 멤버 한 명 → 표시용 `User`.
    ///
    /// 서버가 유저 요약 자체를 못 찾으면 `publicId` 부터 전부 null 로 준다.
    /// 그때 id 는 빈 문자열이 되고 닉네임은 `WithdrawnMemberNames.NO_SUMMARY` 다 — 화면은 빈 id 를 탭
    /// 불가로 다뤄야 한다. **탈퇴(soft delete)와는 다른 경우다**: 탈퇴한 사용자는 publicId 가 살아 있고
    /// 닉네임만 서버가 `WithdrawnMemberNames.SERVER_DELETED` 로 가려 보낸다(그쪽은 이 매퍼를 그냥 통과한다).
    ///
    /// `currentUuid` 는 로그인한 사용자의 UUID(`UserSession.currentUserUuid`). publicId 가 JWT `sub` 와
    /// 같은 값이라 이 비교가 곧 "나" 판정이다. 미로그인이거나 요약이 없으면 `User.isMe` 는 false 다
    /// — 둘 다 null 인 경우까지 참이 되지 않도록 publicId 의 null 을 먼저 끊는다.
    ///
    /// 별점(`User.rating`)과 인증 라벨(`User.verifiedLabel`)은 서버에 값이 없어 0.0 / "" 로 고정한다.
    /// 여기서 그럴듯한 값을 지어내면 화면이 가짜 평판을 진짜처럼 보여 준다.
    ///
    /// ### 방장(`User.isHost`)이 서버 응답에 없을 때 ★
    /// 서버 `MemberInfo.host` 는 원시 `boolean` 이라 운영에서는 늘 실린다. 그래도 **누락**(옛 배포를
    /// 보고 있거나 서버가 필드를 빼는 경우)을 false 로 접지 않고 `User.isMe` 로 떨어뜨린다 —
    /// 즉 **나에 대해서만** 방장으로 본다. 틀렸을 때의 대가가 방향마다 다르기 때문이다:
    ///
    /// | 누락 시 선택 | 나에 대해 틀리면 | 남에 대해 틀리면 |
    /// |---|---|---|
    /// | false | 방장이 「합승 완료」를 **못 본다** → 방을 끝낼 길이 없어 30분 만료를 기다려야 한다(복구 불가) |  방장 표시가 빠진다(사소) |
    /// | true | 눌러도 서버가 403 `NOT_PARTY_HOST` 로 막고, 앱은 그걸 **이미 사유별 문구로** 안내한다(복구됨) | 모두가 방장으로 표시된다(오해를 부른다) |
    ///
    /// 그래서 나에 대해서는 true 쪽(= `User.isMe`), 남에 대해서는 false 쪽으로 기운다. 실질적으로
    /// 서버가 `host` 를 말하기 전의 동작(모두에게 버튼을 보여 주고 서버 403 에 맡김)을 **나에게만** 유지하는
    /// 것이고, 방장 판정의 최종 권한은 어느 쪽이든 서버다 — 앱은 입장 순서로 방장을 **셈하지 않는다**.
    ///
    /// 요약 없는 멤버(전 필드 null)에서는 publicId 가 null 이라 `User.isMe` 가 false 이므로 이 폴백도
    /// false 로 떨어진다 — 누군지 모르는 멤버를 방장으로 세우지 않는다.
    fileprivate func toUser(currentUuid: String?) -> User {
        let isMe = publicId != nil && publicId == currentUuid
        return User(
            id: publicId ?? "",
            // 요약이 없는 멤버의 자리값. 서버가 탈퇴로 가린 이름(SERVER_DELETED)은 여기가 아니라
            // 서버가 직접 넣어 보내므로 그대로 흘러간다 — 두 문자열의 출처 구분은 WithdrawnMemberNames 에 있다.
            nickname: nickname ?? WithdrawnMemberNames.NO_SUMMARY,
            verifiedLabel: "",
            rating: 0.0,
            rideCount: rideCount,
            imageUrl: imageUrl,
            isMe: isMe,
            // null = 「서버가 말하지 않았다」. false 와 갈라 두는 이유는 위 표에 있다.
            isHost: host ?? isMe
        )
    }
}

extension PartyListResponse.PartyItem {
    public func toRide() -> Ride {
        Ride(
            id: String(partyId),
            origin: departure,
            destination: destination,
            departureLabel: "",
            capacity: capacity,
            // 목록 응답에는 멤버 식별자가 없고 인원 수만 온다 — 자리 표시용 멤버를 만든다.
            // **인원을 모르면(null) 빈 목록으로 남긴다** — 0 으로 접으면 카드가 「0/3명」이라는 없는 상태를
            // 그린다(이 목록은 `status = 'ACTIVE'` 인 방만 오고 그런 방에는 최소 방장 1명이 있다).
            // `Ride.members` 가 비어 있다 = 인원을 모른다는 규약은 `MatchCandidate` 주석에 적혀 있고,
            // 화면 문구는 `headcountLabel` 이 그 규약대로 「최대 N명」으로 떨어뜨린다.
            members: currentMembers.map(placeholderMembers(count:)) ?? [],
            farePerPerson: 0,
            totalFare: 0,
            status: partyStatusToRideStatus(status: status),
            // 출발 좌표만 목록에 있다(지도 핀용). 도착 좌표·경로·요금은 상세에서 채운다.
            originLat: departureLat,
            originLng: departureLng
        )
    }
}

extension PartyDetailResponse {
    /// `currentUuid` 를 넘기면 멤버 중 본인이 `User.isMe` 로 표시된다. 기본값 null 은 "모름" —
    /// 아무도 나로 표시되지 않는다. 넘기는 쪽은 `RemoteRideRepository` 다.
    public func toRide(currentUuid: String? = nil) -> Ride {
        Ride(
            id: String(id),
            origin: departure,
            destination: destination,
            departureLabel: "",
            capacity: capacity,
            // 방장은 멤버마다 서버가 표시해 준다(`User.isHost`) — 앱이 입장 순서로 셈하지 않는다.
            members: members.map { $0.toUser(currentUuid: currentUuid) },
            farePerPerson: farePerPerson(estimateFare: estimateFare, capacity: capacity),
            totalFare: estimateFare ?? 0,
            status: partyStatusToRideStatus(status: status),
            originLat: departureLat,
            originLng: departureLng,
            destinationLat: destinationLat,
            destinationLng: destinationLng,
            estimatedFare: estimateFare,
            estimatedMinutes: estimateTime,
            routePolyline: route,
            driverId: taxiDriverId
            // 응답의 departureRadius/destinationRadius 는 **옮기지 않는다** — 서버 고정값이고
            // 아무 조회·판정도 읽지 않는다(`PartyDetailResponse.departureRadius` 주석).
        )
    }
}

extension PartyStatusResponse {
    /// 합류 응답 → 도메인 `PartyStatus`. 상태 문자열 변환은 상세·목록과 **같은 표**를 쓴다
    /// (`partyStatusToRideStatus`) — 두 경로가 갈리면 합류 직후 상태와 상세가 서로 다른 단계로 보인다.
    ///
    /// 옮기는 건 두 값뿐이다. 지문은 서버가 지웠고(`PartyStatusResponse` 주석), 25·26 이 「바뀌었나」를
    /// 판정하는 자리는 이제 도메인 `Ride` 끼리의 `==` 다 — 매퍼가 할 일이 없다.
    ///
    /// **인원이 null(모른다)이면 0 으로 떨어진다.** 다른 매퍼들처럼 「모른다」를 살려 두지 못하는 건
    /// 도메인 `PartyStatus.currentMembers` 가 non-null `Int` 라서다. 지금은 **이 값을 읽는 화면이 없어**
    /// (21 매칭 대기는 합류 응답의 인원을 받지 않고 SSE 첫 스냅샷을 믿는다) 해가 없지만, 읽기 시작하면
    /// 「0명」과 「모른다」가 섞인다 — 그때는 도메인 필드를 `Int?` 로 내려야 한다.
    public func toPartyStatus() -> PartyStatus {
        PartyStatus(
            status: partyStatusToRideStatus(status: status),
            currentMembers: currentMembers ?? 0
        )
    }
}

extension PartySseEvent {
    /// SSE 프레임(`PartySseEvent`) → 도메인 `PartyEvent`.
    ///
    /// 변환이 **상세 매퍼를 그대로 재사용하는 게 핵심**이다 — `connected` 는 방 상세와 같은 모양이라
    /// `toRide` 를, `member-joined` 의 멤버는 상세의 멤버와 같은 record 라 `toUser` 를 쓴다. 같은 모양에
    /// 변환을 두 벌 두면 한쪽만 서버 변경을 따라가다 "스냅샷의 나"와 "입장 신호의 나"가 어긋난다.
    ///
    /// `currentUuid` 는 로그인한 사용자의 UUID(`UserSession.currentUserUuid`) — 상세 조회와 **같은 근거**로
    /// `User.isMe` 를 판정한다. 이벤트가 올 때마다 읽으므로 재로그인도 바로 반영된다.
    ///
    /// `member-left` 의 publicId 는 빈 문자열까지 null 로 접는다 — 화면은 "누가 나갔는지 모름"을
    /// 한 가지 모양(null)으로만 다뤄야 한다. `PartyEvent.memberLeft` 의 `hostPublicId` 도 같은 이유로
    /// 같은 방식으로 접는다("새 방장을 모름" = null 하나).
    public func toPartyEvent(currentUuid: String? = nil) -> PartyEvent {
        switch self {
        case .snapshot(let detail):
            return .snapshot(ride: detail.toRide(currentUuid: currentUuid), version: detail.version)
        case .memberJoined(let payload):
            return .memberJoined(
                member: payload.member.toUser(currentUuid: currentUuid),
                status: partyStatusToRideStatus(status: payload.status),
                version: payload.version
            )
        case .memberLeft(let payload):
            return .memberLeft(
                publicId: payload.publicId?.takeIfNotBlank(),
                status: partyStatusToRideStatus(status: payload.status),
                hostPublicId: payload.hostPublicId?.takeIfNotBlank(),
                version: payload.version
            )
        case .closed:
            return .closed
        case .disconnected:
            return .disconnected
        }
    }
}

// 생성 응답에는 members 목록이 없고 currentMembers 개수만 있다(생성 직후엔 늘 1 = 생성자).
// 목록 응답과 같은 방식으로 자리 표시용 멤버를 만들고, **인원을 모르면(null) 빈 목록으로 남긴다**
// — 방을 막 만든 사람이 「0/3명」을 보면 자기가 방에 없는 것으로 읽는다.
extension OpenPartyResponse {
    public func toRide() -> Ride {
        Ride(
            id: String(id),
            origin: departure,
            destination: destination,
            departureLabel: "",
            capacity: capacity,
            members: currentMembers.map(placeholderMembers(count:)) ?? [],
            farePerPerson: farePerPerson(estimateFare: estimateFare, capacity: capacity),
            totalFare: estimateFare ?? 0,
            status: partyStatusToRideStatus(status: status),
            originLat: departureLat,
            originLng: departureLng,
            destinationLat: destinationLat,
            destinationLng: destinationLng,
            estimatedFare: estimateFare,
            estimatedMinutes: estimateTime,
            routePolyline: route,
            driverId: taxiDriverId
            // 반경은 상세 매퍼와 같은 이유로 옮기지 않는다(`PartyDetailResponse.departureRadius` 주석).
        )
    }
}

extension NewParty {
    /// 방 생성 요청 본문. 실리는 것은 **좌표·라벨·정원뿐**이다.
    ///
    /// 방장 id 는 요청에도 도메인 모델에도 없다 — 방 생성자는 서버가 토큰에서 정한다(NewParty 주석 참고).
    /// 반경도 없다 — 서버가 요청에서 빼고 고정값을 쓴다(Backend `a668aee`). 둘 다 **보내도 서버가 버리는**
    /// 값이라, 되살리면 앱이 정한 값이 반영된다는 착각만 남는다. 「본문에 없다」는 PartyMappersTest 가 못 박는다.
    public func toRequestDto() -> OpenPartyRequestDto {
        OpenPartyRequestDto(
            departureLat: departureLat,
            departureLng: departureLng,
            destinationLat: destinationLat,
            destinationLng: destinationLng,
            departure: departure,
            destination: destination,
            capacity: capacity
        )
    }
}

extension DriverSummaryResponse {
    public func toAssignedDriver() -> AssignedDriver {
        AssignedDriver(seats: seats, plateNumber: plateNumber, vehicleType: type)
    }
}

extension RouteEstimateResponse {
    public func toRouteEstimate() -> RouteEstimate {
        RouteEstimate(
            estimatedFare: estimateFare ?? 0,
            estimatedMinutes: estimateTime ?? 0,
            encodedPath: path ?? ""
        )
    }
}

public func routeRequestDto(
    departureLat: Double,
    departureLng: Double,
    destinationLat: Double,
    destinationLng: Double
) -> RouteRequestDto {
    RouteRequestDto(
        departureLat: departureLat,
        departureLng: departureLng,
        destinationLat: destinationLat,
        destinationLng: destinationLng
    )
}

extension String {
    /// Kotlin `takeIf { it.isNotBlank() }`.
    func takeIfNotBlank() -> String? {
        isBlank ? nil : self
    }
}

/// 에러 본문 원문 → `{code, message}`. 본문이 비었거나 JSON 이 아니면 null.
func decodeApiError(errorBody: String?) -> ApiErrorDto? {
    guard let body = errorBody?.takeIfNotBlank() else { return nil }
    return try? MoyeotaJSON.decoder.decode(ApiErrorDto.self, from: Data(body.utf8))
}

extension Error {
    /// 서버 공통 에러 본문 `{code, message}`. HTTP 응답이 아닌 실패(네트워크 등)거나 본문이 없으면 null.
    ///
    /// 원본에서 본문은 한 번만 읽을 수 있었다(`ResponseBody.string()` 이 스트림을 닫는다). 여기서는 다시
    /// 읽어도 사라지지 않지만 규칙은 같게 둔다 — 호출부가 결과를 **들고 다니며** 쓴다.
    func readApiError() -> ApiErrorDto? {
        guard let http = self as? HttpException else { return nil }
        return decodeApiError(errorBody: http.errorBody())
    }
}

/// 합류 실패 → `PartyJoinException`. presentation 이 HTTP 를 알 필요가 없게 하는 경계다.
///
/// `error` 는 이미 읽어 둔 본문(`readApiError`)이고, `joinedStatus` 는 "내가 이미 그 방 멤버임을
/// 확인했을 때"의 그 방 상태다 — 저장소가 방 상세로 **증거를 확인한 뒤에만** 넘긴다.
func partyJoinException(
    failure: any Error,
    error: ApiErrorDto?,
    joinedStatus: PartyStatus? = nil
) -> PartyJoinException {
    if let failure = failure as? PartyJoinException { return failure }

    if let http = failure as? HttpException {
        return PartyJoinException(
            code: error?.code,
            serverMessage: error?.message,
            httpStatus: http.code(),
            joinedStatus: joinedStatus,
            cause: failure
        )
    }

    // 응답 자체를 못 받았다(연결 거부·타임아웃·DNS). 서버가 합류를 처리했는지조차 알 수 없으므로
    // 화면은 재시도를 안내해야 한다 — 재시도가 409 로 떨어지면 그때 joinedStatus 로 복구된다.
    // URLError(.cancelled) 는 취소이지 전송 실패가 아니다 — 그 도메인이 같아 먼저 거른다.
    if !isCancellation(throwable: failure), isIOFailure(throwable: failure) {
        return PartyJoinException(
            code: nil,
            serverMessage: nil,
            isNetwork: true,
            cause: failure
        )
    }

    return PartyJoinException(code: nil, serverMessage: nil, cause: failure)
}

/// 「합승 완료」 실패 → `PartyFinishException`. 합류(`partyJoinException`)와 같은 자리·같은 이유의 경계다
/// — presentation 이 `HttpException` 을 보지 않게 하고, 화면 문구는 도메인 프로퍼티로만 갈린다.
///
/// `error` 는 이미 읽어 둔 본문(`readApiError`)이다 — 여기서 다시 읽지 않는다.
///
/// 합류와 달리 `isNetwork` 를 두지 않는다: 이 액션은 응답을 못 받은 실패와 모르는 코드의 **대응이 같다**
/// (일반 문구). 쓰지 않을 구분을 노출하면 나중에 네트워크 실패에 방장 안내가 붙는 식으로 어긋난다.
func partyFinishException(
    failure: any Error,
    error: ApiErrorDto?
) -> PartyFinishException {
    if let failure = failure as? PartyFinishException { return failure }

    if let http = failure as? HttpException {
        return PartyFinishException(
            code: error?.code,
            serverMessage: error?.message,
            httpStatus: http.code(),
            cause: failure
        )
    }

    // 응답 자체를 못 받았다(연결 거부·타임아웃·DNS) 또는 그 밖의 실패. 서버가 말해 준 사유가 없으므로
    // code 는 null 이고, 화면은 일반 문구로 안내한다.
    return PartyFinishException(code: nil, serverMessage: nil, cause: failure)
}

/// 실시간 매칭 후보 조회 실패 → `RealtimeMatchException`. `partyFinishException` 과 같은 경계다.
func realtimeMatchException(
    failure: any Error,
    error: ApiErrorDto?
) -> RealtimeMatchException {
    if let failure = failure as? RealtimeMatchException { return failure }

    if let http = failure as? HttpException {
        return RealtimeMatchException(
            code: error?.code,
            serverMessage: error?.message,
            httpStatus: http.code(),
            cause: failure
        )
    }

    return RealtimeMatchException(code: nil, serverMessage: nil, cause: failure)
}

extension MatchCandidateResponse {
    /// 실시간 매칭 후보 하나 → `MatchCandidate`.
    ///
    /// **`Ride` 의 일부가 비어 있는 게 정상이다.** 서버 `NearbyPartySummary` 에는 요금·경로가 없다.
    /// 그래서 요금은 0, 상태는 `RideStatus.recruiting` 으로 둔다 — 상태를 고정값으로 두는 근거는 서버
    /// 쿼리가 `status = 'ACTIVE'` 로 못 박혀 있다는 것이다(모집 중인 방만 후보가 된다).
    ///
    /// **인원은 `placeholderMembers` 로 채운다**(Backend #260 이 `currentMembers` 를 실어 주기 시작했다).
    /// 17 탐색 목록이 같은 숫자를 같은 방식으로 쓰고 있어 카드 문구(「2/3명」)가 양쪽에서 일치한다.
    /// 다만 **`currentMembers` 가 null 이면 빈 목록으로 남긴다** — 옛 배포를 보고 있다는 뜻이고, 그때
    /// 가짜 멤버를 넣으면 화면이 「0/3명」이라는 없는 상태를 그린다. `Ride.members` 가 비어 있다 =
    /// 인원을 모른다로 읽어야 한다.
    ///
    /// `summary` 가 통째로 null 인 프레임은 **버린다**(호출부가 compactMap). 방 id 가 없으면 탭해도
    /// 갈 곳이 없어 카드를 그릴 이유가 없다.
    public func toMatchCandidate() -> MatchCandidate? {
        guard let summary, summary.id > 0 else { return nil }
        return MatchCandidate(
            ride: Ride(
                id: String(summary.id),
                origin: summary.departure,
                destination: summary.destination,
                departureLabel: "",
                capacity: summary.capacity,
                members: summary.currentMembers.map(placeholderMembers(count:)) ?? [],
                farePerPerson: 0,
                totalFare: 0,
                status: .recruiting,
                originLat: summary.departureLat,
                originLng: summary.departureLng,
                // 뷰포트 목록과 달리 **도착 좌표도 온다** — 지도에 경로를 그릴 수 있다.
                destinationLat: summary.destinationLat,
                destinationLng: summary.destinationLng
            ),
            walkSeconds: totalSeconds
        )
    }
}
