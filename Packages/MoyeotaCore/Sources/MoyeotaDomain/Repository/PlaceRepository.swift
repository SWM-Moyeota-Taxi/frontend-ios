public protocol PlaceRepository: Sendable {
    /// GET /api/v1/places?query=. 카카오 로컬 검색 프록시라 결과가 0건일 수 있다.
    func searchPlaces(query: String) async throws -> [Place]

    /// GET /api/v1/places/reverse?latitude=&longitude=. 지도 핀 위치의 주소를 얻는다.
    ///
    /// 주소가 없는 좌표(바다·비무장지대 등)면 **예외가 아니라 null** 이다.
    /// 핀을 아무 데나 찍는 건 정상 유저 행동이라 에러 화면을 띄울 일이 아니다 —
    /// 호출측은 null 이면 주소 표시 갱신만 생략하고 직전 값을 유지한다.
    ///
    /// 그 외 실패는 기존 컨벤션대로 예외:
    /// - 400 INVALID_COORDINATES: 한국 영역(위 33~39, 경 124~132) 밖 좌표
    /// - 502 REVERSE_GEOCODE_FAILED: 네이버 역지오코딩 호출 실패
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress?

    /// POST /api/v1/users/me/favorite-places. 응답 본문 없음(204).
    /// 소유자는 로그인 토큰이 정한다(@CurrentUser) — userId 를 넘기지 않는다.
    ///
    /// 실패: 401 `UNAUTHORIZED`(미로그인) / 409 `CONFLICT`(같은 이름 중복 · 10개 초과).
    /// 성공 후 `getFavoritePlaces` 재조회 필요.
    ///
    /// **예전에 적혀 있던 「항상 500」은 이제 틀린 말이다.** 서버가 `FavoritePlaceId` 무인자 생성자를
    /// 추가해 고쳤고(Backend #231), 뒤이어 그 복합키 클래스 자체를 지우고 단일키 `place_id` 로 바꿨다
    /// (`8f54ad4`). 원인 클래스가 없어 재발하지 않는다. 운영 반영도 끝났다(2026-10-23 `/v3/api-docs` 실측).
    ///
    /// **「성공 경로가 실기에서 한 번도 돈 적이 없다」도 이제 틀린 말이다** — 실측(2026-11-01,
    /// 로컬 `:8080`, `moyeota2`)으로 등록 204 → 조회 반영까지 밟았다. 좌표 검증도 함께 확인했다:
    /// 좌표 키 누락·서비스지역 밖(10.0, 10.0) 모두 400 `INVALID_COORDINATES` 다.
    func addFavoritePlace(place: Place) async throws

    /// GET /api/v1/users/me/favorite-places. 토큰 주체의 목록. sequence 오름차순 정렬해서 돌려준다.
    func getFavoritePlaces() async throws -> [FavoritePlace]

    /// DELETE /api/v1/users/me/favorite-places/{id}. 한 건 삭제, 204 No Content.
    /// `id` 는 `FavoritePlace.id` — 목록에서 받은 값이어야 한다.
    ///
    /// **멱등이 아니다.** 404 `FAVORITE_PLACE_NOT_FOUND` = 없는 것이거나 **남의 것**이고,
    /// 서버는 둘을 구분해 주지 않는다(존재 은닉. 403 이 아니다). 두 번 지우면 두 번째가 404 다.
    /// 실패는 `FavoritePlaceException` 으로 올라오고(`isNotFound` 로 분기), 호출측은 404 를
    /// 성공으로 접지 말고 **목록을 재조회해** 서버와 다시 맞춰야 한다.
    func deleteFavoritePlace(id: Int64) async throws

    /// POST /api/v1/users/me/favorite-places/batch-delete. 여러 건 삭제, 204 No Content.
    ///
    /// **전부-아니면-전무다.** `ids` 에 하나라도 내 것이 아닌 id 가 섞이면 404 이고 **아무것도
    /// 지워지지 않는다**(실측(2026-11-01, 로컬 `:8080`): `[19, 999999]` → 404, 19 도 그대로 남았다).
    /// 그래서 화면은 「일부는 지워졌겠지」로 낙관적 제거를 하면 안 되고, 실패하면 재조회해야 한다.
    /// 다중 선택에 이 경로를 쓰는 이유도 같다 — 단건 삭제를 N번 돌리면 중간 404 에서 **일부만 지워진**
    /// 어중간한 상태가 남는다. id 1개여도 이 경로가 204 다(실측).
    ///
    /// 중복 id 는 서버가 한 번만 센다. 빈 목록은 400 `INVALID_PLACE_IDS` 라 **구현이 서버를 부르지
    /// 않는다.** 서버 메시지의 「1개 이상 100개 이하」는 **강제되지 않지만**(`@Size`·`@Valid` 없음.
    /// 실측: 101개·5000개 통과) 등록 상한이 10개라 실제 배치는 최대 10개다.
    func deleteFavoritePlaces(ids: [Int64]) async throws

    /// DELETE /api/v1/users/me/favorite-places/all. 전체 삭제, 204 No Content.
    ///
    /// **목록을 읽지 않고 서버 행을 비우는 유일한 길이다.** `placeId` 나 좌표가 없는 레거시 행은
    /// 매퍼가 버려서 `getFavoritePlaces` 에 안 나오는데 서버에서는 10칸 중 하나를 계속 차지한다 —
    /// 목록에서 고를 수 없으니 `deleteFavoritePlace` 로는 영영 닿지 못한다. 10칸이 그렇게 막히면
    /// 사용자는 새 장소를 담을 수도, 자리를 비울 수도 없다(그 전까지 탈출구가 회원 탈퇴였다).
    /// 그래서 「목록이 비었으니 부르지 마라」로 막아서는 안 된다.
    ///
    /// 서버는 **이미 비어 있으면 404** 를 준다(멱등이 아니다). 구현이 그 404 만 삼킨다 —
    /// 부른 쪽이 원한 상태가 이미 참이기 때문이다. 그 외 실패는 `FavoritePlaceException` 으로 올라온다.
    func deleteAllFavoritePlaces() async throws
}
