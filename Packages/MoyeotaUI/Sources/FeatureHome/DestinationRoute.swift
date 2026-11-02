import MoyeotaDomain
import PresentationCore
import SwiftUI

// 실위치로 만든 출발지의 표기 이름. 좌표만 실값이고 이름은 고정 문구다.
// 16 이 이 문구를 보고 「아직 주소를 모르는 GPS 출발지」를 식별해 역지오코딩으로 실주소를 채운다
// (검색으로 고른 장소명은 사용자가 고른 정답이라 건드리지 않는다). 그래서 internal.
let CurrentLocationName = "현재 위치"

/// 기기 실좌표 → 출발지 Place. 좌표만 실값이고 이름·주소는 고정 문구다
func currentLocationPlace(_ coordinates: UserCoordinates) -> Place {
    Place(
        name: CurrentLocationName,
        roadName: "",
        latitude: coordinates.latitude,
        longitude: coordinates.longitude
    )
}

@MainActor
@Observable
public final class DestinationViewModel {

    public struct UiState: Equatable, Sendable {
        // 활성 필드 — 검색어·검색 결과는 이 필드 것으로 해석된다
        public var activeField: DestinationField
        public var originQuery: String
        public var query: String // 도착지 검색어
        public var searchResults: [Place]
        public var searchLoading: Bool
        public var searchErrorMessage: String?
        public var favorites: [FavoritePlace]
        public var favoritesLoading: Bool
        public var favoritesErrorMessage: String?
        public var favoriteActionMessage: String?
        /// 담기·빼기 요청이 날아간 동안 true. 단건 삭제가 멱등이 아니라서 연타를 막는다
        public var favoriteActionLoading: Bool
        // nil = 사용자가 고르지 않음 → 실위치를 쓴다
        public var selectedOrigin: Place?
        // 기기 GPS 로 받은 현재 위치. 권한 거부·미취득이면 nil
        public var currentLocation: Place?
        public var selectedPlace: Place?

        public init(
            activeField: DestinationField = .destination,
            originQuery: String = "",
            query: String = "",
            searchResults: [Place] = [],
            searchLoading: Bool = false,
            searchErrorMessage: String? = nil,
            favorites: [FavoritePlace] = [],
            favoritesLoading: Bool = false,
            favoritesErrorMessage: String? = nil,
            favoriteActionMessage: String? = nil,
            favoriteActionLoading: Bool = false,
            selectedOrigin: Place? = nil,
            currentLocation: Place? = nil,
            selectedPlace: Place? = nil
        ) {
            self.activeField = activeField
            self.originQuery = originQuery
            self.query = query
            self.searchResults = searchResults
            self.searchLoading = searchLoading
            self.searchErrorMessage = searchErrorMessage
            self.favorites = favorites
            self.favoritesLoading = favoritesLoading
            self.favoritesErrorMessage = favoritesErrorMessage
            self.favoriteActionMessage = favoriteActionMessage
            self.favoriteActionLoading = favoriteActionLoading
            self.selectedOrigin = selectedOrigin
            self.currentLocation = currentLocation
            self.selectedPlace = selectedPlace
        }

        // 우선순위: 사용자가 고른 출발지 > 실위치. 둘 다 없으면 nil — 고정 좌표로 채우지 않는다.
        // 방 생성(POST /matching/rooms)은 실제 출발 좌표가 필요하므로 15 가 「경로 확인하기」를 막고
        // 출발지 검색을 안내한다.
        public var origin: Place? { selectedOrigin ?? currentLocation }
    }

    public private(set) var uiState = UiState()

    private let repository: any PlaceRepository
    private let sleep: @Sendable (Duration) async throws -> Void
    private let scope = ViewModelScope()

    @ObservationIgnored private var searchJob: Task<Void, Never>?
    /// 진입 때 시작한 첫 조회. 테스트가 끝을 기다리는 용도다(원본 `advanceUntilIdle` 자리).
    @ObservationIgnored private(set) var initialLoad: Task<Void, Never>?
    /// 마지막으로 읽은 첫 검색어. `applyInitialQuery` 가 같은 값을 다시 읽지 않게 한다.
    @ObservationIgnored private var lastInitialQuery: String?

    /// - Parameter sleep: 원본 `delay(300)` 자리. 테스트가 디바운스를 건너뛸 때 주입한다.
    public init(
        repository: any PlaceRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.sleep = sleep
        initialLoad = loadFavorites()
    }

