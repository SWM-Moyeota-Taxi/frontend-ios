import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

/// 사유를 가릴 수 없는 방 생성 실패의 일반 문구 — 네트워크 실패와 **모르는 코드**가 여기로 떨어진다.
/// 서버가 `MatchingErrorCode` 를 늘려도 앱이 틀린 말을 하지 않는다(21 의 `FINISH_FAILED_MESSAGE` 와
/// 같은 규칙: 지어내는 것보다 모른다고 하는 게 낫다). 문구는 예전 단일 문구를 그대로 쓴다.
private let OPEN_FAILED_MESSAGE = "동승 방을 만들지 못했어요. 잠시 후 다시 시도해 주세요"

/// 「이미 참여 중인 방이 있다」 — **세 자리가 같은 말을 해야 한다.**
///
/// 서버가 같은 사유(`ALREADY_JOINED_OTHER_PARTY`)로 막는 곳이 셋이다: 방 생성(`PartyService.open`),
/// 추천 조회(`findRealtimeCandidates`), 합류(`join`). 앞의 둘이 이 상수를 함께 쓰고, 합류는 문구 끝이
/// 다르다(「그 방에서 나온 뒤 합류해 주세요」 — 그쪽은 돌아갈 곳이 목록이라 할 일이 다르다).
///
/// 돌아갈 곳을 **홈**으로 적는 이유: 진행 중인 방으로 들어가는 길은 홈 배너뿐이다(21 의
/// `finishFailureMessage` 가 멤버 아님에 쓰는 「홈에서 진행 중인 방을 확인해 주세요」와 같은 근거).
let ALREADY_IN_PARTY_MESSAGE = "이미 참여 중인 방이 있어요. 홈에서 진행 중인 방을 확인해 주세요"

/// 방 생성 실패를 사용자 문구로 옮긴다 — 실패마다 **다음 행동이 다르다**
/// (20 합류의 `joinFailureMessage`·21 완료의 `finishFailureMessage` 와 같은 자리·같은 이유).
///
/// | 사유 | 서버 코드(HTTP) | 사용자가 할 일 |
/// |---|---|---|
/// | 이미 참여 중인 방 | `ALREADY_JOINED_OTHER_PARTY` (409) | 홈 배너로 그 방에 들어가 정리한다 |
/// | 출발지 = 도착지 | `SAME_DEPARTURE_DESTINATION` (400) | **핀을 옮긴다** |
/// | 서비스 지역 밖 | `OUT_OF_SERVICE_AREA` (400) | 다른 장소를 고른다 |
/// | 정원이 1~3 아님 | `INVALID_CAPACITY` (400) | 인원을 다시 고른다(사실상 앱 버그다) |
/// | 경로를 못 받음 | `ROUTE_SEARCH_FAILED` (502) · `INVALID_ROUTE_ESTIMATE`·`ROUTE_NOT_FOUND` (400) | 잠시 뒤 다시, 또는 핀을 조금 옮긴다 |
/// | 그 밖·네트워크 | 코드 없음 | `OPEN_FAILED_MESSAGE` |
///
/// **상태 코드로 폴백하지 않는다** — 400 이 네 가지라 「400 이니 핀을 옮겨 주세요」가 거짓이 될 수 있다.
/// 코드를 모르면 `PartyOpenException.code` 가 nil 이고 일반 문구로 떨어진다(서버가 503 HTML 을
/// 돌려주는 경우도 여기다 — `readApiError()` 가 nil 을 돌려준다).
///
/// 「출발지와 도착지가 같다」에 **「잠시 후 다시」를 붙이지 않는 것**이 이 분기의 핵심이다. 15 의 50m
/// 검사를 통과한 뒤에도 16 의 핀 조정은 그 검사를 **다시 거치지 않아서**, 두 핀을 겹쳐 놓으면 실제로
/// 이 400 이 떨어진다 — 기다려서 풀리지 않는다.
func openFailureMessage(e: PartyOpenException) -> String {
    if e.isAlreadyInAnotherParty { return ALREADY_IN_PARTY_MESSAGE }
    if e.isSameDepartureDestination { return "출발지와 도착지가 같아요. 핀을 옮겨 조금 떨어뜨려 주세요" }
    if e.isOutOfServiceArea { return "서비스 지역을 벗어난 위치예요. 출발지와 도착지를 다시 골라 주세요" }
    if e.isInvalidCapacity { return "인원은 1~3명까지만 정할 수 있어요" }
    if e.isRouteUnavailable { return "경로를 찾지 못했어요. 잠시 후 다시 시도하거나 출발·도착지를 조금 옮겨 주세요" }
    return OPEN_FAILED_MESSAGE
}

/// `fail_match_request` 의 `reason` — `openFailureMessage` 와 같은 분기를 **문구가 아니라 상수**로 옮긴다.
/// 문구를 그대로 보내면 카피를 다듬을 때마다 Mixpanel 의 집계가 갈라진다.
func openFailureReason(e: PartyOpenException) -> String {
    if e.isAlreadyInAnotherParty { return "already_in_party" }
    if e.isSameDepartureDestination { return "same_departure_destination" }
    if e.isOutOfServiceArea { return "out_of_service_area" }
    if e.isInvalidCapacity { return "invalid_capacity" }
    if e.isRouteUnavailable { return "route_unavailable" }
    return "unknown"
}

