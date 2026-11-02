import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import Testing
@testable import FeatureHome

// 원본에는 없는 테스트다. 원본 `DestinationConfirmRoute.kt` 의 뷰모델 네 개와 파일 안의 순수 규칙을 못 박는다.
// 특히 Swift 태스크는 코루틴과 달리 취소돼도 끝난 호출의 값을 돌려주므로, `flatMapLatest` 자리의 「옛 응답이
// 최신 값을 덮지 못한다」를 직접 확인한다.

private struct NetworkFailure: Error {}

/// 취소를 듣지 않는 관문. 취소된 태스크도 열리면 값을 돌려준다 — 끊긴 요청의 늦은 응답을 재현한다.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func ride(_ id: String = "7") -> Ride {
    Ride(
        id: id,
        origin: "출발",
        destination: "도착",
        departureLabel: "",
        capacity: 3,
        members: [],
        farePerPerson: 0,
        totalFare: 0,
        status: .recruiting
    )
}

/// 이 화면이 부르는 세 호출만 쓴다. 나머지는 부르면 던진다.
private final class FakeRideRepository: RideRepository, @unchecked Sendable {
    typealias Coordinates = (Double, Double, Double, Double)

    private let lock = NSLock()
    private var createRequests: [NewParty] = []
    private var previewCalls = 0
    private var candidateCalls = 0

    var createResult: @Sendable (NewParty) async throws -> Ride = { _ in ride() }
    var previewResult: @Sendable (Double) async throws -> RouteEstimate = { _ in
        RouteEstimate(estimatedFare: 7900, estimatedMinutes: 12, encodedPath: "")
    }
    var candidatesResult: @Sendable () async throws -> [MatchCandidate] = { [] }

    var requests: [NewParty] { lock.withLock { createRequests } }
    var previewCount: Int { lock.withLock { previewCalls } }
    var candidateCount: Int { lock.withLock { candidateCalls } }

    func createParty(request: NewParty) async throws -> Ride {
        lock.withLock { createRequests.append(request) }
        return try await createResult(request)
    }

    func previewRoute(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> RouteEstimate {
        lock.withLock { previewCalls += 1 }
        return try await previewResult(departureLat)
    }

    func findRealtimeCandidates(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> [MatchCandidate] {
        lock.withLock { candidateCalls += 1 }
        return try await candidatesResult()
    }

    func getNearbyParties() -> [Ride] { [] }
    func getParties() async throws -> [Ride] { throw NetworkFailure() }
    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] {
        throw NetworkFailure()
    }
    func getPartyDetail(partyId: Int64) async throws -> Ride { throw NetworkFailure() }
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail { throw NetworkFailure() }
    func joinParty(partyId: Int64) async throws -> PartyStatus { throw NetworkFailure() }
    func leaveParty(partyId: Int64) async throws { throw NetworkFailure() }
    func finishParty(partyId: Int64) async throws { throw NetworkFailure() }
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw NetworkFailure() }
    func reportEmergency(partyId: Int64?) async throws -> Int64 { throw NetworkFailure() }
    func confirmEmergencyCall(called: Bool) async throws { throw NetworkFailure() }
}

/// 역지오코딩만 쓴다.
private final class FakeGeocodeRepository: PlaceRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var result: @Sendable (Double) async throws -> ReverseAddress? = { _ in nil }

    var callCount: Int { lock.withLock { calls } }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? {
        lock.withLock { calls += 1 }
        return try await result(latitude)
    }

    func searchPlaces(query: String) async throws -> [Place] { [] }
    func addFavoritePlace(place: Place) async throws {}
    func getFavoritePlaces() async throws -> [FavoritePlace] { [] }
    func deleteFavoritePlace(id: Int64) async throws {}
    func deleteFavoritePlaces(ids: [Int64]) async throws {}
    func deleteAllFavoritePlaces() async throws {}
}

private func address(_ text: String) -> ReverseAddress {
    ReverseAddress(address: text, roadAddress: text, jibunAddress: nil)
}

private let origin = Place(name: "부산대역", roadName: "부산대로", latitude: 35.23, longitude: 129.08)
private let destination = Place(name: "서면역", roadName: "중앙대로", latitude: 35.15, longitude: 129.05)
private let a = LatLng(35.23, 129.08)
private let b = LatLng(35.15, 129.05)
private let c = LatLng(35.10, 129.03)

