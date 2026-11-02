import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureHome

/// 원본에는 없는 테스트. 원본이 화면 코드에 적어 둔 15 목적지의 규칙과 `DestinationViewModel` 상태 전이를 못 박는다.
@MainActor
@Suite struct DestinationRulesTest {

    private func place(_ name: String, road: String = "도로명", latitude: Double = 35.0, longitude: Double = 129.0) -> Place {
        Place(name: name, roadName: road, latitude: latitude, longitude: longitude)
    }

    private func viewModel(_ repository: ScriptedSearchRepository) -> DestinationViewModel {
        DestinationViewModel(repository: repository, sleep: { _ in })
    }

    // ─── 화면 규칙 ──────────────────────────────────────────────────────────

    @Test("50m 안이면 같은 자리다")
    func sameSpotRadius() {
        // 위도 0.0004도 ≈ 44m, 0.001도 ≈ 111m
        #expect(isSameSpot(originLatitude: 35.0, originLongitude: 129.0, destination: place("a", latitude: 35.0004)))
        #expect(!isSameSpot(originLatitude: 35.0, originLongitude: 129.0, destination: place("a", latitude: 35.001)))
    }

    @Test("좌표가 없거나 유한하지 않으면 같은 자리로 판정하지 않는다")
    func sameSpotNeedsCoordinates() {
        let target = place("a")
        #expect(!isSameSpot(originLatitude: nil, originLongitude: 129.0, destination: target))
        #expect(!isSameSpot(originLatitude: 35.0, originLongitude: nil, destination: target))
        #expect(!isSameSpot(originLatitude: .nan, originLongitude: 129.0, destination: target))
        #expect(!isSameSpot(originLatitude: 35.0, originLongitude: .infinity, destination: target))
        #expect(!isSameSpot(originLatitude: 35.0, originLongitude: 129.0, destination: place("a", latitude: .nan)))
        #expect(!isSameSpot(originLatitude: 35.0, originLongitude: 129.0, destination: place("a", longitude: .infinity)))
    }

    @Test("이름이 같거나 50m 안이면 너무 가깝다")
    func tooClose() {
        let far = place("서면역", latitude: 35.1, longitude: 129.1)
        #expect(isTooClose(selectedPlace: far, origin: " 서면역 ", originLatitude: 35.0, originLongitude: 129.0))
        #expect(isTooClose(selectedPlace: place("서면역", latitude: 35.0004), origin: "현재 위치", originLatitude: 35.0, originLongitude: 129.0))
        #expect(!isTooClose(selectedPlace: far, origin: "현재 위치", originLatitude: 35.0, originLongitude: 129.0))
        #expect(!isTooClose(selectedPlace: far, origin: "현재 위치", originLatitude: nil, originLongitude: nil))
        #expect(!isTooClose(selectedPlace: nil, origin: "현재 위치", originLatitude: 35.0, originLongitude: 129.0))
        #expect(!isTooClose(selectedPlace: far, origin: nil, originLatitude: 35.1, originLongitude: 129.1))
    }

    @Test("도로명이 비면 선택 표시에 구분자를 남기지 않는다")
    func selectedLabel() {
        #expect(selectedPlaceLabel(place("서면역", road: "부산 부산진구 중앙대로 730")) == "선택: 서면역 · 부산 부산진구 중앙대로 730")
        #expect(selectedPlaceLabel(place("서면역", road: "")) == "선택: 서면역")
        #expect(selectedPlaceLabel(place("서면역", road: "  ")) == "선택: 서면역")
    }

    @Test("출발지 행 오른쪽 라벨")
    func originBadge() {
        #expect(originBadgeLabel(origin: nil, originIsDefault: true) == "검색")
        #expect(originBadgeLabel(origin: "현재 위치", originIsDefault: true) == "현재 위치")
        #expect(originBadgeLabel(origin: "서면역", originIsDefault: false) == "변경")
    }

    @Test("실좌표 출발지는 좌표만 실값이고 이름은 고정 문구다")
    func currentLocationIsFixedName() {
        let result = currentLocationPlace(UserCoordinates(latitude: 35.1, longitude: 129.1, accuracyMeters: 5))
        #expect(result == Place(name: "현재 위치", roadName: "", latitude: 35.1, longitude: 129.1))
    }

    // ─── 뷰모델 상태 전이 ────────────────────────────────────────────────────