    // 이 뷰모델의 태스크는 호출 동안 뷰모델을 붙잡지 않는다(`repository` 만 들고 나가 끝난 뒤 `self?` 로 쓴다).
    // 그래야 원본 `viewModelScope` 처럼 화면을 떠나 뷰모델이 해제될 때 요청이 취소된다.
    //
    // 돌려주는 태스크는 테스트가 끝을 기다리는 용도다. 화면은 쓰지 않는다.
    //
    // 상태를 태스크 안이 아니라 호출 자리에서 바로 바꾸는 곳이 있다. 원본의 `Dispatchers.Main.immediate` 는 첫 대기
    // 지점까지 곧바로 실행되지만 `Task` 는 다음 차례로 밀려, 그 틈에 연타가 잠금을 지나간다.
    @discardableResult
    public func loadFavorites() -> Task<Void, Never> {
        uiState.favoritesLoading = true
        uiState.favoritesErrorMessage = nil
        let repository = self.repository
        return scope.launch { [weak self] in
            do {
                // 즐겨찾기 주체는 Bearer 토큰이 정한다 — userId 를 넘기지 않는다 (22 보고서 §2)
                let places = try await repository.getFavoritePlaces()
                guard let self else { return }
                self.uiState.favoritesLoading = false
                self.uiState.favorites = places.sorted { $0.sequence < $1.sequence }
            } catch {
                guard let self else { return }
                self.uiState.favoritesLoading = false
                // 태스크가 정말 취소됐을 때만 문구를 세우지 않는다. 살아 있는 태스크의 `URLError(.cancelled)` 는
                // 원본 `catch (e: Exception)` 이 받는 `IOException` 이다.
                if Task.isCancelled { return }
                self.uiState.favoritesErrorMessage = "자주 가는 곳을 불러오지 못했어요"
            }
        }
    }

    // 타이핑마다 호출하지 않도록 300ms 디바운스 후 검색한다. 활성 필드의 검색어를 갱신한다.
    @discardableResult
    public func onQueryChange(_ query: String) -> Task<Void, Never>? {
        if uiState.activeField == .origin {
            uiState.originQuery = query
        } else {
            uiState.query = query
        }
        uiState.searchErrorMessage = nil
        return runSearch(query)
    }

    /// 14 홈이 넘긴 첫 검색어를 넣는다. 원본 `LaunchedEffect(initialQuery)` 자리.
    ///
    /// 원본은 16 이 15 위에 뜨는 dialog 라 15 가 컴포지션에 남아, 키가 바뀌지 않으면 다시 돌지 않는다.
    /// `.task(id:)` 는 키가 같아도 화면이 다시 나타나면 다시 돈다. 그때 다시 넣으면 사용자가 지운 검색어가
    /// 되살아나고, 출발지 필드가 활성이면 도착지용 검색어가 출발지 칸에 들어간다. 그래서 키가 바뀔 때만 읽는다.
    @discardableResult
    func applyInitialQuery(_ initialQuery: String) -> Task<Void, Never>? {
        if lastInitialQuery == initialQuery { return nil }
        lastInitialQuery = initialQuery
        if initialQuery.isBlank || !uiState.query.isBlank { return nil }
        return onQueryChange(initialQuery)
    }

    // 필드 전환 — 검색 결과는 필드마다 달라야 하므로 비우고 그 필드의 검색어로 다시 검색한다
    @discardableResult
    public func focusField(_ field: DestinationField) -> Task<Void, Never>? {
        if uiState.activeField == field { return nil }
        uiState.activeField = field
        uiState.searchResults = []
        uiState.searchLoading = false
        uiState.searchErrorMessage = nil
        return runSearch(field == .origin ? uiState.originQuery : uiState.query)
    }

