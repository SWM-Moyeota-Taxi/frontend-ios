import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 즐겨찾기 **삭제 3종의 실패 처리**를 못 박는다. 세 경로 모두 멱등이 아니라서(실측 2026-11-01,
/// 로컬 `:8080`) 「404 를 어떻게 다루는가」가 이 저장소의 유일한 판단이고, 그 판단이 두 갈래다:
///
/// - 단건·다건의 404 → **올린다.** 서버가 「없는 것」과 「남의 것」을 같은 404 로 숨기므로
///   성공으로 접으면 남의 행을 지우려는 시도까지 성공으로 보이고, 화면은 서버와 어긋난 목록을 든다.
/// - `/all` 의 404 → **삼킨다.** 「이미 비어 있다」는 부른 쪽이 원한 상태가 이미 참이라는 뜻이다.
@Suite struct RemotePlaceRepositoryTest {

    /// 못 박는 것: **목록이 비어 보일 때도 전체 삭제가 끝까지 간다.** 매퍼가 placeId·좌표 없는 행을
    /// 버리므로 화면의 목록이 비어 있어도 서버에는 행이 남아 있을 수 있고, 전체 삭제가 그 행을 치우는
    /// 유일한 길이다. 404 를 그대로 올리면 사용자는 아무 일도 안 했는데 「지우지 못했어요」를 본다.
    @Test("전체 삭제는 이미 비어 있다는 404 를 실패로 올리지 않는다")
    func deleteAllSwallows404() async throws {
        let api = FakePlaceApi(allDeleteError: httpException(404, Self.FAVORITE_PLACE_NOT_FOUND_BODY))

        // 던지면 테스트가 실패한다 — 확인할 것은 「안 터진다」가 전부다.
        try await RemotePlaceRepository(api: api).deleteAllFavoritePlaces()

        #expect(api.allDeleteCalls.value == 1)
    }

    /// 404 만 삼킨다는 경계. 500 까지 삼키면 서버 장애가 「다 지웠어요」로 보인다.
    @Test("전체 삭제의 500 은 그대로 올린다")
    func deleteAllRaises500() async {
        let api = FakePlaceApi(allDeleteError: httpException(500, #"{"code":"INTERNAL","message":"서버 오류"}"#))

        let e = await #expect(throws: FavoritePlaceException.self) {
            try await RemotePlaceRepository(api: api).deleteAllFavoritePlaces()
        }

        #expect(e?.httpStatus == 500)
        #expect(e?.isNotFound == false, "500 이 「없음」으로 접혔다")
    }

    /// 못 박는 것: 빈 선택으로는 **서버를 부르지 않는다.** 서버는 400 `INVALID_PLACE_IDS` 를 주고
    /// (실측: `{"placeIds":[]}` → 400), 그 에러가 화면에 「지우지 못했어요」로 서는데 사용자가 고른
    /// 것은 애초에 없다.
    @Test("다건 삭제에 빈 목록을 주면 서버를 부르지 않는다")
    func emptyBatchDoesNotCallServer() async throws {
        let api = FakePlaceApi()

        try await RemotePlaceRepository(api: api).deleteFavoritePlaces(ids: [])

        #expect(api.batchDeleteCalls.value == [])
    }

    /// 키 이름이 틀리면 서버가 조용히 400 을 준다 — 저장소를 거쳐도 `placeIds` 로 실리는지 본다.
    @Test("다건 삭제는 고른 id 를 placeIds 로 그대로 넘긴다")
    func batchPassesIds() async throws {
        let api = FakePlaceApi()

        try await RemotePlaceRepository(api: api).deleteFavoritePlaces(ids: [19, 20])

        #expect(api.batchDeleteCalls.value == [[19, 20]])
    }

    /// 못 박는 것: **전부-아니면-전무의 404 를 성공으로 접지 않는다.** 실측에서 `[19, 999999]` 는
    /// 404 였고 19 도 지워지지 않았다 — 성공으로 접으면 화면이 「지웠다」고 믿고 목록에서 빼
    /// 서버와 영구히 어긋난다.
    @Test("다건 삭제의 404 는 도메인 예외로 올라온다")
    func batch404Raises() async {
        let api = FakePlaceApi(batchDeleteError: httpException(404, Self.FAVORITE_PLACE_NOT_FOUND_BODY))

        let e = await #expect(throws: FavoritePlaceException.self) {
            try await RemotePlaceRepository(api: api).deleteFavoritePlaces(ids: [19, 999_999])
        }

        #expect(e?.isNotFound == true, "404 FAVORITE_PLACE_NOT_FOUND 가 「없음」으로 읽히지 않았다")
        #expect(e?.code == "FAVORITE_PLACE_NOT_FOUND")
    }

    /// 못 박는 것: 단건 삭제의 404 도 올린다. 같은 id 두 번째도, 없는 id 도, **남의 id 도** 같은
    /// 404 라서(실측) 성공으로 접으면 남의 행 삭제 시도까지 성공으로 보인다.
    @Test("한 건 삭제의 404 는 성공으로 접히지 않는다")
    func single404Raises() async {
        let api = FakePlaceApi(singleDeleteError: httpException(404, Self.FAVORITE_PLACE_NOT_FOUND_BODY))

        let e = await #expect(throws: FavoritePlaceException.self) {
            try await RemotePlaceRepository(api: api).deleteFavoritePlace(id: 19)
        }

        #expect(e?.isNotFound == true)
    }

    /// `{code,message}` 가 아닌 에러 본문에서도 터지지 않아야 한다 — `POST .../favorite-places/all` 의
    /// 405 가 Spring 기본 `{timestamp,status,error,path}` 다(실측). 코드 파싱이 null 로 떨어지고
    /// 상태 코드만 근거로 남는다.
    @Test("code 가 없는 에러 본문도 상태 코드만으로 다룬다")
    func bodyWithoutCode() async {
        let body = #"{"timestamp":"2026-11-01T00:00:00Z","status":405,"error":"Method Not Allowed","path":"/x"}"#
        let api = FakePlaceApi(singleDeleteError: httpException(405, body))

        let e = await #expect(throws: FavoritePlaceException.self) {
            try await RemotePlaceRepository(api: api).deleteFavoritePlace(id: 19)
        }

        #expect(e?.httpStatus == 405)
        #expect(e?.code == nil)
    }

    private func httpException(_ code: Int, _ body: String) -> HttpException {
        HttpException(Response<Void>.error(code, body))
    }

    /// 실측 본문 그대로(2026-11-01, 로컬 `:8080`) — 없는 것·남의 것·두 번째 삭제가 모두 이것이다.
    private static let FAVORITE_PLACE_NOT_FOUND_BODY =
        #"{"code":"FAVORITE_PLACE_NOT_FOUND","message":"등록되지 않은 즐겨찾기입니다."}"#
}