@MainActor
@Suite struct CreatePartyViewModelTest {

    @Test("요청에 좌표·이름·정원을 싣고 만든 방을 상태에 넣는다")
    func success() async {
        let repository = FakeRideRepository()
        let viewModel = CreatePartyViewModel(repository: repository)

        await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 2))?.value

        #expect(
            repository.requests == [
                NewParty(
                    departureLat: 35.23,
                    departureLng: 129.08,
                    destinationLat: 35.15,
                    destinationLng: 129.05,
                    departure: "부산대역",
                    destination: "서면역",
                    capacity: 2
                ),
            ]
        )
        #expect(viewModel.uiState == CreatePartyViewModel.UiState(createdParty: ride()))
    }

    @Test("정원은 서버 범위 1~3 으로 고정해 보낸다")
    func capacityClamped() async {
        let repository = FakeRideRepository()
        let viewModel = CreatePartyViewModel(repository: repository)

        await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 9))?.value
        await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 0))?.value

        #expect(repository.requests.map(\.capacity) == [3, 1])
    }

    /// 원본 `Dispatchers.Main.immediate` 는 첫 줄이 곧바로 돈다. `Task` 는 다음 차례로 밀리므로 잠금을 호출 자리에서 건다.
    @Test("요청 중에는 중복 제출을 막는다")
    func duplicateBlocked() async {
        let repository = FakeRideRepository()
        let gate = Gate()
        repository.createResult = { _ in
            await gate.wait()
            return ride()
        }
        let viewModel = CreatePartyViewModel(repository: repository)
        let conditions = MatchConditions(capacity: 3)

        let first = viewModel.createParty(origin: origin, destination: destination, conditions: conditions)
        #expect(viewModel.uiState.creating)
        #expect(viewModel.createParty(origin: origin, destination: destination, conditions: conditions) == nil)

        await gate.open()
        await first?.value
        #expect(!viewModel.uiState.creating)
        #expect(repository.requests.count == 1)
    }

    /// 409 는 문구만으로 풀리지 않는다 — 홈 배너가 뜨도록 진행 중 방 조회를 되살린다.
    @Test("이미 참여 중이면 문구와 함께 진행 중 방 조회를 되살린다")
    func alreadyInPartyRaisesRefresh() async {
        let repository = FakeRideRepository()
        repository.createResult = { _ in
            throw PartyOpenException(
                code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY,
                serverMessage: nil,
                httpStatus: 409
            )
        }
        let viewModel = CreatePartyViewModel(repository: repository)

        await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 3))?.value

        #expect(viewModel.uiState.errorMessage == ALREADY_IN_PARTY_MESSAGE)
        #expect(viewModel.uiState.needsActivePartyRefresh)
        #expect(!viewModel.uiState.creating)
    }

    @Test("다른 사유는 진행 중 방 조회를 건드리지 않고, 다시 제출하면 문구를 지운다")
    func otherFailureThenRetry() async {
        let repository = FakeRideRepository()
        repository.createResult = { _ in
            throw PartyOpenException(code: PartyOpenException.SAME_DEPARTURE_DESTINATION, serverMessage: nil, httpStatus: 400)
        }
        let viewModel = CreatePartyViewModel(repository: repository)
        let conditions = MatchConditions(capacity: 3)

        await viewModel.createParty(origin: origin, destination: destination, conditions: conditions)?.value
        #expect(viewModel.uiState.errorMessage == "출발지와 도착지가 같아요. 핀을 옮겨 조금 떨어뜨려 주세요")
        #expect(!viewModel.uiState.needsActivePartyRefresh)

        let gate = Gate()
        repository.createResult = { _ in
            await gate.wait()
            return ride()
        }
        let retry = viewModel.createParty(origin: origin, destination: destination, conditions: conditions)
        #expect(viewModel.uiState.errorMessage == nil)
        await gate.open()
        await retry?.value
    }

    @Test("좁혀지지 않은 실패는 일반 문구다")
    func unknownFailure() async {
        let repository = FakeRideRepository()
        repository.createResult = { _ in throw NetworkFailure() }
        let viewModel = CreatePartyViewModel(repository: repository)

        await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 3))?.value

        #expect(viewModel.uiState.errorMessage == "동승 방을 만들지 못했어요. 잠시 후 다시 시도해 주세요")
        #expect(!viewModel.uiState.needsActivePartyRefresh)
    }

    @Test("태스크가 정말 취소되면 무슨 오류로 끝나든 문구를 띄우지 않고 잠금만 푼다")
    func cancellationIsSilent() async {
        for failure: any Error in [CancellationError(), URLError(.cancelled)] {
            let repository = FakeRideRepository()
            repository.createResult = { _ in throw failure }
            let viewModel = CreatePartyViewModel(repository: repository)

            let task = viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 3))
            task?.cancel()
            await task?.value

            #expect(viewModel.uiState == CreatePartyViewModel.UiState())
        }
    }

    /// 원본은 OkHttp `IOException("Canceled")` 이 코드 없는 `PartyOpenException` 이 되어 일반 문구로 간다.
    /// 문구 없이 잠금만 풀면 「같이 탈 사람 찾기」를 눌렀는데 아무 일도 없는 화면이 된다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 일반 실패 문구를 띄운다")
    func liveUrlCancelShowsFailure() async {
        let repository = FakeRideRepository()
        repository.createResult = { _ in throw URLError(.cancelled) }
        let viewModel = CreatePartyViewModel(repository: repository)

        await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 3))?.value

        #expect(!viewModel.uiState.creating)
        #expect(viewModel.uiState.errorMessage == "동승 방을 만들지 못했어요. 잠시 후 다시 시도해 주세요")
    }
}

