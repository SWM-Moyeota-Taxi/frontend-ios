// 경로 기준: origin/develop place/interfaces/PlaceSearchController.java, FavoritePlaceController.java
// 주의: backend/http/place.http 는 실제 컨트롤러와 완전히 다른 옛 경로(/api/places/favorites/...)라 신뢰하지 않는다.
// 즐겨찾기 두 엔드포인트는 @CurrentUser 로 전환됐다 — 소유자는 토큰이 정하고 userId 파라미터는 없다.
// **장소 검색·역지오코딩도 더 이상 공개가 아니다** — Security 가 전 경로를 인증 필수로 바꾸면서
// 무토큰 호출이 401 `USER005` 로 막힌다(실측). 즉 이 프로토콜 전체가 로그인 후에만 쓸 수 있다.
public protocol PlaceApi: Sendable {
    func searchPlaces(query: String) async throws -> PlaceSearchListResponse

    /// 좌표 → 주소. 주소가 없는 좌표(바다 등)는 404 ADDRESS_NOT_FOUND 로 내려오는데
    /// 이는 정상 유저 행동이라 예외가 아니라 null 로 다뤄야 해서 `Response` 로 받는다.
    /// 판별과 예외 전환은 PlaceMappers 의 `toReverseAddressOrNull()` 이 담당한다.
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> Response<AddressResponseDto>

    // 204 No Content. 소유자는 Bearer 토큰에서 나온다(@CurrentUser) — userId 쿼리 파라미터는 사라졌다.
    func addFavoritePlace(request: FavoritePlaceRequestDto) async throws

    func getFavoritePlaces() async throws -> FavoritePlaceListResponse

    /// 즐겨찾기 한 건 삭제. 204 No Content. 대상은 응답의 `placeId`
    /// (`FavoritePlaceListResponse.FavoritePlaceItem.placeId`).
    ///
    /// **멱등이 아니다.** 실측(2026-11-01, 로컬 `:8080`, `moyeota2`):
    /// - 내 id → 204
    /// - **같은 id 두 번째 → 404** `{"code":"FAVORITE_PLACE_NOT_FOUND","message":"등록되지 않은 즐겨찾기입니다."}`
    /// - 없는 id(999999)·남의 id → **같은 404 FAVORITE_PLACE_NOT_FOUND** (403 이 아니다 — 존재 은닉)
    /// - 숫자가 아닌 id → 400 `{"code":"INVALID_REQUEST","message":"placeId: 형식이 올바르지 않습니다."}`
    /// - 무토큰 → 401 `{"code":"USER005","message":"로그인이 필요합니다."}`
    ///
    /// 404 를 성공으로 접지 말 것 — 남의 id 를 지우려는 시도까지 성공으로 보이고, 화면은 서버와
    /// 어긋난 목록을 계속 들고 있게 된다. 판별·전환은 `toFavoritePlaceException` 이 한다.
    func deleteFavoritePlace(placeId: Int64) async throws

    /// 즐겨찾기 여러 건 삭제. 204 No Content. 본문 키는 `placeIds`
    /// (`FavoritePlaceDeleteRequestDto`).
    ///
    /// ### POST 인 이유 — 틀리면 405 가 아니라 **엉뚱한 엔드포인트의 400** 이 온다
    /// 서버가 `@PostMapping("/batch-delete")` 로 열어 뒀다. `UserApi.deleteAccount` 의
    /// `HTTP(method: .DELETE, hasBody: true)` 를 여기 복사하면 **조용히 다른 매핑으로 샌다** —
    /// 실측(2026-11-01, 로컬 `:8080`): `DELETE .../favorite-places/batch-delete` →
    /// 405 가 아니라 400 `{"code":"INVALID_REQUEST","message":"placeId: 형식이 올바르지 않습니다."}`.
    /// 위 `deleteFavoritePlace` 의 `{placeId}` 템플릿이 "batch-delete" 를 placeId 로 잡아 Long 변환에
    /// 실패한 것이다. 「메서드 미지원」처럼 보이지 않으니 디버깅이 엉뚱한 곳으로 간다 —
    /// `UserApi` 가 "deleteAccount 패턴을 복사하지 마라" 라고 경고해 둔 바로 그 함정이다.
    /// 동사 고정은 `AuthenticatedPathContractTest` 와 `PlaceApiDeleteTest` 가 함께 못 박는다.
    ///
    /// ### 전부-아니면-전무
    /// 실측: `{"placeIds":[19,999999]}` → 404 `FAVORITE_PLACE_NOT_FOUND` 이고 **19 도 그대로 남아 있었다.**
    /// `{"placeIds":[5,6,5]}` → 204(중복은 서버가 한 번만 센다), 내 id 1개만 → 204, `[]` → 400
    /// `INVALID_PLACE_IDS`. 그래서 빈 목록은 아예 보내지 않고
    /// (`RemotePlaceRepository.deleteFavoritePlaces`),
    /// 실패하면 화면이 **낙관적 제거를 하지 않고 목록을 재조회한다.**
    func deleteFavoritePlaces(request: FavoritePlaceDeleteRequestDto) async throws

