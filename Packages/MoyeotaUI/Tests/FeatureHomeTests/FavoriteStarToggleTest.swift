import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureHome

/// 15 목적지의 **★ 토글** — 「이미 담긴 곳인지」를 무엇으로 판정하고, 빼기가 어느 경로로 나가는지.
///
/// 담은 직후 취소할 길이 이 토글뿐이다: 등록 상한이 10개이고 같은 이름은 재등록도 막히므로
/// (409 `FAVORITE_PLACE_DUPLICATED`, 실측) 빼지 못하면 오타 난 이름이 10칸 중 하나를 영구히 차지한다.
@MainActor
@Suite struct FavoriteStarToggleTest {

    /// 담은 곳이면 그 id 가 나와야 한다 — 그 값이 없으면 ★ 를 눌러도 빼기를 부를 수 없다.
    @Test("이미 담은 곳이면 그 즐겨찾기 id 를 찾아낸다")
    func findsSavedId() {
        let saved = [favorite(19, "판교역"), favorite(20, "집")]

        #expect(saved.savedFavoriteIdFor(place("판교역")) == 19)
        #expect(saved.savedFavoriteIdFor(place("집")) == 20)
    }

    @Test("담지 않은 곳이면 nil 이다")
    func notSavedIsNil() {
        let saved = [favorite(19, "판교역")]

        #expect(saved.savedFavoriteIdFor(place("강남역")) == nil)
        #expect([FavoritePlace]().savedFavoriteIdFor(place("판교역")) == nil)
    }

    /// 못 박는 것: **좌표가 달라도 이름이 같으면 담긴 곳으로 본다.**
    ///
    /// 검색 응답의 좌표와 저장 당시 좌표가 같다는 보장이 없다(카카오 응답이 갱신되면 소수점이 흔들린다).
    /// 좌표로 대조하면 담아 둔 곳인데도 빈 ★ 로 보이고, 누르는 순간 서버가 409
    /// `FAVORITE_PLACE_DUPLICATED` 로 막아 「담지 못했어요」가 뜬다 — 사용자는 왜인지 알 수 없다.
    /// 서버가 같은 `placeName` 재등록을 막으므로 이름이 유저당 유일 키다(실측).
    @Test("좌표가 달라도 이름과 도로명이 같으면 담긴 곳으로 본다")
    func differentCoordinatesStillSaved() {
        let road = "경기 성남시 분당구 판교역로 160"
        let saved = [favorite(19, "판교역", roadName: road, latitude: 37.3947, longitude: 127.1112)]

        let fromSearch = Place(name: "판교역", roadName: road, latitude: 37.39470001, longitude: 127.11120009)

        #expect(saved.savedFavoriteIdFor(fromSearch) == 19)
    }

    /// 못 박는 것: **이름만 같은 다른 지점을 담긴 곳으로 보지 않는다.**
    ///
    /// 저장된 쪽은 이름이 유저당 유일하지만(서버가 409 로 막는다) **검색 결과 쪽은 그렇지 않다** —
    /// 같은 이름의 다른 지점이 여러 행으로 나온다. 이름만 대조하면 그 행들에 전부 채운 ★ 가 그려지고,
    /// 담은 적 없는 지점의 ★ 를 누른 사용자가 **확인도 없이 진짜 즐겨찾기를 잃는다.**
    /// ★ 가 「담기 전용」일 때는 없던 위험이고, 빼기가 붙으면서 생겼다.
    @Test("이름이 같아도 도로명이 다르면 담긴 곳이 아니다")
    func sameNameOtherBranchIsNotSaved() {
        let saved = [favorite(19, "스타벅스", roadName: "서울 강남구 테헤란로 152")]

        let otherBranch = Place(name: "스타벅스", roadName: "서울 강남구 역삼로 180", latitude: 37.495, longitude: 127.033)

        #expect(saved.savedFavoriteIdFor(otherBranch) == nil, "이름만 같은 다른 지점을 담긴 곳으로 보면 안 된다")
    }

    /// 못 박는 것: **저장된 도로명이 비어 있으면 이름만으로 되돌아간다.**
    ///
    /// 지번만 있는 건물·지하철역은 서버가 카카오의 `road_address_name` 을 그대로 흘려 빈 값이 온다.
    /// 그때까지 도로명을 요구하면 **그런 즐겨찾기는 영영 뺄 수 없다** — 가를 근거가 없는 경우라
    /// 이름 대조로 떨어뜨리는 쪽이 맞다.
    @Test("저장된 도로명이 비어 있으면 이름만으로 맞춘다")
    func blankSavedRoadFallsBackToName() {
        let saved = [favorite(19, "강남역", roadName: "")]

        let fromSearch = Place(name: "강남역", roadName: "서울 강남구 강남대로 396", latitude: 37.497, longitude: 127.027)

        #expect(saved.savedFavoriteIdFor(fromSearch) == 19)
    }

