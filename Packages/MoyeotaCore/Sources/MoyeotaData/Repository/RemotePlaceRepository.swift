import MoyeotaDomain

public final class RemotePlaceRepository: PlaceRepository {
    private let api: any PlaceApi

    public init(api: any PlaceApi) {
        self.api = api
    }

    public func searchPlaces(query: String) async throws -> [Place] {
        try await api.searchPlaces(query: query).list.map { $0.toPlace() }
    }

    // 404 ADDRESS_NOT_FOUND → null 변환은 매퍼가 한다. 그 외 4xx/5xx 는 HttpException 으로 던져진다.
    public func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? {
        try await api.reverseGeocode(latitude: latitude, longitude: longitude).toReverseAddressOrNull()
    }

    public func addFavoritePlace(place: Place) async throws {
        try await api.addFavoritePlace(request: place.toFavoriteRequestDto())
    }

    /// 서버가 정렬을 보장한다는 언급이 없어(placeSequence 만 내려줌) 앱에서 순서를 확정한다
    /// — 정렬은 `toFavoritePlaces` 안에 있다.
    ///
    /// **식별자나 좌표가 없는 항목은 그 한 건만 버린다.** 서버가 등록 시 좌표를 막게 됐지만
    /// (400 `INVALID_COORDINATES`, 실측) DB 컬럼은 여전히 NULL 허용이라 검증 전 레거시 행이 남아
    /// 있을 수 있고, 한 행 때문에 목록 전체가 파싱에서 터지면 홈의 즐겨찾기가 조용히 비고
    /// 15 는 영구히 에러를 띄운다.
    ///
    /// 버린 행은 **서버에서 10칸 중 하나를 계속 차지한다** — 목록에 없으니 고를 수 없고,
    /// `deleteAllFavoritePlaces` 만이 그 행을 치운다.
    public func getFavoritePlaces() async throws -> [FavoritePlace] {
        try await api.getFavoritePlaces().toFavoritePlaces()
    }

    /// 404 를 삼키지 않는다 — 「이미 지워졌으니 성공」으로 접으면 **남의 id 를 지우려는 시도까지
    /// 성공으로 보인다**(서버가 없는 것과 남의 것을 같은 404 로 숨긴다). 실패로 올려 화면이 목록을
    /// 다시 받게 하는 쪽이 맞다.
    public func deleteFavoritePlace(id: Int64) async throws {
        try await favoritePlaceCall {
            try await api.deleteFavoritePlace(placeId: id)
        }
    }

    /// 빈 목록이면 **서버를 부르지 않는다** — 서버는 400 `INVALID_PLACE_IDS` 를 주고(실측),
    /// 그 에러가 화면에 「지우지 못했어요」로 서는데 사용자가 고른 것은 애초에 없다.
    /// 지울 것이 없다는 요청은 이미 원하는 상태이므로 성공으로 끝낸다.
    ///
    /// 전부-아니면-전무라(실측) 실패 시 일부만 지워진 상태는 생기지 않는다.
    public func deleteFavoritePlaces(ids: [Int64]) async throws {
        if ids.isEmpty { return }
        try await favoritePlaceCall { try await api.deleteFavoritePlaces(request: ids.toFavoriteDeleteRequestDto()) }
    }

    /// **이미 비어 있다는 404 만 삼킨다.** 부른 쪽이 원한 상태가 이미 참이라 실패가 아니다 —
    /// 그대로 올리면 사용자는 아무 일도 안 했는데 「지우지 못했어요」를 본다. 이 파일 위쪽의
    /// 「404 ADDRESS_NOT_FOUND → null」과 `RemoteActivePartyRepository` 의 「404/403 = 없음」이
    /// 같은 관례다.
    ///
    /// 「목록이 비었으면 아예 부르지 않는다」로 바꾸지 말 것 — 매퍼가 placeId·좌표 없는 행을 버리므로
    /// **목록이 비어 보여도 서버에는 행이 남아 있을 수 있고**, 전체 삭제가 그 행을 치우는 유일한
    /// 길이다(`getFavoritePlaces` 주석 참고).
    ///
    /// 404 판별을 상태 코드만으로 하는 이유: 이 경로의 404 는 `FAVORITE_PLACE_NOT_FOUND` 하나뿐이고
    /// (실측), 본문 모양에 기대면 `{code,message}` 가 아닌 응답에서 조용히 어긋난다
    /// (POST 로 부른 `/all` 의 405 가 Spring 기본 `{timestamp,status,error,path}` 다 — 실측).
    /// 500 은 그대로 올린다.
    public func deleteAllFavoritePlaces() async throws {
        do {
            try await api.deleteAllFavoritePlaces()
        } catch let error as HttpException {
            if error.code() != 404 { throw error.toFavoritePlaceException() }
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            throw error.toFavoritePlaceException()
        }
    }
}