// 방 생성자는 서버가 Bearer 토큰 주체로 정한다 — 요청 본문에 사용자 id 를 싣지 않는다.
@MainActor
@Observable
public final class CreatePartyViewModel {

    public struct UiState: Equatable, Sendable {
        public var creating: Bool
        public var errorMessage: String?
        public var createdParty: Ride?
        /// **진행 중인 방 기억을 되살려야 한다** — 생성이 409 `ALREADY_JOINED_OTHER_PARTY` 로 막혔다.
        ///
        /// 문구만으로는 탈출구가 되지 않는다. 그 사람의 유일한 복구 경로는 **홈 배너 → 21 → 「그만
        /// 찾기」**인데, 그 배너는 `ActivePartyRepository.resolve()` 가 방을 찾아야 뜬다 — 앱을 다시
        /// 깔았거나 기억이 지워진 상태라면 조회를 한 번 더 돌려야 그 방이 보인다. 그래서 「문구」와
        /// 「탈출구」를 따로 둔다.
        ///
        /// Route 가 이 값을 콜백으로 바꿔 올리고(`onActivePartyRefresh`), 호출부(`MainNavGraph`)가
        /// `ActivePartyViewModel.refresh()` 에 꽂는다 — 이 ViewModel 은 그 홀더에 닿을 수 없다
        /// (계층이 다르고, 모달은 `ActivePartyViewModel` 을 인자로 받지 않는다).
        public var needsActivePartyRefresh: Bool

        public init(
            creating: Bool = false,
            errorMessage: String? = nil,
            createdParty: Ride? = nil,
            needsActivePartyRefresh: Bool = false
        ) {
            self.creating = creating
            self.errorMessage = errorMessage
            self.createdParty = createdParty
            self.needsActivePartyRefresh = needsActivePartyRefresh
        }
    }

    // 백엔드 검증 상한(서버 `Capacity` record = 1~3). 넘기면 400 `INVALID_CAPACITY` 가 오고
    // 화면은 사유별 문구로 안내한다(`openFailureMessage`) — 예전에는 모든 실패가 한 문구라
    // 「에러 바디 없는 500」과 구별되지 않았다. 그래도 범위 고정은 남긴다: 서버가 막아 주는 것과
    // 앱이 보내지 않는 것은 다른 보호막이다.
    public static let MAX_PARTY_CAPACITY = 3

    public private(set) var uiState = UiState()

    private let repository: any RideRepository
    private let scope = ViewModelScope()

    public init(repository: any RideRepository) {
        self.repository = repository
    }

    /// 방 생성 제출. 실패는 `PartyOpenException` 으로 좁혀 올라오고 `openFailureMessage` 가 사유별
    /// 문구로 가른다 — 예전에는 **모든 사유가 「잠시 후 다시 시도해 주세요」 하나**였다.
    ///
    /// 그게 특히 나쁜 자리였던 까닭은 이 엔드포인트의 실패가 **기다려서 풀리는 것과 사용자가 고쳐야
    /// 하는 것으로 갈리기** 때문이다: 409 「이미 참여 중인 방」은 그 방을 정리해야 풀리고(그 방이 아무도
    /// 합류하지 않은 ACTIVE 방이면 서버 30분 스윕에도 남아 **영구 교착**이다), 400 「출발지와 도착지가
    /// 같다」는 핀을 옮겨야 풀린다. 둘 다 「잠시 후 다시」로 안내하면 영원히 같은 실패를 맞는다.
    ///
    /// 돌려주는 태스크는 테스트가 끝을 기다리는 용도다. 화면은 쓰지 않는다.
    @discardableResult
    public func createParty(origin: Place, destination: Place, conditions: MatchConditions) -> Task<Void, Never>? {
        if uiState.creating { return nil } // 중복 제출 차단
        // 잠금은 태스크 안이 아니라 여기서 건다. `Task` 는 다음 차례로 밀려, 그 틈에 연타가 지나간다.
        uiState.creating = true
        uiState.errorMessage = nil
        Analytics.track(.partyCreateClicked(capacity: conditions.capacity))
        let repository = self.repository
        return scope.launch { [weak self] in
            do {
                let party = try await repository.createParty(
                    request: NewParty(
                        departureLat: origin.latitude,
                        departureLng: origin.longitude,
                        destinationLat: destination.latitude,
                        destinationLng: destination.longitude,
                        departure: origin.name,
                        destination: destination.name,
                        // 서버 상한 3. 16 모달 칩이 1~3 뿐이지만 계약을 여기서 한 번 더 못박는다 —
                        // 벗어나면 400 `INVALID_CAPACITY` 이고(`openFailureMessage`), 값이 **빠지면**
                        // 서버가 primitive 로 풀다 500 을 낸다(사유 없는 실패 = 일반 문구).
                        capacity: min(max(conditions.capacity, 1), Self.MAX_PARTY_CAPACITY)
                        // 반경은 싣지 않는다 — 서버가 요청에서 빼고 고정값(500m)을 쓴다
                        // (Backend `a668aee`). 16 의 반경 칩도 함께 내렸다(`MatchConditions`).
                    )
                )
                guard let self else { return }
                self.uiState.creating = false
                self.uiState.createdParty = party
                // 핵심 퍼널 2단계(방 만들기 쪽). 지역은 시/구까지만, 좌표·번지는 싣지 않는다.
                Analytics.track(.matchRequested(
                    method: .create,
                    capacity: party.capacity,
                    originArea: administrativeArea(fromAddress: origin.roadName),
                    destinationArea: administrativeArea(fromAddress: destination.roadName),
                    estimatedFare: party.estimatedFare
                ))
            } catch {
                guard let self else { return }
                self.uiState.creating = false
                // 모달을 닫으며 태스크가 취소된 것 — 실패 문구를 띄우지 않는다(20 합류와 같은 처리).
                // 살아 있는 태스크의 `URLError(.cancelled)` 는 원본 `IOException` 이라 아래 일반 문구로 간다.
                if Task.isCancelled { return }
                if let e = error as? PartyOpenException {
                    self.uiState.errorMessage = openFailureMessage(e: e)
                    // 409 는 문구만으로 풀리지 않는다 — 홈 배너가 뜨도록 진행 중 방 조회를 되살린다.
                    self.uiState.needsActivePartyRefresh =
                        self.uiState.needsActivePartyRefresh || e.isAlreadyInAnotherParty
                    Analytics.track(.matchRequestFailed(method: .create, reason: openFailureReason(e: e)))
                } else {
                    // 데이터 계층이 좁히지 못한 실패(직렬화 등). 사유를 모르므로 일반 문구다.
                    self.uiState.errorMessage = OPEN_FAILED_MESSAGE
                    Analytics.track(.matchRequestFailed(method: .create, reason: "unknown"))
                }
            }
        }
    }
}

