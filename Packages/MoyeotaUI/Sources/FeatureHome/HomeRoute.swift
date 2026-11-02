import MoyeotaDesignSystem
import MoyeotaDomain
import PresentationCore
import SwiftUI

@MainActor
@Observable
public final class HomeViewModel {

    /// 즐겨찾기 편집 상태. 목록과 분리해 둔 이유: 목록은 진입마다 서버에서 다시 받는 값이고
    /// 이쪽은 사용자가 화면에서 만든 값이다 — 한 덩어리로 묶으면 재조회가 선택을 밀어낸다.
    public struct FavoriteEditState: Equatable, Sendable {
        public var editing: Bool
        /// 고른 `FavoritePlace.id` 들. 서버 placeId 라 세션이 바뀌면 의미가 없다(편집 모드를 닫으면 비운다)
        public var selectedIds: Set<Int64>
        /// 삭제 요청이 날아간 동안 true — 화면이 손잡이를 잠근다
        public var deleting: Bool
        public var errorMessage: String?
        /// **조회가 한 번이라도 성공했는가.** 「전체 삭제」를 그릴지의 유일한 근거다.
        ///
        /// 이게 없으면 조회 실패와 「등록한 곳이 없음」이 **화면에서 똑같아진다.** 그 상태로 편집을 열면
        /// 앱이 「목록에 안 보이는 장소가 서버에 남아 있을 수 있어요」라며 전체 삭제를 권하는데,
        /// 실제로는 서버에 멀쩡한 즐겨찾기가 있고 **통신이 돌아오는 순간 그게 전부 지워진다.**
        /// 되돌릴 수 없다. 레거시 행 탈출구라는 명분은 「목록을 받아 왔고 그 결과가 비었다」일 때만 선다.
        public var loaded: Bool
        /// 조회가 실패해 목록을 못 받았다. 빈 목록과 **다르게** 그려야 한다
        public var loadFailed: Bool

        public init(
            editing: Bool = false,
            selectedIds: Set<Int64> = [],
            deleting: Bool = false,
            errorMessage: String? = nil,
            loaded: Bool = false,
            loadFailed: Bool = false
        ) {
            self.editing = editing
            self.selectedIds = selectedIds
            self.deleting = deleting
            self.errorMessage = errorMessage
            self.loaded = loaded
            self.loadFailed = loadFailed
        }
    }

    // 홈의 「즐겨찾기」 목록은 부가 정보라 실패해도 화면 전체를 막지 않는다. 다만 실패를 **빈 목록으로
    // 보이게 두지는 않는다** — 그 둘을 섞으면 파괴적 동작(전체 삭제)의 근거가 거짓이 된다.
    public private(set) var favorites: [FavoritePlace] = []
    public private(set) var editState = FavoriteEditState()

    private let repository: any PlaceRepository
    private let scope = ViewModelScope()

    public init(repository: any PlaceRepository) {
        self.repository = repository
    }