@MainActor
@Suite struct RoutePreviewViewModelTest {

    @Test("좌표가 있으면 불러 값을 넣고, 같은 좌표로는 다시 부르지 않는다")
    func loadsOncePerCoordinates() async {
        let repository = FakeRideRepository()
        let viewModel = RoutePreviewViewModel(repository: repository)

        let task = viewModel.preview(origin: a, destination: b)
        #expect(viewModel.uiState == .loading)
        await task?.value
        #expect(viewModel.uiState == .success(estimate: RouteEstimate(estimatedFare: 7900, estimatedMinutes: 12, encodedPath: "")))

        #expect(viewModel.preview(origin: a, destination: b) == nil)
        #expect(repository.previewCount == 1)
    }

    @Test("좌표 중 하나라도 없으면 비운다")
    func missingCoordinate() async {
        let repository = FakeRideRepository()
        let viewModel = RoutePreviewViewModel(repository: repository)

        #expect(viewModel.preview(origin: nil, destination: b) == nil)
        #expect(viewModel.uiState == .idle)

        await viewModel.preview(origin: a, destination: b)?.value
        #expect(viewModel.preview(origin: a, destination: nil) == nil)
        #expect(viewModel.uiState == .idle)
        #expect(repository.previewCount == 1)
    }

    @Test("실패하면 값만 감춘다")
    func failureHidesValue() async {
        let repository = FakeRideRepository()
        repository.previewResult = { _ in throw NetworkFailure() }
        let viewModel = RoutePreviewViewModel(repository: repository)

        await viewModel.preview(origin: a, destination: b)?.value

        #expect(viewModel.uiState == .error)
    }

    @Test("늦게 끝난 옛 좌표의 응답이 최신 값을 덮지 못한다")
    func staleResponseDropped() async {
        let repository = FakeRideRepository()
        let gate = Gate()
        repository.previewResult = { latitude in
            if latitude == a.latitude { await gate.wait() }
            return RouteEstimate(estimatedFare: Int(latitude * 100), estimatedMinutes: 1, encodedPath: "")
        }
        let viewModel = RoutePreviewViewModel(repository: repository)

        let stale = viewModel.preview(origin: a, destination: b)
        let latest = viewModel.preview(origin: c, destination: b)
        await latest?.value
        let expected = RoutePreviewViewModel.UiState.success(
            estimate: RouteEstimate(estimatedFare: Int(c.latitude * 100), estimatedMinutes: 1, encodedPath: "")
        )
        #expect(viewModel.uiState == expected)

        await gate.open()
        await stale?.value
        #expect(viewModel.uiState == expected)
    }
}

@MainActor
@Suite struct NearbyCandidatesViewModelTest {

    private let first = MatchCandidate(ride: ride("1"), walkSeconds: 300)
    private let second = MatchCandidate(ride: ride("2"), walkSeconds: 60)

