import Testing
@testable import MoyeotaData

/// **즐겨찾기 삭제 3종이 실제로 어떤 요청으로 나가는지**를 확인한다.
///
/// ### 왜 선언 검사(AuthenticatedPathContractTest)만으로는 부족한가
/// 그쪽은 선언 값만 읽으므로 **본문에 무엇이 실리는지**를 못 본다. 다건 삭제의 유일한 계약이
/// 「키 이름이 `placeIds` 다」인데, 이름이 틀려도 컴파일과 실행은 통과하고 서버가 모르는 키를
/// 무시해 400 `INVALID_PLACE_IDS` 로만 드러난다(실측 2026-11-01, 로컬 `:8080`: `{"ids":[2]}` → 400).
/// 그 실패는 「서버가 거부했다」처럼 보여 원인이 앱 쪽 오타임을 가린다.
///
/// 응답 계약(실측 2026-11-01, 로컬 `:8080`, `moyeota2`):
/// - 세 경로 모두 성공이 **204 No Content**, 본문 없음
/// - 단건·다건의 404 는 `FAVORITE_PLACE_NOT_FOUND` (없는 것·남의 것을 구분하지 않는다)
/// - `/all` 은 이미 비어 있으면 404 (멱등이 아니다)
@Suite struct PlaceApiDeleteTest {

    /// 핵심 검사. 동사가 POST 여야 하고(서버 `@PostMapping`), 본문 키가 `placeIds` 여야 한다.
    /// 둘 중 하나라도 틀리면 실패 모양이 405 가 아니라 **400** 이라 원인을 가린다.
    @Test("다건 삭제는 POST 로 placeIds 를 싣는다")
    func batchDelete() async throws {
        let stub = StubServer(status: 204)
        let api = RestPlaceApi(rest: try stub.rest())

        try await api.deleteFavoritePlaces(request: FavoritePlaceDeleteRequestDto(placeIds: [1, 2]))

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.urlString == stub.url("api/v1/users/me/favorite-places/batch-delete"))
        #expect(request.bodyString == #"{"placeIds":[1,2]}"#)
    }

    /// 단건은 id 를 **경로**에 싣고 본문이 없다. 쿼리로 돌리면 서버 `{placeId}` 매핑에 닿지 못한다.
    @Test("한 건 삭제는 DELETE 에 placeId 를 경로로 싣는다")
    func singleDelete() async throws {
        let stub = StubServer(status: 204)
        let api = RestPlaceApi(rest: try stub.rest())

        try await api.deleteFavoritePlace(placeId: 3)

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.method == "DELETE")
        #expect(request.urlString == stub.url("api/v1/users/me/favorite-places/3"))
        #expect(request.body == nil, "단건 삭제에 본문이 실렸다")
        #expect(request.query == nil, "placeId 가 쿼리로 나갔다")
    }

    /// 전체 삭제는 `/all` 리터럴 경로다. 실측에서 리터럴이 `{placeId}` 템플릿을 이겨 204 가 왔고,
    /// placeId 가 Long 이라 "all" 이 그쪽으로 흘러들 수도 없다.
    @Test("전체 삭제는 DELETE all 이고 본문이 없다")
    func deleteAll() async throws {
        let stub = StubServer(status: 204)
        let api = RestPlaceApi(rest: try stub.rest())

        try await api.deleteAllFavoritePlaces()

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.method == "DELETE")
        #expect(request.urlString == stub.url("api/v1/users/me/favorite-places/all"))
        #expect(request.body == nil, "전체 삭제에 본문이 실렸다")
    }

    /// 세 메서드 모두 204 + 빈 본문으로 끝난다 — 돌려받을 값이 없으니 「안 터진다」가 확인할 전부다.
    @Test("204 는 본문 없이 성공으로 끝난다")
    func noContentSucceeds() async throws {
        let stub = StubServer(status: 204, body: "")
        let api = RestPlaceApi(rest: try stub.rest())

        try await api.deleteFavoritePlace(placeId: 3)
        try await api.deleteFavoritePlaces(request: FavoritePlaceDeleteRequestDto(placeIds: [3]))
        try await api.deleteAllFavoritePlaces()
    }

    /// **함정 자체를 기록해 두는 음성 대조군.** `HTTP(method: .DELETE, hasBody: true)` 로
    /// batch-delete 를 선언해도 **`RestClient` 는 받아들인다** — 즉 컴파일도 실행도 이것을 막지 않는다.
    ///
    /// 그렇게 나간 요청은 405 가 아니라 400
    /// `{"code":"INVALID_REQUEST","message":"placeId: 형식이 올바르지 않습니다."}` 를 받는다(실측
    /// 2026-11-01, 로컬 `:8080`). `DELETE .../favorite-places/{placeId}` 매핑이 "batch-delete" 를
    /// placeId 로 잡아 Long 변환에 실패하기 때문이다 — **조용히 엉뚱한 엔드포인트로 간다.**
    /// 서버 없이 잡을 수 있는 자리는 동사를 못 박는 테스트뿐이다
    /// (`AuthenticatedPathContractTest` 의 「즐겨찾기 다건 삭제는 POST 다」).
    @Test("다건 삭제를 DELETE 로 선언해도 RestClient 는 막지 않는다 - 그래서 테스트로 막는다")
    func wrongVerbIsNotBlocked() async throws {
        let stub = StubServer(status: 204)
        let wrongVerb = ApiRoute.HTTP(
            method: .DELETE,
            path: "api/v1/users/me/favorite-places/batch-delete",
            hasBody: true
        )

        try await stub.rest().callUnit(wrongVerb, body: FavoritePlaceDeleteRequestDto(placeIds: [1]))

        let request = try #require(stub.requests.first)
        #expect(
            request.method == "DELETE" && request.body != nil,
            "RestClient 가 HTTP DELETE + 본문을 거부했다 — 그렇다면 운영 코드의 동사 고정은 덜 급해진다"
        )
        // 이 요청이 서버에 닿으면 405 가 아니라 `{placeId}` 매핑의 400 이 온다(위 주석 참고).
        #expect(request.urlString == stub.url("api/v1/users/me/favorite-places/batch-delete"))
    }
}