    // 이 뷰모델의 태스크는 호출 동안 뷰모델을 붙잡지 않는다. `self?.` 로 `async` 메서드를 부르면 호출이 끝날 때까지
    // 강한 참조가 남아 해제도 스코프 취소도 일어나지 않는다. 그래서 요청은 `repository` 만 들고 나가 끝난 뒤 `self?` 로 쓴다.
    // 그래야 원본 `viewModelScope` 처럼 뷰모델이 해제될 때 진행 중인 조회·삭제가 끊긴다.
    //
    // 돌려주는 태스크는 테스트가 끝을 기다리는 용도다(원본 `advanceUntilIdle` 자리). 화면은 쓰지 않는다.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        let repository = self.repository
        return scope.launch { [weak self] in
            do {
                let places = try await HomeViewModel.fetchFavorites(from: repository)
                self?.applyFavorites(places)
            } catch {
                // 여기까지 올라오는 오류는 취소뿐이다 — 조회의 사실이 생긴 것이 없어 쓸 값이 없다.
            }
        }
    }

    /// 조회 실패 뒤 사용자가 「다시 시도」를 눌렀을 때. `refresh` 와 같은 일이지만 의도가 다르다.
    @discardableResult
    public func retryFavorites() -> Task<Void, Never> {
        refresh()
    }

    /// 즐겨찾기 조회 한 번. 받은 목록을 돌려주고, 실패하면 보고한 뒤 nil 을 돌려준다. 태스크가 정말 취소됐을 때만 던진다.
    private static func fetchFavorites(from repository: any PlaceRepository) async throws -> [FavoritePlace]? {
        // 즐겨찾기 주체는 Bearer 토큰이 정한다 — userId 를 넘기지 않는다 (22 보고서 §2)
        do {
            let places = try await repository.getFavoritePlaces()
            return places.sorted { $0.sequence < $1.sequence }
        } catch {
            // 화면은 그대로 두고 **보고만** 한다. 지하철 끊김은 `Diagnostics` 가 걸러 내고,
            // 파싱 실패나 5xx 처럼 우리가 고쳐야 하는 것만 올라간다.
            if Task.isCancelled { throw error }
            // `report` 는 `URLError(.cancelled)` 를 되던진다. 살아 있는 태스크에서 그 값은 원본 `IOException` 이라 실패로 남긴다 —
            // 던지게 두면 `loaded`·`loadFailed` 가 둘 다 거짓으로 남아 빈 목록 안내도 재시도도 그리지 못한다.
            try? Diagnostics.report(site: .favoritePlaces, throwable: error)
            return nil
        }
    }

    private func applyFavorites(_ places: [FavoritePlace]?) {
        guard let places else {
            // 실패했으면 **이미 보여 주던 목록을 비우지 않는다** — 지하철에서 한 번 끊겼다고 화면이
            // 「등록한 곳이 없어요」로 바뀌면 사용자는 자기 즐겨찾기가 사라진 줄 안다.
            editState.loadFailed = true
            return
        }
        favorites = places
        editState.loaded = true
        editState.loadFailed = false
    }

    /// 편집 모드를 열고 닫는다. 닫을 때 선택과 실패 문구를 함께 비운다 — 남겨 두면 다음에 열었을 때
    /// 사용자가 고르지도 않은 곳이 선택된 채로 「선택한 N곳 삭제」가 활성된다.
    public func toggleFavoriteEditing() {
        if editState.deleting { return }
        // `loaded`·`loadFailed` 는 조회의 사실이라 편집을 여닫는다고 바뀌지 않는다 —
        // 통째로 새 값을 만들면 `loaded` 가 false 로 돌아가 「전체 삭제」가 사라진다.
        editState.editing.toggle()
        editState.selectedIds = []
        editState.errorMessage = nil
    }

    public func toggleFavoriteSelection(_ place: FavoritePlace) {
        if editState.selectedIds.contains(place.id) {
            editState.selectedIds.remove(place.id)
        } else {
            editState.selectedIds.insert(place.id)
        }
        editState.errorMessage = nil
    }

    /// 고른 곳들을 **한 요청으로** 지운다(POST .../favorite-places/batch-delete).
    ///
    /// 단건 삭제를 선택 수만큼 돌리지 않는 이유: 서버가 전부-아니면-전무라 다건 경로는
    /// 「일부만 지워진」 상태를 만들지 않는다. 단건을 N번 돌리면 중간 404 에서 앞 몇 건만 지워져
    /// 화면과 서버가 어긋난다. 선택이 1개여도 같은 경로로 보낸다(서버가 204 로 받는다).
    ///
    /// 빈 선택은 호출하지 않는다 — 서버가 400 `INVALID_PLACE_IDS` 를 준다.
    @discardableResult
    public func deleteSelectedFavorites() -> Task<Void, Never>? {
        let ids = editState.selectedIds
        if ids.isEmpty || editState.deleting { return nil }
        let repository = self.repository
        return launchDelete { try await repository.deleteFavoritePlaces(ids: Array(ids)) }
    }

    /// 서버 목록을 통째로 비운다(DELETE .../favorite-places/all).
    ///
    /// **목록이 비어 보일 때도 부른다.** placeId·좌표가 없는 레거시 행은 매퍼가 버려서 화면에
    /// 안 나오는데 서버에서는 10칸 중 하나를 차지한다 — 고를 수 없으니 이 경로가 유일한 탈출구다.
    /// 「이미 비어 있다」는 404 는 리포지토리가 삼키므로 그때도 실패 문구가 서지 않는다.
    @discardableResult
    public func deleteAllFavorites() -> Task<Void, Never>? {
        if editState.deleting { return nil }
        let repository = self.repository
        return launchDelete { try await repository.deleteAllFavoritePlaces() }
    }

    /// 삭제 한 번과 그 뒷정리. **성공이든 실패든 목록을 다시 받는다** — 서버가 전부-아니면-전무라
    /// 실패했을 때 「일부는 지워졌겠지」로 낙관적 제거를 하면 어긋나고, 404 는 「이미 지워졌거나
    /// 남의 것」이라 화면이 들고 있던 목록 자체가 낡았다는 뜻이다.
    ///
    /// 선택은 **404 일 때만** 비운다. 서버가 전부-아니면-전무라 네트워크 실패는 아무것도 지우지
    /// 않았다는 뜻이고, 그때까지 체크를 날리면 사용자가 처음부터 다시 고른다. 반대로 404 는
    /// 「그 id 가 이제 없다」라 그대로 두면 같은 404 를 반복한다.
    private func launchDelete(_ request: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        // 태스크 안이 아니라 여기서 바로 잠근다. 원본의 `Dispatchers.Main.immediate` 는 첫 대기 지점까지 곧바로
        // 실행돼 다음 탭이 오기 전에 `deleting` 이 서는데, `Task` 는 다음 차례로 밀려 그 틈에 연타가 들어온다.
        // 삭제는 멱등이 아니라(두 번째가 404) 그 연타가 「지우지 못했어요」로 보인다.
        editState.deleting = true
        editState.errorMessage = nil
        let repository = self.repository
        return scope.launch { [weak self] in
            do {
                let failure = try await HomeViewModel.attemptDelete(request)
                let places = try await HomeViewModel.fetchFavorites(from: repository)
                self?.finishDelete(failure: failure, places: places)
            } catch {
                // 여기로 오는 것은 태스크 취소뿐이다(뷰모델이 죽을 때). 그래도 잠금은 남기지 않는다.
                self?.editState.deleting = false
            }
        }
    }

    /// 삭제 요청을 보내고 실패를 값으로 돌려준다(성공이면 nil).
    ///
    /// 태스크 취소만 그대로 던진다. **취소는 실패가 아니라 화면을 떠난 것**이고, 통째로 삼키면 그 뒤 재조회가
    /// 이미 취소된 태스크에서 돈다. 살아 있는 태스크의 `URLError(.cancelled)` 는 원본 `IOException` 이라 실패로 돌려준다. 코루틴은 취소되면 재개 자리에서 예외를 던지지만 Swift 는 끝난 호출의 결과를
    /// 그대로 돌려주므로, 취소와 응답이 엇갈린 경우에도 원본처럼 재조회가 나가지 않게 여기서 끊는다.
    private static func attemptDelete(_ request: @Sendable () async throws -> Void) async throws -> (any Error)? {
        var failure: (any Error)?
        do {
            try await request()
        } catch {
            if Task.isCancelled { throw error }
            failure = error
        }
        try Task.checkCancellation()
        return failure
    }

    private func finishDelete(failure: (any Error)?, places: [FavoritePlace]?) {
        applyFavorites(places)
        let notFound = (failure as? FavoritePlaceException)?.isNotFound == true
        // 성공하면 편집 모드를 닫고, 실패하면 열어 둔다(다시 고를 수 있어야 한다)
        editState.editing = failure != nil
        if failure == nil || notFound { editState.selectedIds = [] }
        editState.deleting = false
        editState.errorMessage = failure.map(HomeViewModel.deleteFailureMessage)
    }

    /// 404 를 성공으로 접지 않으므로 그 자리에 쓸 문구가 필요하다. 서버가 「없는 것」과 「남의 것」을
    /// 같은 404 로 숨기니 둘을 구분하지 않고, 방금 목록을 다시 받았다는 것까지 알린다.
    private static func deleteFailureMessage(_ error: any Error) -> String {
        if (error as? FavoritePlaceException)?.isNotFound == true {
            return "이미 지워졌거나 없는 곳이에요. 목록을 다시 불러왔어요"
        }
        return "즐겨찾기를 지우지 못했어요"
    }
}

