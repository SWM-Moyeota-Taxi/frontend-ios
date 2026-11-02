import Foundation
import Testing
@testable import MoyeotaData

/// `URLSession` 이 **실제로 소켓에 쓰는 것**을 본다. 스텁은 이 층을 지나치므로 못 잡는다:
/// DELETE 본문을 버리거나 `Authorization` 을 빼면 스텁 테스트는 통과하고 서버에서만 실패한다.
@Suite struct LoopbackWireTest {
    private static let noContent = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"

    private static func ok(_ body: String, extraHeaders: String = "") -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(extraHeaders)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private func makeApis(baseUrl: String, accessToken: String = "wire.access") throws -> NetworkModule.Apis {
        try NetworkModule.create(
            baseUrl: baseUrl,
            debugLogging: false,
            tokenHolder: FakeTokenHolder(accessToken: accessToken, refreshToken: "wire.refresh")
        )
    }

    private func header(_ name: String, in request: String) -> String? {
        request.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// 서버가 비밀번호를 `@RequestBody` 로 받는다. 본문이 버려지면 탈퇴가 영영 400 이다.
    @Test("회원 탈퇴 DELETE 는 소켓에 Bearer 와 본문을 싣는다")
    func deleteAccountOnWire() async throws {
        let server = try LoopbackServer { _ in Self.noContent }
        let baseUrl = try await server.start()
        defer { server.stop() }

        try await makeApis(baseUrl: baseUrl).user.deleteAccount(request: AccountDeletionRequest(password: "Passw0rd!"))

        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("DELETE /api/v1/users/me HTTP/1.1\r\n"))
        #expect(header("Authorization", in: request) == "Bearer wire.access")
        #expect(header("Content-Type", in: request) == "application/json; charset=utf-8")
        #expect(request.hasSuffix(#"{"password":"Passw0rd!"}"#))
    }

    /// Retrofit 은 본문 없는 POST 에 빈 본문을 싣는다(`Content-Length: 0`). 없으면 411 을 내는 프록시가 있다.
    @Test("본문 없는 POST 는 Content-Length 0 으로 나간다")
    func emptyPostOnWire() async throws {
        let server = try LoopbackServer { _ in Self.ok(#"{"status":"ACTIVE"}"#) }
        let baseUrl = try await server.start()
        defer { server.stop() }

        _ = try await makeApis(baseUrl: baseUrl).matching.joinParty(partyId: 7)

        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("POST /api/v1/matching/rooms/7/join HTTP/1.1\r\n"))
        #expect(header("Content-Length", in: request) == "0")
        #expect(header("Content-Type", in: request) == nil)
    }

    @Test("본문 없는 DELETE 는 본문을 싣지 않는다")
    func emptyDeleteOnWire() async throws {
        let server = try LoopbackServer { _ in Self.noContent }
        let baseUrl = try await server.start()
        defer { server.stop() }

        try await makeApis(baseUrl: baseUrl).user.resetProfileImage()

        let request = try #require(server.requests.first)
        #expect(request.hasPrefix("DELETE /api/v1/users/me/profile-image HTTP/1.1\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test("쿼리의 인코딩이 소켓까지 그대로 간다")
    func queryOnWire() async throws {
        let server = try LoopbackServer { _ in Self.ok(#"{"list":[]}"#) }
        let baseUrl = try await server.start()
        defer { server.stop() }

        _ = try await makeApis(baseUrl: baseUrl).place.searchPlaces(query: "a b+c")

        #expect(server.requests.first?.hasPrefix("GET /api/v1/places?query=a%20b%2Bc HTTP/1.1\r\n") == true)
    }

    /// 원본(OkHttp)은 `Accept-Language` 를 싣지 않아 서버가 자기 기본 로케일로 답한다. `URLSession` 은 그냥 두면
    /// 기기 언어를 실어 `@NotBlank` 같은 서버 기본 문구의 언어가 기기마다 갈린다. 헤더를 아예 뺄 수는 없어
    /// 빈 값으로 막는다(`NetworkModule.makeSession`).
    @Test("기기 언어를 Accept-Language 로 싣지 않는다")
    func noDeviceLanguageOnWire() async throws {
        let server = try LoopbackServer { index in
            index == 1 ? Self.noContent : Self.ok(#"{"status":"ACTIVE"}"#)
        }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let apis = try makeApis(baseUrl: baseUrl)
        let url = try #require(URL(string: baseUrl + "profile.png"))

        _ = try await apis.matching.joinParty(partyId: 7)
        try await apis.user.resetProfileImage()
        _ = try await apis.config.getConfig()
        _ = try await apis.imageClient.data(from: url)
        _ = try await apis.streamClient.execute(URLRequest(url: url))

        #expect(server.requests.count == 5)
        for request in server.requests {
            #expect(header("Accept-Language", in: request) ?? "" == "", "\(request)")
        }
    }

    /// OkHttp 에는 쿠키 저장소가 없다. 실리면 서버 세션이 토큰과 별개로 따라다닌다.
    @Test("응답 쿠키를 다음 요청에 싣지 않는다")
    func noCookies() async throws {
        let server = try LoopbackServer { _ in Self.ok("{}", extraHeaders: "Set-Cookie: session=abc; Path=/\r\n") }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let config = try makeApis(baseUrl: baseUrl).config

        _ = try await config.getConfig()
        _ = try await config.getConfig()

        #expect(server.requests.count == 2)
        #expect(header("Cookie", in: server.requests[1]) == nil)
    }

    /// 폴링 응답이 캐시에서 나오면 화면이 전이를 영영 못 잡는다.
    @Test("GET 응답을 캐시에서 답하지 않는다")
    func noHttpCache() async throws {
        let server = try LoopbackServer { _ in Self.ok("{}", extraHeaders: "Cache-Control: max-age=600\r\n") }
        let baseUrl = try await server.start()
        defer { server.stop() }
        let config = try makeApis(baseUrl: baseUrl).config

        _ = try await config.getConfig()
        _ = try await config.getConfig()

        #expect(server.requests.count == 2)
    }

    /// `URLRequest` 기본값(60초)이 세션 값을 덮으면 원본의 읽기 타임아웃이 사라진다.
    @Test("세션의 요청 타임아웃이 실제로 적용된다")
    func requestTimeoutApplies() async throws {
        let server = try LoopbackServer { _ in nil }
        let baseUrl = try await server.start()
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        let client = HttpClient(session: URLSession(configuration: configuration))
        let api = RestConfigApi(rest: try RestClient(baseUrl: baseUrl, client: client))

        let clock = ContinuousClock()
        let startedAt = clock.now
        let error = await #expect(throws: URLError.self) {
            _ = try await api.getConfig()
        }

        #expect(error?.code == .timedOut)
        #expect(startedAt.duration(to: clock.now) < .seconds(10))
    }
}