    /// 서버가 도보 시간 순으로 정렬했으므로 앱이 다시 정렬하지 않는다 — 일부러 거꾸로 된 값을 넣어 본다.
    @Test("받은 순서 그대로 둔다")
    func keepsServerOrder() async {
        let repository = FakeRideRepository()
        let expected = [first, second]
        repository.candidatesResult = { expected }
        let viewModel = NearbyCandidatesViewModel(repository: repository)

        let task = viewModel.find(origin: a, destination: b)
        #expect(viewModel.uiState == .loading)
        await task?.value

        #expect(viewModel.uiState == .success(candidates: expected))
    }

    @Test("빈 목록은 숨김이다")
    func emptyIsHidden() async {
        let viewModel = NearbyCandidatesViewModel(repository: FakeRideRepository())

        await viewModel.find(origin: a, destination: b)?.value

        #expect(viewModel.uiState == .hidden)
    }

    @Test("409 와 그 밖의 실패를 가른다")
    func failuresSplit() async {
        let repository = FakeRideRepository()
        repository.candidatesResult = {
            throw RealtimeMatchException(code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY, serverMessage: nil, httpStatus: 409)
        }
        let viewModel = NearbyCandidatesViewModel(repository: repository)
        await viewModel.find(origin: a, destination: b)?.value
        #expect(viewModel.uiState == .alreadyInParty)

        repository.candidatesResult = { throw NetworkFailure() }
        await viewModel.find(origin: c, destination: b)?.value
        #expect(viewModel.uiState == .failed)
    }

    /// `find` 는 같은 좌표를 걸러 내므로, 재시도가 없으면 실패한 좌표를 다시 물을 길이 없다.
    @Test("같은 좌표로는 다시 부르지 않지만 재시도는 다시 부른다")
    func retryBypassesDedupe() async {
        let repository = FakeRideRepository()
        repository.candidatesResult = { throw NetworkFailure() }
        let viewModel = NearbyCandidatesViewModel(repository: repository)

        await viewModel.find(origin: a, destination: b)?.value
        #expect(viewModel.find(origin: a, destination: b) == nil)
        #expect(repository.candidateCount == 1)

        let expected = [first]
        repository.candidatesResult = { expected }
        await viewModel.retry()?.value

        #expect(repository.candidateCount == 2)
        #expect(viewModel.uiState == .success(candidates: expected))
    }

    @Test("좌표가 없으면 재시도해도 부르지 않고 숨긴다")
    func retryWithoutCoordinates() {
        let repository = FakeRideRepository()
        let viewModel = NearbyCandidatesViewModel(repository: repository)

        #expect(viewModel.retry() == nil)
        #expect(viewModel.uiState == .hidden)
        #expect(repository.candidateCount == 0)
    }
}

@MainActor
@Suite struct ReverseGeocodeViewModelTest {

    @Test("대상별로 주소를 넣고, 같은 좌표로 재확정하면 다시 부르지 않는다")
    func appliesPerTarget() async {
        let repository = FakeGeocodeRepository()
        repository.result = { _ in address("부산 금정구 부산대학로 63") }
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        await viewModel.resolve(target: .origin, position: a)?.value
        #expect(viewModel.uiState == ReverseGeocodeViewModel.UiState(originAddress: "부산 금정구 부산대학로 63"))

        #expect(viewModel.resolve(target: .origin, position: a) == nil)
        #expect(repository.callCount == 1)
    }

    @Test("이미 받은 좌표는 다른 대상에도 캐시로 넣는다")
    func cacheSharedAcrossTargets() async {
        let repository = FakeGeocodeRepository()
        repository.result = { _ in address("주소") }
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        await viewModel.resolve(target: .origin, position: a)?.value
        #expect(viewModel.resolve(target: .destination, position: a) == nil)

        #expect(viewModel.uiState.destinationAddress == "주소")
        #expect(repository.callCount == 1)
    }

    /// 「주소가 없는 좌표」라는 사실 자체가 안정된 결과라 nil 도 캐시한다.
    @Test("주소가 없는 좌표는 이름을 유지하고 그 사실도 캐시한다")
    func nilCached() async {
        let repository = FakeGeocodeRepository()
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        await viewModel.resolve(target: .origin, position: a)?.value
        #expect(viewModel.uiState == ReverseGeocodeViewModel.UiState())

        #expect(viewModel.resolve(target: .destination, position: a) == nil)
        #expect(viewModel.uiState == ReverseGeocodeViewModel.UiState())
        #expect(repository.callCount == 1)
    }