/// 경로 미리보기·추천이 함께 쓰는 좌표 쌍. 같은 값이면 다시 부르지 않는다.
private struct RouteQuery: Equatable, Sendable {
    let departureLat: Double
    let departureLng: Double
    let destinationLat: Double
    let destinationLng: Double

    /// 좌표 중 하나라도 없으면 nil 이다(15 를 거치지 않은 진입)
    init?(origin: LatLng?, destination: LatLng?) {
        guard let origin, let destination else { return nil }
        departureLat = origin.latitude
        departureLng = origin.longitude
        destinationLat = destination.latitude
        destinationLng = destination.longitude
    }
}

/// 16 경로 미리보기 — 좌표만으로 예상 요금·소요시간·폴리라인을 받아온다 (POST /matching/routes).
///
/// 핀 조정으로 좌표가 바뀔 때마다 다시 부른다. 조정 확정을 연타하면 요청이 겹치는데,
/// **직전 호출을 취소**하므로(원본 `flatMapLatest`) 늦게 끝난 옛 응답이 최신 값을 덮어쓰지 못한다.
/// 좌표를 들고 있어 같은 좌표로는 재호출되지 않는다(화면 갱신 중복 호출 방지).
@MainActor
@Observable
public final class RoutePreviewViewModel {

    public enum UiState: Equatable, Sendable {
        /// 좌표가 아직(또는 끝내) 없어 부를 수 없다
        case idle
        case loading
        case success(estimate: RouteEstimate)
        /// 미리보기는 부가 정보라 사용자에게 배너를 띄우지 않는다 — 값만 감춘다
        case error
    }

    public private(set) var uiState = UiState.idle

    private let repository: any RideRepository
    private let scope = ViewModelScope()
    @ObservationIgnored private var query: RouteQuery?
    @ObservationIgnored private var job: Task<Void, Never>?

    public init(repository: any RideRepository) {
        self.repository = repository
    }

    /// 좌표 중 하나라도 없으면 미리보기를 비운다(15 를 거치지 않은 진입).
    /// 돌려주는 태스크는 테스트가 끝을 기다리는 용도다. 화면은 쓰지 않는다.
    @discardableResult
    public func preview(origin: LatLng?, destination: LatLng?) -> Task<Void, Never>? {
        let next = RouteQuery(origin: origin, destination: destination)
        if next == query { return nil }
        query = next
        job?.cancel()
        job = nil
        guard let next else {
            uiState = .idle
            return nil
        }
        uiState = .loading
        let repository = self.repository
        let task = scope.launch { [weak self] in
            do {
                let estimate = try await repository.previewRoute(
                    departureLat: next.departureLat,
                    departureLng: next.departureLng,
                    destinationLat: next.destinationLat,
                    destinationLng: next.destinationLng
                )
                // 코루틴은 취소되면 재개 자리에서 예외를 던지지만 Swift 는 끝난 호출의 값을 그대로 돌려준다.
                // 여기서 끊지 않으면 옛 좌표의 늦은 응답이 최신 값을 덮는다.
                try Task.checkCancellation()
                self?.uiState = .success(estimate: estimate)
            } catch {
                // 끊긴 요청은 상태를 쓰지 않는다 — 새 요청이 곧 덮는다. 태스크가 살아 있는데 `URLError(.cancelled)` 가
                // 오면 덮어 줄 요청이 없으니 값만 감춘다(안 그러면 「계산 중」에 머문다).
                if Task.isCancelled { return }
                self?.uiState = .error
            }
        }
        job = task
        return task
    }
}