    private func runSearch(_ query: String) -> Task<Void, Never>? {
        searchJob?.cancel()
        if query.isBlank {
            uiState.searchResults = []
            uiState.searchLoading = false
            return nil
        }
        let repository = self.repository
        let sleep = self.sleep
        let job = scope.launch { [weak self] in
            do {
                try await sleep(.milliseconds(300))
                try Task.checkCancellation()
                self?.uiState.searchLoading = true
                let results = try await repository.searchPlaces(query: query.trim())
                // 코루틴은 취소되면 재개 자리에서 예외를 던지지만 Swift 는 끝난 호출의 값을 그대로 돌려준다.
                // 여기서 끊지 않으면 앞 글자의 늦은 응답이 새 검색의 결과를 덮는다.
                try Task.checkCancellation()
                guard let self else { return }
                // 성공하면 **이전 실패 문구를 반드시 지운다.** 화면은 에러를 분기의 첫 가지로 두므로
                // (DestinationScreen), 남겨 두면 결과가 와도 그 문구에 가려 한 건도 안 보인다.
                self.uiState.searchLoading = false
                self.uiState.searchResults = results
                self.uiState.searchErrorMessage = nil
            } catch {
                // **취소는 실패가 아니다.** 글자를 칠 때마다 위에서 `searchJob?.cancel()` 로 이전 요청을
                // 끊는데, 그 취소가 여기까지 올라온다. 함께 처리하면 타이핑하는 족족
                // 「검색하지 못했어요」가 서고, 뒤따라 성공한 검색의 결과까지 그 문구에 가려진다.
                // 상태는 새 요청이 곧 덮는다. 끊긴 요청은 어떤 오류로 끝나든 상태를 쓰지 않는다.
                if Task.isCancelled { return }
                guard let self else { return }
                // 살아 있는 태스크의 `URLError(.cancelled)` 는 여기로 온다. 덮어 줄 새 요청이 없고 원본에서는 `IOException` 이다.
                self.uiState.searchLoading = false
                self.uiState.searchResults = []
                self.uiState.searchErrorMessage = "장소를 검색하지 못했어요"
            }
        }
        searchJob = job
        return job
    }

    // 기기 위치 갱신 — 사용자가 출발지를 직접 고른 뒤에는 origin 계산에서 밀려나므로 덮어쓰지 않는다
    public func setCurrentLocation(_ place: Place?) {
        if uiState.currentLocation == place { return }
        uiState.currentLocation = place
    }

    // 검색 결과·자주 가는 곳 선택 — 활성 필드에 따라 출발지/도착지가 정해진다
    @discardableResult
    public func selectPlace(_ place: Place) -> Task<Void, Never>? {
        if uiState.activeField == .origin {
            searchJob?.cancel()
            uiState.selectedOrigin = place
            uiState.originQuery = place.name
            uiState.favoriteActionMessage = nil
            // 출발지를 정했으면 자연스럽게 도착지 입력으로 넘어간다
            uiState.activeField = .destination
            uiState.searchResults = []
            uiState.searchLoading = false
            uiState.searchErrorMessage = nil
            return runSearch(uiState.query)
        } else {
            uiState.selectedPlace = place
            uiState.favoriteActionMessage = nil
            return nil
        }
    }

    @discardableResult
    public func addFavorite(_ place: Place) -> Task<Void, Never>? {
        if uiState.favoriteActionLoading { return nil }
        uiState.favoriteActionLoading = true
        let repository = self.repository
        return scope.launch { [weak self] in
            var reload: Task<Void, Never>?
            do {
                try await repository.addFavoritePlace(place: place)
                self?.uiState.favoriteActionMessage = "\(place.name)을(를) 자주 가는 곳에 담았어요"
                reload = self?.loadFavorites() // 등록 후 목록 재조회
            } catch {
                // 태스크가 정말 취소됐을 때만 문구를 세우지 않는다(살아 있는 태스크의 `URLError(.cancelled)` 는 실패다).
                if !Task.isCancelled {
                    // 서버 409 CONFLICT: 이름 중복 · 10개 초과 (운영 OpenAPI 는 409 를 적어 두지 않았지만
                    // 실제 응답이 409 다 — 컨트롤러 @ApiResponses 누락. 어차피 사유를 가리지 않으므로 영향 없다)
                    self?.uiState.favoriteActionMessage = "자주 가는 곳에 담지 못했어요 (중복이거나 10개를 넘었을 수 있어요)"
                }
            }
            self?.uiState.favoriteActionLoading = false
            await reload?.value
        }
    }