    @Test("실패는 조용하고 다음 확정 때 다시 시도한다")
    func failureAllowsRetry() async {
        let repository = FakeGeocodeRepository()
        repository.result = { _ in throw NetworkFailure() }
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        await viewModel.resolve(target: .origin, position: a)?.value
        #expect(viewModel.uiState == ReverseGeocodeViewModel.UiState())

        repository.result = { _ in address("다시 받은 주소") }
        await viewModel.resolve(target: .origin, position: a)?.value

        #expect(repository.callCount == 2)
        #expect(viewModel.uiState.originAddress == "다시 받은 주소")
    }

    /// 원본은 OkHttp `IOException("Canceled")` 을 실패로 받아 `requested` 를 지운다. 남겨 두면 같은 좌표를 다시 확정해도
    /// 「이미 물어봤다」로 건너뛰어 주소가 영영 빈 채로 남는다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 뒤에는 같은 좌표를 다시 부른다")
    func liveUrlCancelRetriesSameCoordinate() async {
        let repository = FakeGeocodeRepository()
        repository.result = { _ in throw URLError(.cancelled) }
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        await viewModel.resolve(target: .origin, position: a)?.value
        #expect(viewModel.uiState == ReverseGeocodeViewModel.UiState())

        repository.result = { _ in address("다시 받은 주소") }
        await viewModel.resolve(target: .origin, position: a)?.value

        #expect(repository.callCount == 2)
        #expect(viewModel.uiState.originAddress == "다시 받은 주소")
    }

    @Test("좌표가 없으면 부르지 않는다")
    func nilPosition() {
        let repository = FakeGeocodeRepository()
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        #expect(viewModel.resolve(target: .origin, position: nil) == nil)
        #expect(repository.callCount == 0)
    }

    /// 취소를 실패로 다루면 `requested` 가 지워져 새 좌표 등록이 날아간다.
    @Test("옛 좌표의 늦은 응답은 버리고 새 좌표를 재확정해도 다시 부르지 않는다")
    func staleResponseDropped() async {
        let repository = FakeGeocodeRepository()
        let gate = Gate()
        repository.result = { latitude in
            if latitude == a.latitude {
                await gate.wait()
                return address("옛 주소")
            }
            return address("새 주소")
        }
        let viewModel = ReverseGeocodeViewModel(repository: repository)

        let stale = viewModel.resolve(target: .origin, position: a)
        let latest = viewModel.resolve(target: .origin, position: c)
        await latest?.value
        await gate.open()
        await stale?.value

        #expect(viewModel.uiState.originAddress == "새 주소")
        #expect(viewModel.resolve(target: .origin, position: c) == nil)
    }
}

@Suite struct DestinationConfirmRulesTest {