    /// 즐겨찾기 전체 삭제. 204 No Content. 목록을 읽지 않고 서버 행을 전부 비운다.
    ///
    /// **매퍼가 버린 행을 치우는 유일한 길이다.** 좌표나 `placeId` 가 없는 레거시 행은 사용자 눈에
    /// 안 보이는데 서버에서는 10칸 중 하나를 차지하므로, 목록에서 고르는 삭제로는 영영 닿지 못한다
    /// (`FavoritePlaceListResponse.FavoritePlaceItem.latitude` 참고).
    ///
    /// 실측(2026-11-01, 로컬 `:8080`, `moyeota2`):
    /// - 1건 남은 상태 → 204, 직후 조회가 `{"places":[]}`
    /// - **이미 빈 상태 → 404** `FAVORITE_PLACE_NOT_FOUND` (멱등이 아니다)
    /// - POST 로 호출 → 405 인데 본문이 `{code,message}` 가 **아니라** Spring 기본
    ///   `{timestamp,status,error,path}` 다 — 에러 코드 파싱 실패를 예외로 번지게 하지 말 것
    /// - 무토큰 → 401 `USER005`
    ///
    /// `/all` 리터럴이 `{placeId}` 템플릿을 이기므로 형제 경로로 둬도 안전하다(실측 204).
    /// placeId 가 Long 이라 "all" 이 그쪽으로 흘러들 수도 없다.
    /// 「이미 비어 있다」는 404 는 부른 쪽이 원한 상태가 이미 참이므로 리포지토리가 삼킨다.
    func deleteAllFavoritePlaces() async throws
}

enum PlaceApiRoute: String, CaseIterable, ApiRouteSet {
    case searchPlaces, reverseGeocode, addFavoritePlace, getFavoritePlaces
    case deleteFavoritePlace, deleteFavoritePlaces, deleteAllFavoritePlaces

    var route: ApiRoute {
        switch self {
        case .searchPlaces: .GET("api/v1/places", query: ["query"])
        case .reverseGeocode: .GET("api/v1/places/reverse", query: ["latitude", "longitude"])
        case .addFavoritePlace: .POST("api/v1/users/me/favorite-places")
        case .getFavoritePlaces: .GET("api/v1/users/me/favorite-places")
        case .deleteFavoritePlace: .DELETE("api/v1/users/me/favorite-places/{placeId}")
        case .deleteFavoritePlaces: .POST("api/v1/users/me/favorite-places/batch-delete")
        case .deleteAllFavoritePlaces: .DELETE("api/v1/users/me/favorite-places/all")
        }
    }
}

struct RestPlaceApi: PlaceApi {
    let rest: RestClient

    func searchPlaces(query: String) async throws -> PlaceSearchListResponse {
        try await rest.call(PlaceApiRoute.searchPlaces.route, query: ["query": query])
    }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> Response<AddressResponseDto> {
        try await rest.response(
            PlaceApiRoute.reverseGeocode.route,
            query: ["latitude": queryValue(latitude), "longitude": queryValue(longitude)]
        )
    }

    func addFavoritePlace(request: FavoritePlaceRequestDto) async throws {
        try await rest.callUnit(PlaceApiRoute.addFavoritePlace.route, body: request)
    }

    func getFavoritePlaces() async throws -> FavoritePlaceListResponse {
        try await rest.call(PlaceApiRoute.getFavoritePlaces.route)
    }

    func deleteFavoritePlace(placeId: Int64) async throws {
        try await rest.callUnit(PlaceApiRoute.deleteFavoritePlace.route, path: ["placeId": placeId])
    }

    func deleteFavoritePlaces(request: FavoritePlaceDeleteRequestDto) async throws {
        try await rest.callUnit(PlaceApiRoute.deleteFavoritePlaces.route, body: request)
    }

    func deleteAllFavoritePlaces() async throws {
        try await rest.callUnit(PlaceApiRoute.deleteAllFavoritePlaces.route)
    }
}