    /// 담은 곳을 다시 뺀다(DELETE .../favorite-places/{placeId}).
    ///
    /// 잘못 담은 장소를 취소할 길이 이것뿐이다 — 등록 상한이 10개이고 같은 이름은 재등록도 막히므로
    /// (409 `FAVORITE_PLACE_DUPLICATED`) 빼지 못하면 오타 난 이름이 10칸 중 하나를 영구히 차지한다.
    ///
    /// **404 를 성공으로 접지 않는다.** 서버가 「이미 지워졌다」·「없다」·「남의 것」을 같은 404 로
    /// 숨기므로, 성공으로 접으면 남의 행을 지우려는 시도까지 성공으로 보인다. 대신 실패 문구를 띄우고
    /// `loadFavorites` 로 목록을 다시 받아 ★ 상태를 서버와 맞춘다 — 그 404 는 화면이 들고 있던
    /// 목록이 낡았다는 신호이기도 하다.
    @discardableResult
    public func removeFavorite(id: Int64) -> Task<Void, Never>? {
        if uiState.favoriteActionLoading { return nil }
        let name = uiState.favorites.first { $0.id == id }?.name
        uiState.favoriteActionLoading = true
        let repository = self.repository
        return scope.launch { [weak self] in
            do {
                try await repository.deleteFavoritePlace(id: id)
                let label = name.map { "\($0)을(를) " } ?? ""
                self?.uiState.favoriteActionMessage = "\(label)자주 가는 곳에서 뺐어요"
            } catch {
                // 태스크 취소는 실패가 아니다 — 화면을 떠난 것이라 문구를 세울 자리가 없다(runSearch 와 같은 규칙).
                if !Task.isCancelled {
                    self?.uiState.favoriteActionMessage = Self.removeFailureMessage(error)
                }
            }
            // 성공이든 실패든 목록을 다시 받는다 — 실패가 「목록이 낡았다」는 뜻일 수 있다
            let reload = self?.loadFavorites()
            self?.uiState.favoriteActionLoading = false
            await reload?.value
        }
    }

    private static func removeFailureMessage(_ error: any Error) -> String {
        if (error as? FavoritePlaceException)?.isNotFound == true {
            return "이미 지워졌거나 없는 곳이에요"
        }
        return "자주 가는 곳에서 빼지 못했어요"
    }
}

// 15 목적지 — 장소 검색·즐겨찾기 서버 연동 진입점
public struct DestinationRoute: View {
    private let initialQuery: String // 14 홈에서 넘어온 검색어 (자주 가는 곳 · 최근 목적지 탭)
    private let onBack: () -> Void
    // (출발지, 도착지) — 출발지는 사용자가 고른 곳 또는 실위치. 둘 다 없으면 CTA 가 비활성이라 호출되지 않는다
    private let onConfirmRoute: (Place, Place) -> Void

    @HostedViewModel private var viewModel: DestinationViewModel

    // 여기서는 권한 다이얼로그를 띄우지 않는다 — 검색이 본체인 화면이라 진입하자마자 막아서면 방해가 된다.
    // 합승 탭(17)에서 이미 허용했으면 그 좌표가 그대로 출발지 기본값이 되고, 아니면 출발지가 비어
    // 사용자가 출발지를 검색해 채운다.
    // 지도가 없어 출발지 좌표 한 번이면 충분하다 — 지도용 1초 주기를 여기까지 끌고 오지 않는다
    @RememberMyLocationState(autoRequestPermission: false, updateIntervalMs: FormLocationIntervalMs)
    private var myLocation

    public init(
        repository: any PlaceRepository,
        initialQuery: String = "",
        onBack: @escaping () -> Void = {},
        onConfirmRoute: @escaping (Place, Place) -> Void = { _, _ in }
    ) {
        self.initialQuery = initialQuery
        self.onBack = onBack
        self.onConfirmRoute = onConfirmRoute
        _viewModel = HostedViewModel(wrappedValue: DestinationViewModel(repository: repository))
    }

    public var body: some View {
        let viewModel = self.viewModel
        let state = viewModel.uiState
        DestinationScreen(
            origin: state.origin?.name,
            originIsDefault: state.selectedOrigin == nil,
            originLatitude: state.origin?.latitude,
            originLongitude: state.origin?.longitude,
            originQuery: state.originQuery,
            activeField: state.activeField,
            onFieldFocus: { viewModel.focusField($0) },
            query: state.query,
            onQueryChange: { viewModel.onQueryChange($0) },
            searchResults: state.searchResults,
            searchLoading: state.searchLoading,
            searchErrorMessage: state.searchErrorMessage,
            favoritePlaces: state.favorites,
            favoritesLoading: state.favoritesLoading,
            favoritesErrorMessage: state.favoritesErrorMessage,
            selectedPlace: state.selectedPlace,
            favoriteActionMessage: state.favoriteActionMessage,
            favoriteActionLoading: state.favoriteActionLoading,
            onPlaceSelect: { viewModel.selectPlace($0) },
            onAddFavorite: { viewModel.addFavorite($0) },
            onRemoveFavorite: { viewModel.removeFavorite(id: $0) },
            onBack: onBack,
            onConfirmRoute: { destination in
                if let origin = state.origin { onConfirmRoute(origin, destination) }
            }
        )
        .myLocationEffect($myLocation)
        .task(id: initialQuery) {
            viewModel.applyInitialQuery(initialQuery)
        }
        .task(id: myLocation.coordinates) {
            viewModel.setCurrentLocation(myLocation.coordinates.map(currentLocationPlace))
        }
    }
}