/// 16 에서 보여 줄 **「걸어서 가까운 방」 추천**(`POST /matching/rooms/realtime`).
///
/// `RoutePreviewViewModel` 과 같은 모양이고 같은 좌표로 **함께** 1회 부른다 — 둘 다 "출발·도착이
/// 확정된 순간"에만 의미가 있고, 폴링할 값이 아니다(후보마다 서버가 도보 경로를 2번 계산한다).
///
/// **`UiState.hidden` 이 이 화면의 기본 상태다.** 서버가 출발지·도착지 **각각** 300m 안(AND)에서만
/// 고르기 때문에 초기에는 거의 항상 후보가 없다. 그래서 "없음"을 강조하지 않고 섹션을 아예 그리지
/// 않는다 — 빈 상태가 기본인데 실패처럼 보이면 안 된다.
@MainActor
@Observable
public final class NearbyCandidatesViewModel {

    public enum UiState: Equatable, Sendable {
        /// 그릴 게 없다 — 좌표가 없거나, 후보가 없다. **둘 다 섹션을 숨긴다.**
        ///
        /// 예전에는 **조회 실패까지** 여기로 접었다. 그게 결함이었다: 「후보 0개」와 「못 가져왔다」는
        /// 사용자에게 구별되지 않는데 **올바른 다음 행동이 정반대**다(방 만들기 / 다시 시도). OSRM 이
        /// 죽거나 503 이면 300m 안에 방이 있어도 섹션이 그냥 사라지고, 사용자는 **합승이 가능한데도**
        /// 새 방을 만든다 — 합승 매칭이라는 제품의 핵심이 조용히 꺼지는 자리다.
        ///
        /// 그래서 실패를 `failed`·`alreadyInParty` 로 갈라 냈고, **이 상태의 뜻은 좁혔다.**
        case hidden
        case loading
        /// 서버가 도보 시간 순으로 정렬한 1~5개. **재정렬하지 않는다.**
        case success(candidates: [MatchCandidate])
        /// **조회 자체가 실패했다**(502 경로 엔진·503·네트워크·모르는 코드). 후보가 없는 것과 다르다.
        ///
        /// 화면은 이걸 **차단형 배너로 띄우지 않는다** — 방을 만들러 온 사용자가 자기가 뭘 잘못했다고
        /// 읽는다. 작은 인라인 「다시 시도」 줄 하나면 된다(`retry`). 그 줄이 있어야 OSRM 장애가
        /// 「주변에 방이 없다」로 위장되지 않는다.
        case failed
        /// 409 `ALREADY_JOINED_OTHER_PARTY` — **이미 진행 중인 방이 있다.** 서버
        /// `PartyService.findRealtimeCandidates` 도 `validateNotInOngoingParty` 를 먼저 탄다.
        ///
        /// 추천을 보여 줄 이유가 없다는 점은 예전과 같지만, **이 신호를 지우면 안 된다**: 바로 뒤에
        /// 사용자가 누를 「방 만들기」도 **같은 409 로 막힌다**(그쪽은 영구 교착이다 —
        /// `openFailureMessage` 의 409 분기 참고). 즉 이건 그 교착의 **예고 신호**이고, 화면은 같은
        /// 사유를 같은 말로 안내하며(`ALREADY_IN_PARTY_MESSAGE`) 진행 중 방 조회를 되살려야 한다.
        case alreadyInParty
    }

    public private(set) var uiState = UiState.hidden

    private let repository: any RideRepository
    private let scope = ViewModelScope()
    @ObservationIgnored private var query: RouteQuery?
    @ObservationIgnored private var job: Task<Void, Never>?

    public init(repository: any RideRepository) {
        self.repository = repository
    }

    /// 좌표 중 하나라도 없으면 추천을 비운다(`RoutePreviewViewModel.preview` 와 같은 규칙).
    /// 돌려주는 태스크는 테스트가 끝을 기다리는 용도다. 화면은 쓰지 않는다.
    @discardableResult
    public func find(origin: LatLng?, destination: LatLng?) -> Task<Void, Never>? {
        let next = RouteQuery(origin: origin, destination: destination)
        if next == query { return nil }
        query = next
        return run()
    }

    /// 「다시 시도」 — **같은 좌표로** 추천을 한 번 더 조회한다(`UiState.failed` 의 인라인 줄이 부른다).
    ///
    /// `find` 는 같은 좌표면 그냥 돌아간다(그게 화면 갱신 중복 호출을 막는 장치다). 재시도는 좌표가
    /// **그대로인 채** 다시 부르는 일이라 그 중복 방지를 건너뛴다.
    ///
    /// 폴링이 아니라 사용자가 누를 때만이다: 후보마다 서버가 도보 경로를 2번 계산하므로 자동 재시도를
    /// 걸면 장애 중인 경로 엔진을 앱이 대신 두드린다.
    @discardableResult
    public func retry() -> Task<Void, Never>? {
        run()
    }