/// 즐겨찾기 행을 눌렀을 때 15 에 넣을 검색어.
///
/// 도로명이 없는 장소가 있다 — 서버가 카카오의 road_address_name 을 그대로 흘리고,
/// 지번만 있는 건물·지하철역에서 그 값이 빈다(매퍼가 null 을 "" 로 떨군다).
/// 빈 값을 그대로 넘기면 **빈 검색어로 15 가 열려** 아무것도 안 뜬다. 이름으로 되돌린다.
func favoritePlaceQuery(_ place: FavoritePlace) -> String {
    place.roadName.isBlank ? place.name : place.roadName
}

// 14 홈 — 즐겨찾기 목록을 서버에서 채운다(domain FavoritePlace 그대로, sequence 순).
public struct HomeRoute: View {
    // 이름은 NavHost 의 공용 홀더(UserProfileViewModel)가 세션당 한 번 받아 내려보낸다
    // — 홈 진입마다 다시 조회하지 않는다.
    private let userName: String?
    /// 지금 진행 중인 내 방(ActivePartyViewModel.resolve 결과). 있으면 지도 위에 복귀 배너를 띄운다
    private let activeRide: Ride?
    private let onSearchClick: () -> Void
    private let onActiveRideClick: () -> Void
    private let onPlaceQuery: (String) -> Void
    private let onTabSelect: (MoyeotaTab) -> Void