    /// 빼기는 단건 DELETE 다 — 다건 경로는 본문이 필요하고 여기서는 한 건이 확정돼 있다.
    @Test("담긴 곳의 별을 누르면 그 id 로 한 건 삭제를 부른다")
    func starDeletesSingleById() async {
        let repository = FakePlaceRepository(favorites: [favorite(19, "판교역")])
        let viewModel = DestinationViewModel(repository: repository)
        await viewModel.initialLoad?.value

        await viewModel.removeFavorite(id: 19)?.value

        #expect(await repository.singleDeletes == [19])
        #expect(viewModel.uiState.favoriteActionMessage == "판교역을(를) 자주 가는 곳에서 뺐어요")
    }

    /// 못 박는 것: **404 를 성공으로 접지 않고, 목록을 다시 받는다.**
    /// 서버가 「이미 지워졌다」·「없다」·「남의 것」을 같은 404 로 숨기므로 문구도 구분하지 않는다.
    @Test("빼기의 404 는 성공으로 접히지 않고 목록을 다시 받는다")
    func removeNotFoundIsNotSuccess() async {
        let repository = FakePlaceRepository(
            favorites: [favorite(19, "판교역")],
            singleDeleteError: FavoritePlaceException(
                code: "FAVORITE_PLACE_NOT_FOUND",
                serverMessage: "등록되지 않은 즐겨찾기입니다.",
                httpStatus: 404
            )
        )
        let viewModel = DestinationViewModel(repository: repository)
        await viewModel.initialLoad?.value
        let loadsBefore = await repository.loadCalls

        await viewModel.removeFavorite(id: 19)?.value

        #expect(viewModel.uiState.favoriteActionMessage == "이미 지워졌거나 없는 곳이에요")
        #expect(await repository.loadCalls == loadsBefore + 1, "실패했는데 목록을 다시 받지 않았다")
    }

    /// 원본은 OkHttp `IOException("Canceled")` 을 `catch (e: Exception)` 로 받아 문구를 세운다. 조용히 끝내면
    /// ★ 를 눌렀는데 지워지지도 않고 아무 말도 없는 화면이 된다.
    @Test("빼기가 살아 있는 태스크의 URLError(.cancelled) 로 끝나면 실패 문구를 세우고 목록을 다시 받는다")
    func removeLiveUrlCancelIsFailure() async {
        let repository = FakePlaceRepository(favorites: [favorite(19, "판교역")], singleDeleteError: URLError(.cancelled))
        let viewModel = DestinationViewModel(repository: repository)
        await viewModel.initialLoad?.value
        let loadsBefore = await repository.loadCalls

        await viewModel.removeFavorite(id: 19)?.value

        #expect(viewModel.uiState.favoriteActionMessage == "자주 가는 곳에서 빼지 못했어요")
        #expect(await repository.loadCalls == loadsBefore + 1)
        #expect(!viewModel.uiState.favoriteActionLoading)
    }
}

private func place(_ name: String) -> Place {
    Place(name: name, roadName: "도로명", latitude: 37.0, longitude: 127.0)
}

private func favorite(
    _ id: Int64,
    _ name: String,
    roadName: String = "도로명",
    latitude: Double = 37.0,
    longitude: Double = 127.0
) -> FavoritePlace {
    FavoritePlace(
        id: id,
        name: name,
        roadName: roadName,
        latitude: latitude,
        longitude: longitude,
        sequence: Int(id)
    )
}

private actor FakePlaceRepository: PlaceRepository {
    private let favorites: [FavoritePlace]
    private let singleDeleteError: (any Error)?
    private(set) var singleDeletes: [Int64] = []
    private(set) var loadCalls = 0

    init(favorites: [FavoritePlace] = [], singleDeleteError: (any Error)? = nil) {
        self.favorites = favorites
        self.singleDeleteError = singleDeleteError
    }

    func searchPlaces(query: String) async throws -> [Place] { [] }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? { nil }

    func addFavoritePlace(place: Place) async throws {}

    func getFavoritePlaces() async throws -> [FavoritePlace] {
        loadCalls += 1
        return favorites
    }

    func deleteFavoritePlace(id: Int64) async throws {
        singleDeletes.append(id)
        if let singleDeleteError { throw singleDeleteError }
    }

    func deleteFavoritePlaces(ids: [Int64]) async throws {}

    func deleteAllFavoritePlaces() async throws {}
}