    private func run() -> Task<Void, Never>? {
        job?.cancel()
        job = nil
        guard let query else {
            uiState = .hidden
            return nil
        }
        uiState = .loading
        let repository = self.repository
        let task = scope.launch { [weak self] in
            do {
                let candidates = try await repository.findRealtimeCandidates(
                    departureLat: query.departureLat,
                    departureLng: query.departureLng,
                    destinationLat: query.destinationLat,
                    destinationLng: query.destinationLng
                )
                try Task.checkCancellation()
                // 빈 목록은 성공이지만 그릴 것이 없다 — 「후보 0개」를 띄우지 않는다.
                self?.uiState = candidates.isEmpty ? .hidden : .success(candidates: candidates)
            } catch {
                if Task.isCancelled { return }
                // 추천은 **부가 기능**이지만, 실패를 「후보 0개」와 똑같이 다루면 안 된다 —
                // 둘의 올바른 다음 행동이 정반대다(다시 시도 / 방 만들기). 차단형 배너는
                // 여전히 띄우지 않는다: 가르는 건 **상태**이고, 그 상태를 어떻게 보여 줄지는
                // 화면이 정한다(`UiState.failed` 설명).
                self?.uiState = candidatesFailure(cause: error)
            }
        }
        job = task
        return task
    }
}

/// 추천 조회 실패를 화면 상태로 옮긴다 — **「후보 0개」와 섞지 않는 게 요점**이다.
///
/// | 사유 | 상태 | 왜 갈라야 하나 |
/// |---|---|---|
/// | 409 `ALREADY_JOINED_OTHER_PARTY` | `UiState.alreadyInParty` | 추천도, **방 만들기도** 막힌 상태다 — 바로 뒤의 409 교착을 예고하는 신호라 지우면 안 된다 |
/// | 그 밖(502·503·네트워크·모르는 코드) | `UiState.failed` | 「주변에 방이 없다」가 아니라 **못 물어봤다**는 뜻이고, 할 일은 재시도다 |
///
/// 빈 목록은 여기 오지 않는다 — 후보가 없는 건 성공이고, 데이터 계층이 예외로 올리지 않는다.
///
/// `RealtimeMatchException` 이 아닌 실패(직렬화 등)도 `UiState.failed` 다 —
/// 사유를 모를 때 「진행 중인 방이 있어요」라고 **추측하지 않는다**(그 말은 거짓일 때 사용자를
/// 없는 방으로 찾아 보내게 한다).
func candidatesFailure(cause: any Error) -> NearbyCandidatesViewModel.UiState {
    (cause as? RealtimeMatchException)?.isAlreadyInParty == true ? .alreadyInParty : .failed
}

/// 16 핀 좌표 → 주소 (GET /places/reverse). 출발지·도착지의 **표시 이름과 방 생성 요청에 실리는
/// 이름**을 실주소로 갈아 끼운다.
///
/// 이름 갱신은 부가 기능이라 **흐름을 절대 막지 않는다**:
/// - 실패(네트워크·400·502)하면 조용히 기존 이름을 유지한다. 배너·토스트를 띄우지 않는다.
/// - 주소가 없는 좌표(바다 등, Repository 계약상 `nil`)도 정상 결과라 마찬가지로 기존 이름 유지.
/// - 호출 중에도 확정 버튼을 잠그지 않는다 — 낙관적으로 진행하고 응답이 오면 그때 이름이 바뀐다.
///
/// 팬 중에는 부르지 않는다. 호출 시점은 「이 위치로 설정」 확정 순간과 16 진입(GPS 출발지) 둘뿐이다.
@MainActor
@Observable
public final class ReverseGeocodeViewModel {

    /// 필드별로 확정된 주소. nil = 아직(또는 끝내) 없음 → 원래 장소 이름을 그대로 쓴다
    public struct UiState: Equatable, Sendable {
        public var originAddress: String?
        public var destinationAddress: String?

        public init(originAddress: String? = nil, destinationAddress: String? = nil) {
            self.originAddress = originAddress
            self.destinationAddress = destinationAddress
        }
    }

    public private(set) var uiState = UiState()

    private let repository: any PlaceRepository
    private let scope = ViewModelScope()

    // 좌표 → 주소. **nil 값도 캐시한다** — 「주소가 없는 좌표」라는 사실 자체가 안정된 결과다.
    @ObservationIgnored private var addresses: [String: String?] = [:]

    // 대상별 마지막으로 요청한 좌표. 같은 좌표로 재확정하면 서버를 다시 부르지 않는다
    // (조정 화면은 한쪽만 만져도 양쪽 좌표를 함께 돌려주므로 중복 호출이 쉽게 생긴다).
    @ObservationIgnored private var requested: [PinTarget: String] = [:]
    @ObservationIgnored private var jobs: [PinTarget: Task<Void, Never>] = [:]

    public init(repository: any PlaceRepository) {
        self.repository = repository
    }