    @Test("즐겨찾기는 sequence 순으로 정렬한다")
    func favoritesSorted() async {
        let repository = ScriptedSearchRepository()
        await repository.setFavorites([
            FavoritePlace(id: 2, name: "b", roadName: "", latitude: 0, longitude: 0, sequence: 5),
            FavoritePlace(id: 1, name: "a", roadName: "", latitude: 0, longitude: 0, sequence: 1),
        ])
        let viewModel = viewModel(repository)
        #expect(viewModel.uiState.favoritesLoading, "조회 시작과 함께 로딩이 서야 한다")
        await viewModel.initialLoad?.value

        #expect(viewModel.uiState.favorites.map(\.id) == [1, 2])
        #expect(!viewModel.uiState.favoritesLoading)
    }

    @Test("검색어는 활성 필드의 것을 갱신하고 공백을 잘라 보낸다")
    func queryGoesToActiveField() async {
        let repository = ScriptedSearchRepository(script: ["서면": .results([place("서면역")])])
        let viewModel = viewModel(repository)

        await viewModel.onQueryChange(" 서면 ")?.value
        #expect(viewModel.uiState.query == " 서면 ")
        #expect(viewModel.uiState.originQuery == "")
        #expect(await repository.searches == ["서면"])
        #expect(viewModel.uiState.searchResults == [place("서면역")])

        await viewModel.focusField(.origin)?.value
        await viewModel.onQueryChange("부산")?.value
        #expect(viewModel.uiState.originQuery == "부산")
        #expect(viewModel.uiState.query == " 서면 ")
    }

    @Test("빈 검색어는 서버를 부르지 않고 결과를 비운다")
    func blankQueryClears() async {
        let repository = ScriptedSearchRepository(script: ["서면": .results([place("서면역")])])
        let viewModel = viewModel(repository)
        await viewModel.onQueryChange("서면")?.value

        #expect(viewModel.onQueryChange("  ") == nil)

        #expect(viewModel.uiState.searchResults == [])
        #expect(!viewModel.uiState.searchLoading)
        #expect(await repository.searches == ["서면"])
    }

    // ─── 첫 검색어 (원본 `LaunchedEffect(initialQuery)` 자리) ─────────────────

    @Test("첫 검색어는 비어 있을 때만 넣고 검색한다")
    func initialQueryFillsOnlyBlank() async {
        let repository = ScriptedSearchRepository(script: ["서면": .results([place("서면역")])])
        let viewModel = viewModel(repository)

        #expect(viewModel.applyInitialQuery("  ") == nil)
        #expect(viewModel.uiState.query == "")

        await viewModel.applyInitialQuery("서면")?.value
        #expect(viewModel.uiState.query == "서면")
        #expect(await repository.searches == ["서면"])

        // 이미 검색어가 있으면 키가 바뀌어도 덮지 않는다
        #expect(viewModel.applyInitialQuery("부산역") == nil)
        #expect(viewModel.uiState.query == "서면")
    }

    /// 16 을 열었다 닫아 15 가 다시 나타나도 원본은 첫 검색어를 다시 읽지 않는다.
    @Test("화면이 다시 나타나도 지운 검색어를 되살리지 않는다")
    func initialQueryDoesNotReviveClearedQuery() async {
        let repository = ScriptedSearchRepository(script: ["서면": .results([place("서면역")])])
        let viewModel = viewModel(repository)
        await viewModel.applyInitialQuery("서면")?.value
        viewModel.onQueryChange("")

        #expect(viewModel.applyInitialQuery("서면") == nil)

        #expect(viewModel.uiState.query == "")
        #expect(viewModel.uiState.searchResults == [])
        #expect(await repository.searches == ["서면"])
    }

    @Test("화면이 다시 나타나도 출발지 칸에 첫 검색어를 넣지 않는다")
    func initialQueryDoesNotLeakIntoOriginField() async {
        let repository = ScriptedSearchRepository(script: ["서면": .results([place("서면역")])])
        let viewModel = viewModel(repository)
        await viewModel.applyInitialQuery("서면")?.value
        viewModel.onQueryChange("")
        await viewModel.focusField(.origin)?.value

        #expect(viewModel.applyInitialQuery("서면") == nil)

        #expect(viewModel.uiState.originQuery == "")
        #expect(viewModel.uiState.query == "")
    }

    /// `LaunchedEffect` 는 키가 바뀌면 다시 돈다. 그 규칙은 그대로다.
    @Test("첫 검색어 값이 바뀌면 다시 읽는다")
    func initialQueryRereadsOnKeyChange() async {
        let repository = ScriptedSearchRepository(script: [
            "서면": .results([place("서면역")]),
            "부산역": .results([place("부산역")]),
        ])
        let viewModel = viewModel(repository)
        await viewModel.applyInitialQuery("서면")?.value
        viewModel.onQueryChange("")

        await viewModel.applyInitialQuery("부산역")?.value

        #expect(viewModel.uiState.query == "부산역")
    }

