import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureHome

/// 14 홈의 즐겨찾기 **삭제가 어느 경로로 나가고 실패를 어떻게 다루는가** — `HomeViewModel` 과
/// Repository 사이만 본다.
///
/// data 쪽 `RemotePlaceRepositoryTest` 는 「404 를 올리는가/삼키는가」까지만 보고, 이 테스트는
/// 그 위를 본다 — **화면이 404 를 성공으로 접지 않는가**, **선택 1곳도 다건 경로로 가는가**,
/// 그리고 **목록이 비어 보일 때도 전체 삭제를 부르는가**. 그 셋이 이 묶음의 결함 지점이다.
///
/// 원본 `advanceUntilIdle()` 자리는 뷰모델이 돌려주는 태스크의 `.value` 를 기다리는 것이다.
@MainActor
@Suite struct FavoriteDeleteStateTest {

    /// 못 박는 것: 선택이 **1곳이어도 단건 삭제를 쓰지 않는다.**
    ///
    /// 서버가 전부-아니면-전무라(실측 2026-11-01, 로컬 `:8080`) 다건 경로는 「3개 중 1개만 지워진」
    /// 상태를 만들지 않는다. 선택 수에 따라 경로를 갈라 두면 2곳을 고른 사용자만 그 보장을 받는
    /// 꼴이 되고, 단건을 N번 돌리는 구현으로 되돌아가는 문턱도 낮아진다.
    @Test("선택이 한 곳이어도 다건 삭제 경로로 보낸다")
    func singleSelectionUsesBatchPath() async {
        let repository = FakePlaceRepository(favorites: [favorite(19), favorite(20)])
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value

        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))
        await viewModel.deleteSelectedFavorites()?.value

        #expect(await repository.batchDeletes == [[19]])
        #expect(await repository.singleDeletes == [], "선택 1곳을 단건 삭제로 보냈다")
    }

    /// 성공하면 편집 모드를 닫고 목록을 다시 받는다 — 낙관적 제거를 하지 않으므로 재조회가 필수다.
    @Test("다건 삭제가 성공하면 편집 모드를 닫고 목록을 다시 받는다")
    func batchSuccessClosesEditingAndReloads() async {
        let repository = FakePlaceRepository(favorites: [favorite(19)])
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        let loadsBefore = await repository.loadCalls
        await viewModel.deleteSelectedFavorites()?.value

        #expect(!viewModel.editState.editing, "성공인데 편집 모드가 남아 있다")
        #expect(viewModel.editState.selectedIds == [])
        #expect(viewModel.editState.errorMessage == nil)
        #expect(await repository.loadCalls == loadsBefore + 1)
    }

    /// 못 박는 것: **404 를 성공으로 접지 않는다.** 서버가 「이미 지워졌다」·「없다」·「남의 것」을
    /// 같은 404 `FAVORITE_PLACE_NOT_FOUND` 로 숨기므로(실측) 성공으로 접으면 남의 행을 지우려는
    /// 시도까지 성공으로 보인다. 대신 문구를 띄우고 **목록을 다시 받아** 서버와 맞춘다.
    ///
    /// 선택도 비운다 — 실패한 선택을 남기면 사라진 id 를 다시 보내 같은 404 를 반복한다.
    @Test("다건 삭제의 404 를 성공으로 접지 않고 목록을 다시 받는다")
    func batchNotFoundIsNotSuccess() async {
        let repository = FakePlaceRepository(favorites: [favorite(19)], batchDeleteError: notFound())
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        let loadsBefore = await repository.loadCalls
        await viewModel.deleteSelectedFavorites()?.value

        let state = viewModel.editState
        #expect(state.errorMessage == "이미 지워졌거나 없는 곳이에요. 목록을 다시 불러왔어요")
        #expect(state.editing, "실패인데 편집 모드가 닫혔다 — 다시 고를 자리가 없어진다")
        #expect(state.selectedIds == [])
        #expect(await repository.loadCalls == loadsBefore + 1, "실패했는데 목록을 다시 받지 않았다")
    }

    /// 404 가 아닌 실패는 사유를 가리지 않는다 — 사용자가 할 수 있는 일이 재시도뿐이다.
    @Test("404 가 아닌 실패는 일반 문구로 알린다")
    func otherFailureUsesGenericMessage() async {
        let repository = FakePlaceRepository(
            favorites: [favorite(19)],
            batchDeleteError: FavoritePlaceException(code: nil, serverMessage: nil, httpStatus: 500)
        )
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        await viewModel.deleteSelectedFavorites()?.value

        #expect(viewModel.editState.errorMessage == "즐겨찾기를 지우지 못했어요")
    }

    /// 빈 선택은 서버가 400 `INVALID_PLACE_IDS` 다 — 아예 부르지 않는다.
    @Test("아무것도 고르지 않으면 삭제를 부르지 않는다")
    func emptySelectionDoesNotCall() async {
        let repository = FakePlaceRepository(favorites: [favorite(19)])
        let viewModel = HomeViewModel(repository: repository)
        viewModel.toggleFavoriteEditing()

        await viewModel.deleteSelectedFavorites()?.value

        #expect(await repository.batchDeletes == [])
    }

    /// ★ **이 묶음에서 가장 중요한 테스트다.** 목록이 비어 보여도 전체 삭제는 서버까지 간다.
    ///
    /// `placeId` 나 좌표가 없는 레거시 행은 매퍼가 버려서 목록에 안 나오는데 서버에서는 10칸 중
    /// 하나를 계속 차지한다 — 고를 수 없으니 per-item 삭제로는 영영 닿지 못하고, 10칸이 그렇게
    /// 막히면 사용자는 새 장소를 담을 수도 자리를 비울 수도 없다(그 전까지 탈출구가 회원 탈퇴였다).
    /// 「목록이 비었으니 부를 필요 없다」는 최적화를 넣는 순간 그 탈출구가 사라진다.
    @Test("목록이 비어 보여도 전체 삭제는 서버를 부른다")
    func deleteAllCallsServerEvenWhenEmpty() async {
        let repository = FakePlaceRepository(favorites: [])
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()

        await viewModel.deleteAllFavorites()?.value

        #expect(await repository.allDeletes == 1)
        #expect(viewModel.editState.errorMessage == nil)
    }

    /// 편집 모드를 닫으면 선택이 비워진다. 안 비우면 다음에 열었을 때 사용자가 고르지도 않은 곳이
    /// 선택된 채 「선택한 N곳 삭제」가 활성된다 — 되돌릴 수 없는 삭제라 그 상태를 남겨선 안 된다.
    @Test("편집 모드를 닫으면 선택이 비워진다")
    func closingEditingClearsSelection() {
        let viewModel = HomeViewModel(repository: FakePlaceRepository(favorites: [favorite(19)]))
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))
        #expect(viewModel.editState.selectedIds == [19])

        viewModel.toggleFavoriteEditing()

        #expect(viewModel.editState.selectedIds == [])
        #expect(!viewModel.editState.editing)
    }

    /// 같은 행을 두 번 누르면 선택이 풀린다 — 체크박스의 기본 기대다.
    @Test("같은 즐겨찾기를 다시 누르면 선택이 풀린다")
    func secondTapDeselects() {
        let viewModel = HomeViewModel(repository: FakePlaceRepository(favorites: [favorite(19)]))
        viewModel.toggleFavoriteEditing()

        viewModel.toggleFavoriteSelection(favorite(19))
        viewModel.toggleFavoriteSelection(favorite(19))

        #expect(viewModel.editState.selectedIds == [])
    }

    /// ★ 못 박는 것: **조회 실패는 「등록한 곳이 없음」이 아니다.**
    ///
    /// 둘을 같게 두면 지하철에서 조회가 끊긴 사용자에게 화면이 「즐겨찾기를 등록하면…」을 보여 주고,
    /// 편집을 열면 「전체 삭제로 비울 수 있어요」까지 권한다. 통신이 돌아오는 순간
    /// `DELETE /favorite-places/all` 이 204 로 성공해 **서버의 멀쩡한 즐겨찾기가 전부 사라진다.**
    /// 되돌릴 수 없다. 그래서 `loaded` 가 「전체 삭제」를 그릴지의 유일한 근거다.
    @Test("조회에 실패하면 전체 삭제의 근거가 서지 않는다")
    func loadFailureDoesNotEnableDeleteAll() async {
        let repository = FakePlaceRepository(loadError: NetworkFailure())
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.refresh().value

        let state = viewModel.editState
        #expect(!state.loaded, "조회에 실패했는데 loaded 가 섰다 — 전체 삭제가 그려진다")
        #expect(state.loadFailed, "실패를 상태로 남기지 않으면 화면이 빈 목록과 구분할 수 없다")
    }

    /// 반대 경우 — 받아 왔고 결과가 비었으면 전체 삭제의 근거가 선다(레거시 행 탈출구).
    @Test("조회에 성공하면 결과가 비어도 전체 삭제의 근거가 선다")
    func emptyLoadSuccessEnablesDeleteAll() async {
        let repository = FakePlaceRepository(favorites: [])
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.refresh().value

        #expect(viewModel.editState.loaded)
        #expect(!viewModel.editState.loadFailed)
    }

    /// 못 박는 것: **조회가 실패해도 이미 보여 주던 목록을 비우지 않는다.**
    /// 비우면 사용자는 자기 즐겨찾기가 사라진 줄 안다.
    @Test("조회 실패가 이미 받아 둔 목록을 지우지 않는다")
    func loadFailureKeepsList() async {
        let repository = FakePlaceRepository(favorites: [favorite(19, name: "집")])
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        #expect(viewModel.favorites.count == 1)

        await repository.setFailNextLoad(true)
        await viewModel.refresh().value

        #expect(viewModel.favorites.count == 1, "실패가 목록을 비웠다")
        #expect(viewModel.editState.loadFailed)
    }

    /// 편집을 여닫는다고 조회의 사실(`loaded`)이 뒤집히면 「전체 삭제」가 사라진다.
    @Test("편집을 여닫아도 조회 성공 사실은 남는다")
    func togglingEditingKeepsLoaded() async {
        let viewModel = HomeViewModel(repository: FakePlaceRepository(favorites: []))
        await viewModel.refresh().value

        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteEditing()

        #expect(viewModel.editState.loaded)
    }

    // ─── 원본에 없는 iOS 전용 확인 ───

    /// 원본은 `Dispatchers.Main.immediate` 로 첫 대기 지점까지 곧바로 돌아 다음 탭 전에 `deleting` 이 선다.
    /// `Task` 는 다음 차례로 밀리므로 그 틈의 연타를 직접 막아야 한다(두 번째 요청은 404 다).
    @Test("삭제가 시작되면 곧바로 잠겨 연타가 두 번 나가지 않는다")
    func doubleTapSendsOnce() async {
        let repository = FakePlaceRepository(favorites: [favorite(19)])
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        let first = viewModel.deleteSelectedFavorites()
        #expect(viewModel.editState.deleting)
        let second = viewModel.deleteSelectedFavorites()
        #expect(second == nil)
        await first?.value

        #expect(await repository.batchDeletes == [[19]])
        #expect(!viewModel.editState.deleting)
    }

    /// 태스크가 정말 취소되면(뷰모델 해제) `URLSession` 은 `URLError(.cancelled)` 로 끝날 수 있다. 실패 문구로 읽히면
    /// 화면을 떠났을 뿐인데 「지우지 못했어요」가 서고, 이미 취소된 태스크에서 재조회가 돈다.
    @Test("태스크가 정말 취소된 삭제는 실패로 치지 않고 다시 받지도 않는다", arguments: [
        CancellationError() as any Error,
        URLError(.cancelled) as any Error,
    ])
    func cancelledDeleteIsNotFailure(error: any Error) async {
        let repository = FakePlaceRepository(favorites: [favorite(19)], batchDeleteError: error)
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        let loadsBefore = await repository.loadCalls
        let task = viewModel.deleteSelectedFavorites()
        task?.cancel()
        await task?.value

        #expect(viewModel.editState.errorMessage == nil)
        #expect(await repository.loadCalls == loadsBefore)
        #expect(!viewModel.editState.deleting, "취소 뒤에도 잠겨 있으면 손잡이를 다시 못 쓴다")
    }

    /// 원본은 OkHttp `IOException("Canceled")` 을 삭제 실패로 받아 재조회하고 문구를 세운다. 조용히 끝내면
    /// 아무것도 지워지지 않았는데 편집 화면이 아무 말도 하지 않는다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 삭제 실패다 — 문구를 세우고 다시 받고 선택을 남긴다")
    func liveUrlCancelledDeleteIsFailure() async {
        let repository = FakePlaceRepository(favorites: [favorite(19)], batchDeleteError: URLError(.cancelled))
        let viewModel = HomeViewModel(repository: repository)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        let loadsBefore = await repository.loadCalls
        await viewModel.deleteSelectedFavorites()?.value

        #expect(viewModel.editState.errorMessage != nil)
        #expect(await repository.loadCalls == loadsBefore + 1)
        #expect(viewModel.editState.selectedIds == [19], "서버가 전부-아니면-전무라 아무것도 지워지지 않았다")
        #expect(!viewModel.editState.deleting)
    }

    /// `loaded`·`loadFailed` 가 둘 다 거짓으로 남으면 빈 목록 안내도 재시도도 그릴 수 없어 멈춘 화면이 된다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 조회는 조회 실패로 남아 재시도를 그린다")
    func liveUrlCancelledLoadIsLoadFailure() async {
        let repository = FakePlaceRepository(loadError: URLError(.cancelled))
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.refresh().value

        #expect(viewModel.editState.loadFailed)
        #expect(!viewModel.editState.loaded)
    }

    /// 취소를 조회 실패로 남기면 빈 목록과 실패를 가르는 `loadFailed` 가 거짓이 된다.
    @Test("태스크가 정말 취소된 조회는 조회 실패로 남기지 않는다")
    func cancelledLoadIsNotLoadFailure() async {
        let repository = FakePlaceRepository(loadError: URLError(.cancelled))
        let viewModel = HomeViewModel(repository: repository)

        let task = viewModel.refresh()
        task.cancel()
        await task.value

        #expect(!viewModel.editState.loadFailed)
        #expect(!viewModel.editState.loaded)
    }

    /// 서버가 정렬해 준다고 믿지 않는다 — 원본도 받은 뒤 다시 sequence 로 정렬한다.
    @Test("목록은 sequence 순으로 정렬한다")
    func favoritesSortedBySequence() async {
        let repository = FakePlaceRepository(favorites: [favorite(5), favorite(1), favorite(2)])
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.refresh().value

        #expect(viewModel.favorites.map(\.id) == [1, 2, 5])
    }

    // ─── 뷰모델 해제 (원본 `viewModelScope` 취소 자리) ───

    /// 태스크가 호출 동안 뷰모델을 잡고 있으면 해제되지 않고, 해제가 없으면 스코프 취소도 돌지 않는다.
    @Test("조회 중에 뷰모델을 놓으면 해제되고 요청이 취소된다")
    func releasingDuringLoadCancels() async throws {
        let repository = HangingPlaceRepository(hangOnLoad: true)
        var viewModel: HomeViewModel? = HomeViewModel(repository: repository)
        weak let released = viewModel
        let task = try #require(viewModel?.refresh())
        await repository.waitUntilRequestStarted()

        viewModel = nil

        #expect(released == nil, "요청이 끝나기 전에는 뷰모델이 해제되지 않는다")
        await task.value
        #expect(await repository.cancelledRequests == 1)
    }

    /// 원본은 스코프가 취소되면 삭제 요청이 끊기고 재조회 GET 도 나가지 않는다.
    @Test("삭제 중에 뷰모델을 놓으면 요청이 취소되고 재조회가 나가지 않는다")
    func releasingDuringDeleteCancels() async throws {
        let repository = HangingPlaceRepository(favorites: [favorite(19)], hangOnDelete: true)
        var viewModel: HomeViewModel? = HomeViewModel(repository: repository)
        weak let released = viewModel
        await viewModel?.refresh().value
        viewModel?.toggleFavoriteEditing()
        viewModel?.toggleFavoriteSelection(favorite(19))
        let loadsBefore = await repository.loadCalls
        let task = try #require(viewModel?.deleteSelectedFavorites())
        await repository.waitUntilRequestStarted()

        viewModel = nil

        #expect(released == nil, "요청이 끝나기 전에는 뷰모델이 해제되지 않는다")
        await task.value
        #expect(await repository.cancelledRequests == 1)
        #expect(await repository.loadCalls == loadsBefore, "버려진 뷰모델을 위해 재조회가 나갔다")
    }

    /// 전체 삭제도 같은 경로로 끊긴다.
    @Test("전체 삭제 중에 뷰모델을 놓으면 요청이 취소되고 재조회가 나가지 않는다")
    func releasingDuringDeleteAllCancels() async throws {
        let repository = HangingPlaceRepository(favorites: [favorite(19)], hangOnDelete: true)
        var viewModel: HomeViewModel? = HomeViewModel(repository: repository)
        weak let released = viewModel
        await viewModel?.refresh().value
        let loadsBefore = await repository.loadCalls
        let task = try #require(viewModel?.deleteAllFavorites())
        await repository.waitUntilRequestStarted()

        viewModel = nil

        #expect(released == nil, "요청이 끝나기 전에는 뷰모델이 해제되지 않는다")
        await task.value
        #expect(await repository.cancelledRequests == 1)
        #expect(await repository.loadCalls == loadsBefore, "버려진 뷰모델을 위해 재조회가 나갔다")
    }

    /// 코루틴은 취소되면 재개 자리에서 예외를 던지지만 Swift 는 끝난 호출의 값을 그대로 돌려준다.
    /// 취소와 응답이 엇갈려도 원본처럼 재조회 GET 이 나가지 않아야 한다.
    @Test("취소된 뒤 도착한 삭제 응답은 재조회를 부르지 않는다", arguments: [false, true])
    func lateDeleteResponseDoesNotReload(fails: Bool) async throws {
        let repository = HangingPlaceRepository(favorites: [favorite(19)], ignoresCancellation: true)
        var viewModel: HomeViewModel? = HomeViewModel(repository: repository)
        await viewModel?.refresh().value
        viewModel?.toggleFavoriteEditing()
        viewModel?.toggleFavoriteSelection(favorite(19))
        let loadsBefore = await repository.loadCalls
        let task = try #require(viewModel?.deleteSelectedFavorites())
        await repository.waitUntilRequestStarted()

        viewModel = nil
        await repository.finishDelete(throwing: fails ? NetworkFailure() : nil)
        await task.value

        #expect(await repository.loadCalls == loadsBefore, "버려진 뷰모델을 위해 재조회가 나갔다")
    }

    // ─── 호스트가 든 뷰모델 (원본 백스택 엔트리의 `ViewModelStore` 자리) ───

    /// 원본은 홈 엔트리가 스택에 남아 탭을 다녀와도 뷰모델이 그대로다. 복귀 조회가 실패해도 받아 둔 목록을
    /// 지우지 않고, 편집 상태와 「전체 삭제」의 근거도 남는다.
    @Test("호스트가 든 뷰모델을 넘기면 탭 복귀 뒤에도 목록과 편집 상태가 남는다")
    func hostHeldViewModelKeepsStateAcrossRoutes() async {
        let repository = FakePlaceRepository(favorites: [favorite(19)])
        let viewModel = HomeViewModel(repository: repository)
        _ = HomeRoute(viewModel: viewModel)
        await viewModel.refresh().value
        viewModel.toggleFavoriteEditing()
        viewModel.toggleFavoriteSelection(favorite(19))

        // 탭을 갈아 끼우는 호스트에서 돌아온 경우 — 뷰는 새로 만들어지고 `.task` 가 다시 조회한다
        await repository.setFailNextLoad(true)
        _ = HomeRoute(viewModel: viewModel)
        await viewModel.refresh().value

        #expect(viewModel.favorites.map(\.id) == [19])
        #expect(viewModel.editState.editing)
        #expect(viewModel.editState.selectedIds == [19])
        #expect(viewModel.editState.loaded)
    }
}