    /// 돌려주는 태스크는 테스트가 끝을 기다리는 용도다. 화면은 쓰지 않는다.
    @discardableResult
    public func resolve(target: PinTarget, position: LatLng?) -> Task<Void, Never>? {
        guard let position else { return nil }
        let key = String(format: "%.6f,%.6f", position.latitude, position.longitude)
        if requested[target] == key { return nil }
        requested[target] = key

        if let cached = addresses[key] {
            if let cached { apply(target: target, address: cached) } // 주소 없는 좌표였다면 기존 이름 유지
            return nil
        }

        // 확정을 연타하면 요청이 겹친다 — 직전 호출을 취소해 늦게 끝난 옛 응답이 최신 좌표를 덮지 못하게
        jobs[target]?.cancel()
        let repository = self.repository
        let task = scope.launch { [weak self] in
            do {
                let address = try await repository.reverseGeocode(
                    latitude: position.latitude,
                    longitude: position.longitude
                )?.address
                try Task.checkCancellation()
                guard let self else { return }
                self.addresses.updateValue(address, forKey: key)
                if let address { self.apply(target: target, address: address) }
            } catch {
                // 태스크 취소는 실패가 아니다 — requested 를 지우면 새 좌표 등록이 날아간다.
                // 살아 있는 태스크의 `URLError(.cancelled)` 는 실패다. requested 가 남으면 같은 좌표를 다시 묻지 못한다.
                if Task.isCancelled { return }
                // 다음 확정 때 다시 시도할 수 있도록 요청 기록을 지운다(캐시에도 남기지 않는다)
                self?.requested[target] = nil
            }
        }
        jobs[target] = task
        return task
    }

    private func apply(target: PinTarget, address: String) {
        switch target {
        case .origin: uiState.originAddress = address
        case .destination: uiState.destinationAddress = address
        }
    }
}

// 16 도착지 확인 모달 — 방 생성 진입점. 성공하면 생성된 방을 그대로 21 매칭 대기로 넘긴다.
public struct DestinationConfirmRoute: View {
    // 15 에서 확정한 출발지(고른 곳 또는 실위치). 15 를 거치지 않고 들어오면 nil — 방을 만들지 않고 안내만 한다
    private let origin: Place?
    private let destination: Place?
    private let onDismiss: () -> Void
    private let onPartyCreated: (Ride) -> Void
    private let onCandidateSelected: (Ride) -> Void
    private let onActivePartyRefresh: () -> Void

    @HostedViewModel private var viewModel: CreatePartyViewModel
    @HostedViewModel private var routeViewModel: RoutePreviewViewModel
    @HostedViewModel private var candidatesViewModel: NearbyCandidatesViewModel
    @HostedViewModel private var reverseViewModel: ReverseGeocodeViewModel

    // 핀 조정 결과. ViewModel 이 아니라 화면 상태로 들고 있다 — 방을 만드는 순간에만 쓰이고,
    // 모달을 닫으면(15 로 복귀) 검색 결과 좌표에서 다시 시작하는 편이 예측 가능하다.
    @State private var adjustedOrigin: LatLng?
    @State private var adjustedDestination: LatLng?

    // 원본 `remember(key)` 자리 — 시각 라벨은 추정이 갱신될 때만 다시 찍는다
    @State private var departureMemo = Remembered<RouteEstimate?, String>()
    @State private var arrivalMemo = Remembered<RoutePreviewViewModel.UiState, String>()

    /// - Parameters:
    ///   - onCandidateSelected: 「걸어서 가까운 방」 추천을 골랐다 — 그 방의 합류 확인(19)으로 보낸다.
    ///     `onPartyCreated` 와 갈라 둔 이유: 저쪽은 **방을 만든 뒤** 21 대기로 가고, 이쪽은 아무것도
    ///     만들지 않고 남의 방 합류 흐름을 탄다. 같은 콜백으로 묶으면 호출부가 둘을 구분할 수 없다.
    ///   - onActivePartyRefresh: **진행 중인 방 조회를 다시 돌려라** — 서버가 「이미 참여 중인 방이 있다」(409)고 답했다.
    ///     호출부는 `ActivePartyViewModel.refresh()` 를 꽂아야 한다. 문구만으로는 탈출구가 되지 않기
    ///     때문이다: 그 사람의 유일한 복구 경로가 **홈 배너 → 21 → 「그만 찾기」**인데, 배너는
    ///     `ActivePartyRepository.resolve()` 가 그 방을 찾아야 뜬다
    ///     (`CreatePartyViewModel.UiState.needsActivePartyRefresh` 설명).
    public init(
        repository: any RideRepository,
        placeRepository: any PlaceRepository,
        origin: Place?,
        destination: Place?,
        onDismiss: @escaping () -> Void = {},
        onPartyCreated: @escaping (Ride) -> Void = { _ in },
        onCandidateSelected: @escaping (Ride) -> Void = { _ in },
        onActivePartyRefresh: @escaping () -> Void = {}
    ) {
        self.origin = origin
        self.destination = destination
        self.onDismiss = onDismiss
        self.onPartyCreated = onPartyCreated
        self.onCandidateSelected = onCandidateSelected
        self.onActivePartyRefresh = onActivePartyRefresh
        _viewModel = HostedViewModel(wrappedValue: CreatePartyViewModel(repository: repository))
        _routeViewModel = HostedViewModel(wrappedValue: RoutePreviewViewModel(repository: repository))
        _candidatesViewModel = HostedViewModel(wrappedValue: NearbyCandidatesViewModel(repository: repository))
        _reverseViewModel = HostedViewModel(wrappedValue: ReverseGeocodeViewModel(repository: placeRepository))
    }

    private struct PositionsKey: Equatable {
        let origin: LatLng?
        let destination: LatLng?
    }