    @Test("디바운스 300ms 를 지난 뒤에야 검색한다")
    func debounceIs300ms() async {
        let durations = DurationLog()
        let repository = ScriptedSearchRepository()
        let viewModel = DestinationViewModel(repository: repository, sleep: { await durations.append($0) })

        await viewModel.onQueryChange("서면")?.value

        #expect(await durations.values == [.milliseconds(300)])
    }

    @Test("필드를 옮기면 결과를 비우고 그 필드의 검색어로 다시 검색한다")
    func focusFieldResearches() async {
        let repository = ScriptedSearchRepository(script: [
            "도착": .results([place("도착지")]),
            "출발": .results([place("출발지")]),
        ])
        let viewModel = viewModel(repository)
        await viewModel.onQueryChange("도착")?.value
        await viewModel.focusField(.origin)?.value
        #expect(viewModel.uiState.activeField == .origin)
        #expect(viewModel.uiState.searchResults == [], "출발지 검색어가 비었으면 도착지 결과가 남으면 안 된다")

        await viewModel.onQueryChange("출발")?.value
        let task = viewModel.focusField(.destination)
        #expect(viewModel.uiState.searchResults == [])
        await task?.value
        #expect(viewModel.uiState.searchResults == [place("도착지")])

        #expect(viewModel.focusField(.destination) == nil, "같은 필드면 아무 일도 하지 않는다")
    }

    @Test("출발지를 고르면 도착지 입력으로 넘어가고 도착지 검색어로 다시 검색한다")
    func selectOriginMovesToDestination() async {
        let repository = ScriptedSearchRepository(script: ["도착": .results([place("도착지")])])
        let viewModel = viewModel(repository)
        await viewModel.onQueryChange("도착")?.value
        await viewModel.focusField(.origin)?.value

        let chosen = place("부산역")
        await viewModel.selectPlace(chosen)?.value

        let state = viewModel.uiState
        #expect(state.selectedOrigin == chosen)
        #expect(state.originQuery == "부산역")
        #expect(state.activeField == .destination)
        #expect(state.selectedPlace == nil)
        #expect(state.origin == chosen)
        #expect(state.searchResults == [place("도착지")])
    }

    @Test("도착지를 고르면 selectedPlace 만 바뀐다")
    func selectDestination() {
        let viewModel = viewModel(ScriptedSearchRepository())
        let chosen = place("서면역")

        #expect(viewModel.selectPlace(chosen) == nil)

        #expect(viewModel.uiState.selectedPlace == chosen)
        #expect(viewModel.uiState.selectedOrigin == nil)
        #expect(viewModel.uiState.activeField == .destination)
    }

    @Test("출발지는 고른 곳이 실위치보다 우선이고 둘 다 없으면 nil 이다")
    func originPriority() {
        let viewModel = viewModel(ScriptedSearchRepository())
        #expect(viewModel.uiState.origin == nil)

        let here = place("현재 위치")
        viewModel.setCurrentLocation(here)
        #expect(viewModel.uiState.origin == here)

        viewModel.focusField(.origin)
        let chosen = place("부산역")
        viewModel.selectPlace(chosen)
        #expect(viewModel.uiState.origin == chosen)

        viewModel.setCurrentLocation(nil)
        #expect(viewModel.uiState.origin == chosen)
    }

    @Test("담기에 성공하면 문구를 세우고 목록을 다시 받는다")
    func addSuccess() async {
        let repository = ScriptedSearchRepository()
        let viewModel = viewModel(repository)
        await viewModel.initialLoad?.value
        let saved = FavoritePlace(id: 7, name: "서면역", roadName: "도로명", latitude: 35, longitude: 129, sequence: 1)
        await repository.setFavorites([saved])

        await viewModel.addFavorite(place("서면역"))?.value

        #expect(viewModel.uiState.favoriteActionMessage == "서면역을(를) 자주 가는 곳에 담았어요")
        #expect(viewModel.uiState.favorites == [saved])
        #expect(!viewModel.uiState.favoriteActionLoading)
    }

    @Test("담기에 실패하면 사유를 가리지 않고 알린다")
    func addFailure() async {
        let repository = ScriptedSearchRepository()
        await repository.setAddError(URLError(.badServerResponse))
        let viewModel = viewModel(repository)
        await viewModel.initialLoad?.value

        await viewModel.addFavorite(place("서면역"))?.value

        #expect(viewModel.uiState.favoriteActionMessage == "자주 가는 곳에 담지 못했어요 (중복이거나 10개를 넘었을 수 있어요)")
        #expect(!viewModel.uiState.favoriteActionLoading)
    }