private struct NetworkFailure: Error {}

/// 요청을 붙잡아 두는 저장소. 끝을 기다리는 동안 뷰모델을 놓아 볼 수 있다.
private actor HangingPlaceRepository: PlaceRepository {
    private let favorites: [FavoritePlace]
    private let hangOnLoad: Bool
    private let hangOnDelete: Bool
    /// 취소를 듣지 않고 `finishDelete` 를 기다린다 — 취소와 응답이 엇갈린 경우
    private let ignoresCancellation: Bool
    private var startedRequests = 0
    private var pendingDelete: CheckedContinuation<Void, any Error>?
    private(set) var cancelledRequests = 0
    private(set) var loadCalls = 0

    init(
        favorites: [FavoritePlace] = [],
        hangOnLoad: Bool = false,
        hangOnDelete: Bool = false,
        ignoresCancellation: Bool = false
    ) {
        self.favorites = favorites
        self.hangOnLoad = hangOnLoad
        self.hangOnDelete = hangOnDelete
        self.ignoresCancellation = ignoresCancellation
    }

    func waitUntilRequestStarted() async {
        while startedRequests == 0 && pendingDelete == nil {
            await Task.yield()
        }
    }

    func finishDelete(throwing error: (any Error)?) {
        if let error {
            pendingDelete?.resume(throwing: error)
        } else {
            pendingDelete?.resume()
        }
        pendingDelete = nil
    }

    // 뷰모델이 안 놓이면 이 대기가 끝나지 않으므로, 실패가 멈춤이 아니라 단언 실패로 드러나게 시간을 둔다.
    private func hang() async throws {
        startedRequests += 1
        do {
            try await Task.sleep(for: .seconds(3))
        } catch {
            cancelledRequests += 1
            throw error
        }
    }

    private func deleteRequest() async throws {
        if ignoresCancellation {
            try await withCheckedThrowingContinuation { pendingDelete = $0 }
        } else if hangOnDelete {
            try await hang()
        }
    }

    func searchPlaces(query: String) async throws -> [Place] { [] }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? { nil }

    func addFavoritePlace(place: Place) async throws {}

    func getFavoritePlaces() async throws -> [FavoritePlace] {
        loadCalls += 1
        if hangOnLoad { try await hang() }
        return favorites
    }

    func deleteFavoritePlace(id: Int64) async throws {}

    func deleteFavoritePlaces(ids: [Int64]) async throws {
        try await deleteRequest()
    }

    func deleteAllFavoritePlaces() async throws {
        try await deleteRequest()
    }
}