    @HostedViewModel private var viewModel: HomeViewModel

    // 홈은 배경이 통째로 지도인 화면이라 내 위치가 있어야 지도가 쓸모 있다 — 합승 탭(17~19)과 같이
    // 권한을 요청한다. 거부하면 파란 점 없이 기본 카메라(부산)로 남고 화면은 그대로 동작한다.
    @RememberMyLocationState private var myLocation

    public init(
        repository: any PlaceRepository,
        userName: String? = nil,
        activeRide: Ride? = nil,
        onSearchClick: @escaping () -> Void = {},
        onActiveRideClick: @escaping () -> Void = {},
        onPlaceQuery: @escaping (String) -> Void = { _ in },
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in }
    ) {
        self.userName = userName
        self.activeRide = activeRide
        self.onSearchClick = onSearchClick
        self.onActiveRideClick = onActiveRideClick
        self.onPlaceQuery = onPlaceQuery
        self.onTabSelect = onTabSelect
        _viewModel = HostedViewModel(wrappedValue: HomeViewModel(repository: repository))
    }

    /// 호스트가 뷰모델을 들고 있는 경로 — 원본 `viewModel(factory = …)` 이 돌려주는 **백스택 엔트리의 뷰모델** 자리.
    ///
    /// 원본은 탭으로 나가도 홈 엔트리가 스택에 남아 뷰모델이 그대로다. 그 전제 위에서 복귀 재조회가 실패해도 받아
    /// 둔 목록을 지우지 않고, 편집 모드·고른 항목·「전체 삭제」의 근거(`loaded`)가 남는다. 탭을 `switch` 로 갈아
    /// 끼우는 호스트는 뷰가 없어지므로, 위의 `init(repository:…)` 를 쓰면 복귀할 때마다 이 값이 모두 사라진다.
    /// 그런 호스트는 탭 바깥에서 `HomeViewModel` 을 하나 들고 여기로 넘기고, 로그아웃 때 버린다.
    /// `TabView` 나 스택 루트처럼 뷰를 살려 두는 호스트는 `init(repository:…)` 로 충분하다.
    ///
    /// 뷰 수명 동안 처음 받은 인스턴스를 쓴다.
    public init(
        viewModel: HomeViewModel,
        userName: String? = nil,
        activeRide: Ride? = nil,
        onSearchClick: @escaping () -> Void = {},
        onActiveRideClick: @escaping () -> Void = {},
        onPlaceQuery: @escaping (String) -> Void = { _ in },
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in }
    ) {
        self.userName = userName
        self.activeRide = activeRide
        self.onSearchClick = onSearchClick
        self.onActiveRideClick = onActiveRideClick
        self.onPlaceQuery = onPlaceQuery
        self.onTabSelect = onTabSelect
        _viewModel = HostedViewModel(wrappedValue: viewModel)
    }

    public var body: some View {
        let viewModel = self.viewModel
        let editState = viewModel.editState
        HomeScreen(
            userName: userName,
            activeRide: activeRide,
            myLocation: myLocation.coordinates,
            favoritePlaces: viewModel.favorites,
            editingFavorites: editState.editing,
            selectedFavoriteIds: editState.selectedIds,
            deletingFavorites: editState.deleting,
            favoriteErrorMessage: editState.errorMessage,
            favoritesLoaded: editState.loaded,
            favoritesLoadFailed: editState.loadFailed,
            onRetryFavorites: { viewModel.retryFavorites() },
            onSearchClick: onSearchClick,
            onActiveRideClick: onActiveRideClick,
            onFavoritePlaceClick: { onPlaceQuery(favoritePlaceQuery($0)) },
            onEditFavoritesToggle: { viewModel.toggleFavoriteEditing() },
            onFavoriteSelectToggle: { viewModel.toggleFavoriteSelection($0) },
            onDeleteSelected: { viewModel.deleteSelectedFavorites() },
            onDeleteAll: { viewModel.deleteAllFavorites() },
            onTabSelect: onTabSelect
        )
        .myLocationEffect($myLocation)
        // 15 에서 즐겨찾기를 등록하고 돌아오면 반영돼야 해서 진입마다 재조회한다
        .task { viewModel.refresh() }
    }
}