    /// 단건 삭제가 멱등이 아니라 연타가 404 로 보인다. 잠금은 태스크가 돌기 전에 서야 한다.
    @Test("요청 중의 담기·빼기 연타는 잠금에서 막힌다")
    func actionLockIsImmediate() async {
        let repository = ScriptedSearchRepository()
        let viewModel = viewModel(repository)
        await viewModel.initialLoad?.value

        let first = viewModel.addFavorite(place("서면역"))
        #expect(viewModel.uiState.favoriteActionLoading)
        #expect(viewModel.addFavorite(place("부산역")) == nil)
        #expect(viewModel.removeFavorite(id: 1) == nil)
        await first?.value

        #expect(await repository.added == [place("서면역")])
    }

    @Test("이름을 모르는 곳을 빼면 이름 없이 알린다")
    func removeUnknownName() async {
        let viewModel = viewModel(ScriptedSearchRepository())
        await viewModel.initialLoad?.value

        await viewModel.removeFavorite(id: 99)?.value

        #expect(viewModel.uiState.favoriteActionMessage == "자주 가는 곳에서 뺐어요")
    }

    @Test("장소를 고르면 담기 결과 문구를 지운다")
    func selectClearsActionMessage() async {
        let viewModel = viewModel(ScriptedSearchRepository())
        await viewModel.initialLoad?.value
        await viewModel.addFavorite(place("서면역"))?.value
        #expect(viewModel.uiState.favoriteActionMessage != nil)

        viewModel.selectPlace(place("서면역"))

        #expect(viewModel.uiState.favoriteActionMessage == nil)
    }

    /// 원본 `catch (e: Exception)` 은 OkHttp `IOException("Canceled")` 도 같은 문구로 받는다.
    @Test("즐겨찾기 조회가 실패하면 문구를 세우고, 살아 있는 태스크의 URLError(.cancelled) 도 실패다")
    func loadFailureAndLiveUrlCancel() async {
        let failing = FailingFavoritesRepository(error: URLError(.timedOut))
        let failed = DestinationViewModel(repository: failing, sleep: { _ in })
        await failed.initialLoad?.value
        #expect(failed.uiState.favoritesErrorMessage == "자주 가는 곳을 불러오지 못했어요")
        #expect(!failed.uiState.favoritesLoading)

        let cancelling = FailingFavoritesRepository(error: URLError(.cancelled))
        let cancelled = DestinationViewModel(repository: cancelling, sleep: { _ in })
        await cancelled.initialLoad?.value
        #expect(cancelled.uiState.favoritesErrorMessage == "자주 가는 곳을 불러오지 못했어요")
        #expect(!cancelled.uiState.favoritesLoading)
    }

    @Test("태스크가 정말 취소된 즐겨찾기 조회는 문구를 세우지 않는다")
    func cancelledLoadWritesNoMessage() async {
        let cancelling = FailingFavoritesRepository(error: URLError(.cancelled))
        let viewModel = DestinationViewModel(repository: cancelling, sleep: { _ in })
        viewModel.initialLoad?.cancel()
        await viewModel.initialLoad?.value

        #expect(viewModel.uiState.favoritesErrorMessage == nil)
    }

    /// 원본 `catch (e: Exception)` — 담기 실패 문구가 없으면 눌렀는데 아무 일도 없는 것처럼 보인다.
    @Test("즐겨찾기 담기가 살아 있는 태스크의 URLError(.cancelled) 로 끝나면 실패 문구를 세우고 잠금을 푼다")
    func addFavoriteLiveUrlCancel() async {
        let repository = ScriptedSearchRepository()
        await repository.setAddError(URLError(.cancelled))
        let viewModel = viewModel(repository)

        await viewModel.addFavorite(place("서면역"))?.value

        #expect(viewModel.uiState.favoriteActionMessage == "자주 가는 곳에 담지 못했어요 (중복이거나 10개를 넘었을 수 있어요)")
        #expect(!viewModel.uiState.favoriteActionLoading)
    }
}

private actor DurationLog {
    private(set) var values: [Duration] = []

    func append(_ value: Duration) {
        values.append(value)
    }
}

private struct FailingFavoritesRepository: PlaceRepository {
    let error: any Error

    func searchPlaces(query: String) async throws -> [Place] { [] }
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? { nil }
    func addFavoritePlace(place: Place) async throws {}
    func getFavoritePlaces() async throws -> [FavoritePlace] { throw error }
    func deleteFavoritePlace(id: Int64) async throws {}
    func deleteFavoritePlaces(ids: [Int64]) async throws {}
    func deleteAllFavoritePlaces() async throws {}
}