    public var body: some View {
        let viewModel = self.viewModel
        let routeViewModel = self.routeViewModel
        let candidatesViewModel = self.candidatesViewModel
        let reverseViewModel = self.reverseViewModel
        let state = viewModel.uiState
        let routeState = routeViewModel.uiState
        let candidatesState = candidatesViewModel.uiState
        let resolvedNames = reverseViewModel.uiState

        // 조정값이 있으면 그것, 없으면 검색 좌표(범위 검증 통과분)
        let originPosition = adjustedOrigin ?? latLngOrNull(latitude: origin?.latitude, longitude: origin?.longitude)
        let destinationPosition = adjustedDestination
            ?? latLngOrNull(latitude: destination?.latitude, longitude: destination?.longitude)

        let nearbyCandidates: [MatchCandidate] = {
            if case let .success(candidates) = candidatesState { return candidates }
            return []
        }()

        // 「이미 참여 중인 방이 있다」를 **두 창구 중 어느 쪽에서든** 들었다 — 생성 409(눌러 본 뒤)와
        // 추천 409(누르기 전)다. 둘 다 같은 사실이고 탈출구도 같으므로 함께 올린다. 추천 쪽이 먼저
        // 뜨므로, 사용자가 「방 만들기」를 눌러 교착을 한 번 더 확인하기 전에 홈 배너가 준비된다.
        let alreadyInParty = candidatesState == .alreadyInParty
        let needsActivePartyRefresh = state.needsActivePartyRefresh || alreadyInParty

        // 주소를 받아냈으면 표시·전송 이름을 그것으로 바꾼다. 못 받았으면 원래 이름 그대로.
        let originName = resolvedNames.originAddress ?? origin?.name ?? "—"
        let destinationName = resolvedNames.destinationAddress ?? destination?.name ?? "—"

        let estimate: RouteEstimate? = {
            if case let .success(estimate) = routeState { return estimate }
            return nil
        }()
        // 출발·도착 시각은 「지금 출발」 기준. 추정이 갱신될 때 두 값을 같은 기준 시각으로 다시 찍는다.
        let departureTimeLabel = departureMemo.value(key: estimate) { clockLabel(minutesFromNow: 0) }
        let arrivalTimeLabel = arrivalMemo.value(key: routeState) {
            if let estimate { return "\(clockLabel(minutesFromNow: estimate.estimatedMinutes)) 도착" }
            if routeState == .loading { return "도착 계산 중" }
            return "—"
        }

        // 15 를 거치지 않고 들어오면 좌표가 없어 방을 만들 수 없다 — 안내만 하고 닫기 유도.
        // 고정 좌표로 채우지 않는다 — 실제 출발 위치가 아닌 곳으로 방이 만들어진다.
        DestinationConfirmModal(
            destinationName: destinationName,
            // 이름 자리가 이미 실주소면 검색 당시의 도로명은 같은 값을 두 번 적는 꼴이라 비운다.
            // (핀을 옮겼다면 그 도로명은 더 이상 핀이 선 자리도 아니다)
            destinationAddress: resolvedNames.destinationAddress != nil ? "" : destination?.roadName ?? "",
            originStopName: originName,
            departureTimeLabel: departureTimeLabel,
            arrivalTimeLabel: arrivalTimeLabel,
            // 좌표 검증은 latLngOrNull 에 맡긴다 — 범위를 벗어난 값이면 nil 이 되어
            // 지도가 엉뚱한 곳을 비추는 대신 자리표시자로 떨어진다 (QA D-1 위경도 전치 대비)
            destinationPosition: destinationPosition,
            originPosition: originPosition,
            routePreview: RoutePreviewUi(
                loading: routeState == .loading,
                estimatedMinutes: estimate?.estimatedMinutes,
                estimatedFare: estimate?.estimatedFare,
                encodedPath: estimate?.encodedPath
            ),
            creating: state.creating,
            // 추천 409 를 **누르기 전에** 알려 준다 — 그 상태에서는 「방 만들기」도 같은 409 로 막히므로
            // (서버가 두 경로 모두 validateNotInOngoingParty 를 먼저 탄다) 미리 말하는 쪽이 정확하다.
            // 눌러 본 뒤의 실패 문구(state.errorMessage)가 있으면 그게 먼저다 — 더 최근의 사실이다.
            // 추천의 **단순 실패**(UiState.failed)는 여기 넣지 않는다: 차단형 배너로 띄우면 방을 만들러
            // 온 사용자가 자기가 뭘 잘못했다고 읽는다 — 그 자리는 인라인 재시도 줄이다.
            errorMessage: state.errorMessage
                ?? (alreadyInParty ? ALREADY_IN_PARTY_MESSAGE : nil)
                ?? (destination == nil ? "도착지 좌표가 없어요. 15 목적지 화면에서 장소를 다시 선택해 주세요" : nil)
                ?? (origin == nil ? "출발지가 없어요. 15 목적지 화면에서 출발지를 검색해 주세요" : nil),
            onDismiss: onDismiss,
            onAdjustPositions: { newOrigin, newDestination in
                // 좌표가 **실제로 바뀐 쪽만** 역지오코딩한다. 조정 화면은 한쪽만 만져도 양쪽 좌표를
                // 함께 돌려주므로, 안 건드린 필드까지 부르면 사용자가 고른 장소명이 주소로 덮인다.
                if movedFrom(before: originPosition, after: newOrigin) {
                    reverseViewModel.resolve(target: .origin, position: newOrigin)
                }
                if movedFrom(before: destinationPosition, after: newDestination) {
                    reverseViewModel.resolve(target: .destination, position: newDestination)
                }
                adjustedOrigin = newOrigin
                adjustedDestination = newDestination
            },
            onFindCompanions: { conditions in
                if let origin, let destination {
                    // 조정한 좌표와 **갱신된 이름**을 그대로 방 생성 요청에 태운다.
                    // 주소를 못 받았으면 renamedTo(address: nil) 이 원래 이름을 유지한다.
                    viewModel.createParty(
                        origin: origin.movedTo(position: adjustedOrigin).renamedTo(address: resolvedNames.originAddress),
                        destination: destination.movedTo(position: adjustedDestination)
                            .renamedTo(address: resolvedNames.destinationAddress),
                        conditions: conditions
                    )
                }
            },
            nearbyCandidates: nearbyCandidates,
            // 추천을 고르면 **방을 만들지 않고** 그 방의 합류 확인(19)으로 넘긴다 — 합류 흐름은
            // 이미 있는 걸 그대로 쓴다. 인원·요금처럼 추천 응답에 없던 값은 거기서 방 상세로 채워진다.
            onCandidateClick: { candidate in onCandidateSelected(candidate.ride) },
            // 「후보 0건」과 「못 물어봤다」를 모달이 구별해 그릴 수 있게 실패를 따로 넘긴다.
            // 409(이미 참여 중)는 여기가 아니라 errorMessage 슬롯으로 간다 — 그 상태에서는
            // 「방 만들기」도 같은 409 로 막히므로 재시도가 아니라 안내가 맞다.
            nearbyLoadFailed: candidatesState == .failed,
            onRetryNearby: { candidatesViewModel.retry() }
        )
        .task(id: state.createdParty) {
            if let created = state.createdParty { onPartyCreated(created) }
        }
        // 진입 시 1회 + 핀 조정으로 좌표가 바뀔 때마다 경로 미리보기를 다시 부른다.
        // 「걸어서 가까운 방」 추천도 **같은 좌표로 같이** 1회. 폴링하지 않는다
        // (후보마다 서버가 도보 경로를 2번 계산한다).
        .task(id: PositionsKey(origin: originPosition, destination: destinationPosition)) {
            routeViewModel.preview(origin: originPosition, destination: destinationPosition)
            candidatesViewModel.find(origin: originPosition, destination: destinationPosition)
        }
        .task(id: needsActivePartyRefresh) {
            if needsActivePartyRefresh { onActivePartyRefresh() }
        }
        // GPS 로 잡은 출발지는 이름이 「현재 위치」라는 고정 문구뿐이라 진입하자마자 실주소로 바꾼다.
        // 검색으로 고른 장소명(「CGV 서면」)은 사용자가 고른 정답이므로 건드리지 않는다.
        // 키가 origin 자체라 조정으로 좌표가 바뀌어도 재실행되지 않는다 — 조정 쪽은 onAdjustPositions 담당.
        .task(id: origin) {
            if let origin, origin.name == CurrentLocationName {
                reverseViewModel.resolve(
                    target: .origin,
                    position: latLngOrNull(latitude: origin.latitude, longitude: origin.longitude)
                )
            }
        }
    }
}

