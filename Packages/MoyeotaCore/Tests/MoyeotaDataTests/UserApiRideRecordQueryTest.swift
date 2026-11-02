import Testing
@testable import MoyeotaData

/// 탑승 기록 조회가 **실제로 어떤 URL 로 나가는지** 확인한다.
///
/// `AuthenticatedPathContractTest` 는 선언 값만 읽으므로 「null 커서가 쿼리에 실리는가」를
/// 말해 주지 못한다. 그 답은 `RestClient` 의 동작(쿼리의 null 을 생략한다)에 달려 있고, 바뀌면
/// 서버에 `cursor=` 가 나가기 시작한다 — 서버는 그 빈 값도 200 으로 받지만(실측) 계약과 어긋나고,
/// 반대로 **커서를 실어야 할 때 빠지면 2페이지가 영영 1페이지가 되어 목록이 무한히 중복된다.**
@Suite struct UserApiRideRecordQueryTest {
    private let emptyPage = #"{"rides":[],"nextCursor":null,"hasNext":false}"#

    private func makeApi() throws -> (RestUserApi, StubServer) {
        let stub = StubServer(status: 200, body: emptyPage)
        return (RestUserApi(rest: try stub.rest()), stub)
    }

    /// 첫 페이지. 커서가 null 이면 **쿼리에 실리지 않아야** 한다 — `cursor=` 를 보내는 쪽이
    /// 서버에서 200 이긴 하지만(실측) 「값이 없다」와 「빈 값이다」를 섞는 계약이 된다.
    /// 기본 `size` 는 서버 기본값과 같은 20 이다(1~50 밖이면 400 `INVALID_PAGE_SIZE`).
    @Test("cursor 가 null 이면 쿼리에 실리지 않는다")
    func nullCursorOmitted() async throws {
        let (api, stub) = try makeApi()

        _ = try await api.getMyRideRecords()

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.path == "/api/v1/users/me/parties")
        #expect(request.queryParameter("cursor") == nil, "커서가 없는데 cursor 쿼리가 나갔다")
        #expect(request.queryParameter("size") == String(RIDE_RECORD_PAGE_SIZE))
        #expect(RIDE_RECORD_PAGE_SIZE == 20)
    }

    /// 2페이지. 이전 응답의 `nextCursor` 를 그대로 싣는다. 빠지면 서버가 첫 페이지를 다시 주고
    /// 목록이 무한히 중복된다(이 화면에서 가장 비싼 버그다).
    @Test("cursor 가 있으면 그 값이 쿼리로 나간다")
    func cursorSent() async throws {
        let (api, stub) = try makeApi()

        _ = try await api.getMyRideRecords(cursor: 69, size: 1)

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.queryParameter("cursor") == "69")
        #expect(request.queryParameter("size") == "1")
    }

    /// 서버에 없는 `status` 파라미터가 **나가지 않는** 것을 못 박는다.
    ///
    /// `docs/BACKEND-GAP-CLEANUP.md` §4 가 적어 둔 `?status=FINISHED` 는 구현되지 않은 추측이었고,
    /// 붙여도 400 이 아니라 **200 + 조용히 무시**라서(실측 2026-11-01) 「필터가 동작한다」고
    /// 착각하고 지나간다. 필터는 필요 없다 — 서버가 이미 완료분만 준다.
    @Test("서버에 없는 status 파라미터를 보내지 않는다")
    func noStatusParameter() async throws {
        let (api, stub) = try makeApi()

        _ = try await api.getMyRideRecords(cursor: nil, size: 50)

        #expect(stub.requests.first?.queryParameter("status") == nil, "서버에 없는 status 파라미터가 나갔다")
    }
}
