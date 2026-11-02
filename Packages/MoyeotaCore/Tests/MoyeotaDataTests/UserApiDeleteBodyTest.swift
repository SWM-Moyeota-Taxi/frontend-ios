import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// **회원 탈퇴 요청이 본문을 싣고 DELETE 로 나가는지**를 확인한다.
///
/// ### 왜 선언 검사(AuthenticatedPathContractTest)로는 부족한가
/// `ApiRoute.DELETE` 는 `hasBody = false` 라 본문과 함께 쓸 수 없는데, 그 조합을 **컴파일러가
/// 막지 않는다.** 터지는 건 요청을 만드는 **실행 시점**이고
/// (`IllegalArgumentException: Non-body HTTP method cannot contain @Body or @Field parameters.`),
/// 그 시점은 사용자가 「탈퇴하기」를 누른 순간이다. 선언 값만 읽는 검사는
/// "`HTTP` 로 선언돼 있다"까지만 말해 주고 실제로 본문이 실리는지는 말해 주지 않는다.
@Suite struct UserApiDeleteBodyTest {

    /// 핵심 검사. 서버가 비밀번호를 `@RequestBody` 로 받으므로 본문이 **반드시** 실려야 하고,
    /// 동사는 서버 `@DeleteMapping` 에 맞춰 DELETE 여야 한다.
    ///
    /// 이 테스트가 깨지는 가장 흔한 경우는 누군가 `HTTP` 를 `DELETE` 로 "정리"하는 것이다 —
    /// 그러면 요청을 만들다 던져 호출까지 가지 못한다.
    @Test("탈퇴 요청은 DELETE 인데 본문에 비밀번호를 싣는다")
    func deleteCarriesPassword() async throws {
        let stub = StubServer(status: 204)
        let api = RestUserApi(rest: try stub.rest())

        try await api.deleteAccount(request: AccountDeletionRequest(password: "Passw0rd!"))

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.method == "DELETE")
        #expect(request.urlString == stub.url("api/v1/users/me"))
        #expect(request.body != nil, "DELETE 에 본문이 실리지 않았다 — HTTP(hasBody: true) 가 빠졌다")
        #expect(request.bodyString == #"{"password":"Passw0rd!"}"#)
    }

    /// 비밀번호가 **URL 에 새지 않는** 것을 못 박는다. 쿼리로 돌리면 서버 액세스 로그와
    /// 프록시·브라우저 히스토리에 평문이 남는다. 쿼리 문자열이 비어 있어야 한다.
    @Test("비밀번호가 URL 에 실리지 않는다")
    func passwordNotInUrl() async throws {
        let stub = StubServer(status: 204)
        let api = RestUserApi(rest: try stub.rest())

        try await api.deleteAccount(request: AccountDeletionRequest(password: "Passw0rd!"))

        let request = try #require(stub.requests.first)
        #expect(request.query == nil, "비밀번호가 쿼리 문자열로 나갔다")
        #expect(!request.urlString.contains("Passw0rd"), "URL 에 비밀번호가 보인다: \(request.urlString)")
    }

    /// 204 는 본문이 없다 — 반환값 없는 호출이 그 응답을 예외 없이 끝내는지 본다.
    @Test("204 는 본문 없이 성공으로 끝난다")
    func noContentSucceeds() async throws {
        let stub = StubServer(status: 204, body: "")
        let api = RestUserApi(rest: try stub.rest())

        // 던지면 테스트가 실패한다. 돌려받을 값이 없는 성공이라 확인할 것은 "안 터진다"가 전부다.
        try await api.deleteAccount(request: AccountDeletionRequest(password: "Passw0rd!"))
    }

    /// **함정 자체를 기록해 두는 음성 대조군.** 같은 서명을 `DELETE` 로 쓰면 `RestClient` 가 거부한다.
    ///
    /// 이 테스트가 깨진다면(= 더 이상 던지지 않는다면) `DELETE` 선언이 본문을 허용하도록 바뀐 것이고,
    /// 탈퇴와 프로필 이미지 되돌리기를 가르는 안전장치가 하나 사라진 것이다.
    @Test("DELETE 에 본문을 붙이면 RestClient 가 거부한다 - 그래서 HTTP 를 쓴다")
    func deleteWithBodyIsRejected() async throws {
        let stub = StubServer(status: 204)
        let bodylessDelete = ApiRoute.DELETE("api/v1/users/me")

        let thrown = await #expect(throws: IllegalArgumentException.self, "RestClient 가 DELETE + 본문을 받아들였다") {
            try await stub.rest().callUnit(bodylessDelete, body: AccountDeletionRequest(password: "Passw0rd!"))
        }

        #expect(
            thrown?.message?.contains("Non-body HTTP method cannot contain @Body") == true,
            "거부 이유가 본문 문제가 아니다: \(String(describing: thrown?.message))"
        )
        #expect(stub.requests.isEmpty, "거부된 요청이 나갔다")
    }
}