private final class FakePlaceApi: PlaceApi {
    private let singleDeleteError: (any Error)?
    private let batchDeleteError: (any Error)?
    private let allDeleteError: (any Error)?

    let singleDeleteCalls = Locked<[Int64]>([])
    let batchDeleteCalls = Locked<[[Int64]]>([])
    let allDeleteCalls = Locked(0)

    init(
        singleDeleteError: (any Error)? = nil,
        batchDeleteError: (any Error)? = nil,
        allDeleteError: (any Error)? = nil
    ) {
        self.singleDeleteError = singleDeleteError
        self.batchDeleteError = batchDeleteError
        self.allDeleteError = allDeleteError
    }

    func searchPlaces(query: String) async throws -> PlaceSearchListResponse { PlaceSearchListResponse() }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> Response<AddressResponseDto> {
        .success(AddressResponseDto())
    }

    func addFavoritePlace(request: FavoritePlaceRequestDto) async throws {}

    func getFavoritePlaces() async throws -> FavoritePlaceListResponse { FavoritePlaceListResponse() }

    func deleteFavoritePlace(placeId: Int64) async throws {
        singleDeleteCalls.append(placeId)
        if let singleDeleteError { throw singleDeleteError }
    }

    func deleteFavoritePlaces(request: FavoritePlaceDeleteRequestDto) async throws {
        batchDeleteCalls.append(request.placeIds)
        if let batchDeleteError { throw batchDeleteError }
    }

    func deleteAllFavoritePlaces() async throws {
        allDeleteCalls.update { $0 += 1 }
        if let allDeleteError { throw allDeleteError }
    }
}