    private func kst(hour: Int, minute: Int) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hour, minute: minute))!
        return (date, calendar)
    }

    @Test("시계 라벨은 오전·오후 12시간제이고 분은 두 자리다")
    func clock() {
        let cases: [(Int, Int, Int, String)] = [
            (0, 5, 0, "오전 12:05"),
            (11, 59, 0, "오전 11:59"),
            (12, 0, 0, "오후 12:00"),
            (18, 45, 0, "오후 6:45"),
            (18, 45, 20, "오후 7:05"),
            (23, 50, 15, "오전 12:05"),
        ]
        for (hour, minute, minutesFromNow, expected) in cases {
            let (now, calendar) = kst(hour: hour, minute: minute)
            #expect(clockLabel(minutesFromNow: minutesFromNow, now: now, calendar: calendar) == expected)
        }
    }

    @Test("조정 좌표가 있을 때만 갈아 끼운다")
    func movedToPosition() {
        #expect(origin.movedTo(position: nil) == origin)
        #expect(
            origin.movedTo(position: b)
                == Place(name: "부산대역", roadName: "부산대로", latitude: b.latitude, longitude: b.longitude)
        )
    }

    @Test("주소를 받았으면 이름을 바꾸고 도로명을 비운다")
    func renamedToAddress() {
        #expect(origin.renamedTo(address: nil) == origin)
        #expect(
            origin.renamedTo(address: "부산 금정구")
                == Place(name: "부산 금정구", roadName: "", latitude: origin.latitude, longitude: origin.longitude)
        )
    }

    /// 안 건드린 필드까지 역지오코딩하면 사용자가 고른 장소명이 주소로 덮인다.
    @Test("좌표가 실제로 바뀐 쪽만 움직인 것으로 본다")
    func moved() {
        #expect(!movedFrom(before: a, after: nil))
        #expect(!movedFrom(before: nil, after: nil))
        #expect(movedFrom(before: nil, after: a))
        #expect(!movedFrom(before: a, after: a))
        #expect(movedFrom(before: a, after: LatLng(a.latitude + 0.000001, a.longitude)))
        #expect(movedFrom(before: a, after: LatLng(a.latitude, a.longitude + 0.000001)))
    }

    @Test("요약 칩은 계산 중·값 있음·실패로 갈린다")
    func summaryLabel() {
        let locale = Locale(identifier: "ko_KR")
        #expect(routeSummaryLabel(routePreview: RoutePreviewUi(loading: true), locale: locale) == "예상 경로 계산 중")
        #expect(
            routeSummaryLabel(routePreview: RoutePreviewUi(estimatedMinutes: 12, estimatedFare: 7900), locale: locale)
                == "예상 12분 · 총 7,900원"
        )
        #expect(routeSummaryLabel(routePreview: RoutePreviewUi(), locale: locale) == nil)
        #expect(routeSummaryLabel(routePreview: RoutePreviewUi(estimatedMinutes: 12), locale: locale) == nil)
        #expect(routeSummaryLabel(routePreview: RoutePreviewUi(estimatedFare: 7900), locale: locale) == nil)
    }

    @Test("요금 안내는 인원으로 나눈 값을 쓰고 추정이 없으면 줄표다")
    func fareFooter() {
        let locale = Locale(identifier: "ko_KR")
        let estimated = RoutePreviewUi(estimatedMinutes: 12, estimatedFare: 7900)
        #expect(fareFooterText(routePreview: RoutePreviewUi(loading: true), peopleCount: 3, locale: locale) == "예상 요금 계산 중이에요")
        #expect(fareFooterText(routePreview: estimated, peopleCount: 3, locale: locale) == "예상 요금 1인 2,630원")
        #expect(fareFooterText(routePreview: estimated, peopleCount: 1, locale: locale) == "예상 요금 1인 7,900원")
        #expect(fareFooterText(routePreview: RoutePreviewUi(), peopleCount: 3, locale: locale) == "예상 요금 —")
    }

    @Test("주소 칸이 비면 구분자를 남기지 않는다")
    func badgeLabel() {
        #expect(destinationBadgeLabel(destinationName: "서면역", destinationAddress: "중앙대로") == "서면역 · 중앙대로")
        #expect(destinationBadgeLabel(destinationName: "서면역", destinationAddress: "") == "서면역")
        #expect(destinationBadgeLabel(destinationName: "서면역", destinationAddress: "  ") == "서면역")
    }

    @Test("진입 대상에 좌표가 없으면 반대쪽에서 시작한다")
    func initialTarget() {
        #expect(initialPinTarget(initialTarget: .origin, originPosition: nil, destinationPosition: b) == .destination)
        #expect(initialPinTarget(initialTarget: .destination, originPosition: a, destinationPosition: nil) == .origin)
        #expect(initialPinTarget(initialTarget: .origin, originPosition: a, destinationPosition: b) == .origin)
        #expect(initialPinTarget(initialTarget: .destination, originPosition: a, destinationPosition: b) == .destination)
    }

    @Test("핀 좌표 문구는 소수 여섯째 자리까지다")
    func coordinateLabel() {
        let locale = Locale(identifier: "ko_KR")
        #expect(pinCoordinateLabel(position: LatLng(35.2316, 129.0846), locale: locale) == "35.231600, 129.084600")
        #expect(pinCoordinateLabel(position: nil, locale: locale) == "좌표 없음")
    }
}

@MainActor
@Suite struct PinAdjustWorkingStateTest {

    @Test("카메라 좌표는 지금 조정 중인 쪽에만 쓴다")
    func writesCurrentTargetOnly() {
        let state = PinAdjustWorkingState(target: .origin, originWorking: a, destinationWorking: b)

        state.writeTarget(c)
        #expect(state.originWorking == c)
        #expect(state.destinationWorking == b)
        #expect(state.targetWorking == c)

        state.target = .destination
        #expect(state.targetWorking == b)
        state.writeTarget(a)
        #expect(state.originWorking == c)
        #expect(state.destinationWorking == a)
    }
}