private func favorite(_ id: Int64) -> FavoritePlace {
    FavoritePlace(
        id: id,
        name: "장소\(id)",
        roadName: "서울 강남구 테헤란로 \(id)",
        latitude: 37.4979,
        longitude: 127.0276,
        sequence: Int(id)
    )
}

private func favorite(_ id: Int64, name: String) -> FavoritePlace {
    FavoritePlace(
        id: id,
        name: name,
        roadName: "도로명",
        latitude: 37.0,
        longitude: 127.0,
        sequence: Int(id)
    )
}

/// 실측 본문의 코드 그대로 — 없는 것·남의 것·두 번째 삭제가 모두 이것이다.
private func notFound() -> FavoritePlaceException {
    FavoritePlaceException(
        code: "FAVORITE_PLACE_NOT_FOUND",
        serverMessage: "등록되지 않은 즐겨찾기입니다.",
        httpStatus: 404
    )
}

private actor FakePlaceRepository: PlaceRepository {
    private let favorites: [FavoritePlace]
    private let batchDeleteError: (any Error)?
    private let singleDeleteError: (any Error)?
    private let allDeleteError: (any Error)?
    private let loadError: (any Error)?
    /// 두 번째 조회부터 실패시키고 싶을 때 — 「이미 받아 둔 목록을 지우지 않는다」를 보려면 필요하다
    private var failNextLoad = false
    private(set) var batchDeletes: [[Int64]] = []
    private(set) var singleDeletes: [Int64] = []
    private(set) var allDeletes = 0
    private(set) var loadCalls = 0

    init(
        favorites: [FavoritePlace] = [],
        batchDeleteError: (any Error)? = nil,
        singleDeleteError: (any Error)? = nil,
        allDeleteError: (any Error)? = nil,
        loadError: (any Error)? = nil
    ) {
        self.favorites = favorites
        self.batchDeleteError = batchDeleteError
        self.singleDeleteError = singleDeleteError
        self.allDeleteError = allDeleteError
        self.loadError = loadError
    }

    func setFailNextLoad(_ value: Bool) {
        failNextLoad = value
    }

    func searchPlaces(query: String) async throws -> [Place] { [] }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? { nil }

    func addFavoritePlace(place: Place) async throws {}

    func getFavoritePlaces() async throws -> [FavoritePlace] {
        loadCalls += 1
        if let loadError { throw loadError }
        if failNextLoad { throw NetworkFailure() }
        return favorites
    }

    func deleteFavoritePlace(id: Int64) async throws {
        singleDeletes.append(id)
        if let singleDeleteError { throw singleDeleteError }
    }

    func deleteFavoritePlaces(ids: [Int64]) async throws {
        batchDeletes.append(ids)
        if let batchDeleteError { throw batchDeleteError }
    }

    func deleteAllFavoritePlaces() async throws {
        allDeletes += 1
        if let allDeleteError { throw allDeleteError }
    }
}