/// 「오후 6:45」 형식의 시계 라벨.
func clockLabel(minutesFromNow: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
    let time = calendar.date(byAdding: .minute, value: minutesFromNow, to: now) ?? now
    let hour24 = calendar.component(.hour, from: time)
    let meridiem = hour24 < 12 ? "오전" : "오후"
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    let minute = calendar.component(.minute, from: time)
    return "\(meridiem) \(hour12):\(minute < 10 ? "0" : "")\(minute)"
}

extension Place {
    /// 조정 좌표가 있으면 갈아 끼운다. 없으면(조정 안 함) 검색 결과를 그대로 쓴다.
    func movedTo(position: LatLng?) -> Place {
        guard let position else { return self }
        var moved = self
        moved.latitude = position.latitude
        moved.longitude = position.longitude
        return moved
    }

    /// 역지오코딩으로 받은 주소가 있으면 이름을 그것으로 바꾼다. 없으면(실패·주소 없는 좌표) 원래 이름 유지.
    /// 도로명은 비운다 — 이름 자리가 이미 주소라 서버에 같은 문자열을 두 번 실어 보낼 이유가 없다.
    func renamedTo(address: String?) -> Place {
        guard let address else { return self }
        var renamed = self
        renamed.name = address
        renamed.roadName = ""
        return renamed
    }
}

/// 핀이 실제로 움직였는지. 조금이라도 다르면 새 좌표다 — 팬 한 번에 소수점 아래가 바뀐다.
func movedFrom(before: LatLng?, after: LatLng?) -> Bool {
    guard let after else { return false }
    guard let before else { return true }
    return before.latitude != after.latitude || before.longitude != after.longitude
}
