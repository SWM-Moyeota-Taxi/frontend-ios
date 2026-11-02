import Foundation
import MoyeotaDomain
import os
import Testing
@testable import MoyeotaData

/// 원본에 대응 테스트가 없는 HTTP 계층 전체 경로. OkHttp·Retrofit 이 해 주던 동작을 직접 구현한 자리들이다.
@Suite struct HttpStackTest {

    private func makeApis(
        _ stub: StubServer,
        tokens: any TokenHolder = FakeTokenHolder(accessToken: "live.access", refreshToken: "live.refresh"),
        debugLogging: Bool = false,
        logSink: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> NetworkModule.Apis {
        try NetworkModule.create(
            baseUrl: stub.baseUrl,
            debugLogging: debugLogging,
            tokenHolder: tokens,
            protocolClasses: [StubURLProtocol.self],
            logSink: logSink
        )
    }

    /// 낡은 토큰에는 401, 새 토큰에는 200. 재발급은 회전된 쌍을 준다.
    private func rotatingServer(
        body: String = #"{"places":[]}"#,
        reissueDelay: Duration? = nil
    ) -> StubServer {
        StubServer { request in
            if request.path == "/api/v1/auth/reissue" {
                return StubResponse(
                    status: 200,
                    body: #"{"accessToken":"new.access","refreshToken":"new.refresh"}"#,
                    delay: reissueDelay
                )
            }
            if request.header("Authorization") == "Bearer new.access" {
                return StubResponse(status: 200, body: body)
            }
            return StubResponse(status: 401, body: #"{"code":"USER002","message":"만료"}"#)
        }
    }

    // MARK: - base URL

    @Test("base URL 은 끝이 슬래시여야 한다")
    func baseUrlMustEndInSlash() {
        let error = #expect(throws: IllegalArgumentException.self) {
            try NetworkModule.create(
                baseUrl: "https://api.moyeota.co.kr",
                debugLogging: false,
                tokenHolder: FakeTokenHolder(accessToken: nil, refreshToken: nil)
            )
        }
        #expect(error?.message == "baseUrl must end in /: https://api.moyeota.co.kr")
    }

    @Test("빌드 설정의 base URL 은 끝에 슬래시가 없으면 붙인다 - 원본 build.gradle.kts 의 보정")
    func normalizedBaseUrlAppendsSlash() throws {
        #expect(NetworkModule.normalizedBaseUrl("http://localhost:8080") == "http://localhost:8080/")
        #expect(NetworkModule.normalizedBaseUrl("https://api.moyeota.co.kr/") == "https://api.moyeota.co.kr/")
        // 보정한 값은 Retrofit 규약을 지나간다. 이 줄이 원본에서 앱이 죽지 않는 이유다
        _ = try NetworkModule.create(
            baseUrl: NetworkModule.normalizedBaseUrl("https://api.moyeota.co.kr"),
            debugLogging: false,
            tokenHolder: FakeTokenHolder(accessToken: nil, refreshToken: nil)
        )
    }

    @Test("보정은 슬래시만 붙이고 빈 값은 그대로 거부된다")
    func normalizedBaseUrlKeepsInvalidValuesInvalid() {
        #expect(throws: IllegalArgumentException.self) {
            try NetworkModule.create(
                baseUrl: NetworkModule.normalizedBaseUrl(""),
                debugLogging: false,
                tokenHolder: FakeTokenHolder(accessToken: nil, refreshToken: nil)
            )
        }
    }

    @Test("http 나 https 가 아닌 base URL 은 거부한다")
    func baseUrlMustBeHttp() {
        for invalid in ["ftp://host/", "not a url/", "http:///"] {
            #expect(throws: IllegalArgumentException.self, "\(invalid)") {
                try NetworkModule.create(
                    baseUrl: invalid,
                    debugLogging: false,
                    tokenHolder: FakeTokenHolder(accessToken: nil, refreshToken: nil)
                )
            }
        }
    }

    @Test("base URL 에 경로가 있으면 그 아래로 잇는다")
    func baseUrlWithPathIsKept() async throws {
        let stub = StubServer(status: 200, body: "{}")
        let rest = try RestClient(baseUrl: stub.url("gateway/"), client: HttpClient(session: stub.session()))

        _ = try await RestConfigApi(rest: rest).getConfig()

        #expect(stub.requests.first?.urlString == stub.url("gateway/api/v1/config"))
    }

    // MARK: - 쿼리·본문

    /// `URLQueryItem` 은 `+` 를 그대로 둬 Spring 이 공백으로 읽는다.
    @Test("쿼리 값은 OkHttp 와 같게 인코딩된다")
    func queryEncoding() async throws {
        let stub = StubServer(status: 200, body: #"{"list":[]}"#)

        _ = try await RestPlaceApi(rest: try stub.rest()).searchPlaces(query: "a b+c&d=e/한글~*-._")

        #expect(stub.requests.first?.query == "query=a%20b%2Bc%26d%3De%2F%ED%95%9C%EA%B8%80%7E*-._")
        #expect(stub.requests.first?.queryParameter("query") == "a b+c&d=e/한글~*-._")
    }

    /// 서버가 네 값의 유무로 핸들러를 고른다 — 하나라도 빠지면 전체 목록으로 떨어진다.
    @Test("지도 범위 조회는 네 좌표를 순서대로 싣는다")
    func withinQuery() async throws {
        let stub = StubServer(status: 200, body: #"{"list":[]}"#)

        _ = try await RestMatchingApi(rest: try stub.rest())
            .getPartiesWithin(swLat: 37.5, swLng: 127.0, neLat: 37.6, neLng: 127.125)

        #expect(stub.requests.first?.query == "swLat=37.5&swLng=127.0&neLat=37.6&neLng=127.125")
    }

    @Test("채팅 검색은 null 커서를 빼고 키워드와 크기를 싣는다")
    func searchQuery() async throws {
        let stub = StubServer(status: 200, body: #"{"messages":[]}"#)

        _ = try await RestChatApi(rest: try stub.rest())
            .searchMessages(chatRoomId: 7, keyword: "안녕", cursor: nil, size: 30)

        let request = try #require(stub.requests.first)
        #expect(request.path == "/api/v1/chat-rooms/7/messages/search")
        #expect(request.query == "keyword=%EC%95%88%EB%85%95&size=30")
    }

    @Test("JSON 본문의 Content-Type 은 OkHttp 와 같다")
    func contentType() async throws {
        let stub = StubServer(status: 200, body: #"{"accessToken":"a","refreshToken":"r"}"#)

        _ = try await RestAuthApi(rest: try stub.rest()).login(request: LoginRequestDto(loginId: "id", password: "pw"))

        let request = try #require(stub.requests.first)
        #expect(request.header("Content-Type") == "application/json; charset=utf-8")
        #expect(request.bodyString == #"{"loginId":"id","password":"pw"}"#)
    }

    @Test("선언과 다른 경로 쿼리 인자는 거부한다")
    func argumentsMustMatchDeclaration() throws {
        let stub = StubServer()
        let rest = try stub.rest()

        #expect(throws: IllegalArgumentException.self) {
            try rest.newRequest(.GET("rooms/{partyId}"))
        }
        #expect(throws: IllegalArgumentException.self) {
            try rest.newRequest(.GET("rooms", query: ["size"]), query: ["status": "x"])
        }
    }

    // MARK: - 응답 해석

    @Test("2xx 가 아니면 HttpException 이 상태와 본문 바이트를 싣는다")
    func httpErrorCarriesStatusAndBytes() async throws {
        let bytes = Data([0xFF, 0xFE, 0x41])
        let stub = StubServer { _ in StubResponse(status: 502, bytes: bytes) }

        let error = await #expect(throws: HttpException.self) {
            _ = try await RestConfigApi(rest: try stub.rest()).getConfig()
        }

        #expect(error?.code() == 502)
        #expect(error?.errorBodyBytes() == bytes)
    }

    @Test("반환값 없는 호출도 2xx 가 아니면 던진다")
    func unitCallThrowsOnError() async throws {
        let stub = StubServer(status: 404, body: #"{"code":"FAVORITE_PLACE_NOT_FOUND","message":"없음"}"#)

        let error = await #expect(throws: HttpException.self) {
            try await RestPlaceApi(rest: try stub.rest()).deleteAllFavoritePlaces()
        }

        #expect(error?.readApiError()?.code == "FAVORITE_PLACE_NOT_FOUND")
    }

    @Test("반환값 없는 호출은 2xx 본문을 보지 않는다")
    func unitCallIgnoresBody() async throws {
        let stub = StubServer(status: 200, body: "<html>not json</html>")

        try await RestChatApi(rest: try stub.rest()).joinRoom(chatRoomId: 1)
    }

    /// Retrofit: "Response from ... was null but response body type was declared as non-null".
    @Test("값을 돌려주는 호출이 204 를 받으면 예외다")
    func typedCallOnNoContent() async throws {
        let stub = StubServer(status: 204)

        await #expect(throws: IllegalStateException.self) {
            _ = try await RestConfigApi(rest: try stub.rest()).getConfig()
        }
    }

    @Test("값을 돌려주는 호출이 200 빈 본문을 받으면 파싱 실패다")
    func typedCallOnEmptyBody() async throws {
        let stub = StubServer(status: 200, body: "")

        await #expect(throws: DecodingError.self) {
            _ = try await RestConfigApi(rest: try stub.rest()).getConfig()
        }
    }

    /// 주소가 없는 좌표(바다 등)는 예외가 아니라 null 이다.
    @Test("역지오코딩 404 는 던지지 않고 null 주소가 된다")
    func reverseGeocodeNotFound() async throws {
        let stub = StubServer(status: 404, body: #"{"code":"ADDRESS_NOT_FOUND","message":"없음"}"#)

        let response = try await RestPlaceApi(rest: try stub.rest()).reverseGeocode(latitude: 1.5, longitude: 2.5)

        #expect(response.code() == 404)
        #expect(!response.isSuccessful)
        #expect(try response.toReverseAddressOrNull() == nil)
        #expect(stub.requests.first?.query == "latitude=1.5&longitude=2.5")
    }

    @Test("Response 를 돌려주는 호출의 204 는 본문이 null 이다")
    func responseOnNoContent() async throws {
        let stub = StubServer(status: 204)

        let response = try await RestPlaceApi(rest: try stub.rest()).reverseGeocode(latitude: 1, longitude: 2)

        #expect(response.isSuccessful)
        #expect(response.body() == nil)
    }

    @Test("재발급 200 빈 본문은 연결 불가다")
    func reissueEmptyBodyIsUnavailable() async throws {
        let stub = StubServer(status: 200, body: "")
        let refresher = RetrofitTokenRefresher(authApi: RestAuthApi(rest: try stub.rest()))

        #expect(await refresher.refresh(refreshToken: "r") == .unavailable)
    }

    @Test("재발급 204 는 연결 불가다")
    func reissueNoContentIsUnavailable() async throws {
        let stub = StubServer(status: 204)
        let refresher = RetrofitTokenRefresher(authApi: RestAuthApi(rest: try stub.rest()))

        #expect(await refresher.refresh(refreshToken: "r") == .unavailable)
    }

    // MARK: - 헤더 규칙

    @Test("도메인 API 에는 Bearer 가 붙는다")
    func bearerOnDomainApis() async throws {
        let stub = StubServer(status: 200, body: "{}")
        let apis = try makeApis(stub)

        _ = try? await apis.user.getMyProfile()
        _ = try? await apis.matching.getParties()
        _ = try? await apis.place.getFavoritePlaces()
        _ = try? await apis.chat.getMyRooms()
        _ = try? await apis.dispatch.getDriverLocation(partyId: 1)
        _ = try? await apis.report.report(request: ReportRequestDto())

        #expect(stub.requests.count == 6)
        for request in stub.requests {
            #expect(request.header("Authorization") == "Bearer live.access", "\(request.path)")
        }
    }

    /// 깨진 토큰을 실으면 permitAll 경로인데도 JWT 필터가 401 을 낸다.
    @Test("인증 API 와 앱 설정에는 Bearer 가 붙지 않는다")
    func noBearerOnPublicApis() async throws {
        let stub = StubServer(status: 200, body: "{}")
        let apis = try makeApis(stub)

        _ = try await apis.auth.login(request: LoginRequestDto(loginId: "a", password: "b"))
        _ = try await apis.auth.checkPhone(request: PhoneCheckRequestDto(phoneNumber: "010"))
        _ = try await apis.config.getConfig()

        #expect(stub.requests.count == 3)
        #expect(stub.requests.allSatisfy { $0.header("Authorization") == nil })
    }

    /// 프로필 이미지 URL 은 제3자 전체 주소다 — 토큰이 실리면 CDN 액세스 로그에 남는다.
    @Test("이미지 세션에는 Bearer 가 붙지 않는다")
    func noBearerOnImages() async throws {
        let stub = StubServer(status: 200, body: "png")
        let apis = try makeApis(stub)

        _ = try await apis.imageClient.data(from: URL(string: stub.url("profile/presets/03.png"))!)

        #expect(stub.requests.first?.header("Authorization") == nil)
    }

    @Test("미로그인이면 헤더 없이 보내고 401 을 호출부로 올린다")
    func noTokenNoHeader() async throws {
        let stub = StubServer(status: 401, body: #"{"code":"USER005","message":"로그인이 필요합니다."}"#)
        let tokens = FakeTokenHolder(accessToken: nil, refreshToken: nil)
        let apis = try makeApis(stub, tokens: tokens)

        let error = await #expect(throws: HttpException.self) {
            _ = try await apis.user.getMyProfile()
        }

        #expect(error?.code() == 401)
        #expect(stub.requests.count == 1)
        #expect(stub.requests.first?.header("Authorization") == nil)
        #expect(tokens.sessionExpiredCount == 0)
    }

    @Test("이미 붙은 Authorization 은 건드리지 않는다")
    func existingHeaderKept() async throws {
        let stub = StubServer(status: 200)
        let client = HttpClient(
            session: stub.session(),
            interceptors: [AuthHeaderInterceptor(tokens: FakeTokenHolder(accessToken: "live", refreshToken: "r"))]
        )
        var request = URLRequest(url: URL(string: stub.url("x"))!)
        request.setValue("Bearer preset", forHTTPHeaderField: "Authorization")

        _ = try await client.execute(request)

        #expect(stub.requests.first?.header("Authorization") == "Bearer preset")
    }

    // MARK: - 401 재발급

    @Test("401 이면 재발급 후 새 토큰으로 원요청을 다시 보낸다")
    func refreshAndRetry() async throws {
        let stub = rotatingServer(body: #"{"places":[]}"#)
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")

        let response = try await makeApis(stub, tokens: tokens).place.getFavoritePlaces()

        #expect(response == FavoritePlaceListResponse(places: []))
        #expect(stub.requests.map(\.path) == [
            "/api/v1/users/me/favorite-places", "/api/v1/auth/reissue", "/api/v1/users/me/favorite-places",
        ])
        #expect(stub.requests[1].header("Authorization") == nil, "재발급 요청에 Bearer 가 실렸다")
        #expect(stub.requests[1].bodyString == #"{"refreshToken":"old.refresh"}"#)
        #expect(tokens.accessToken == "new.access")
        #expect(tokens.refreshToken == "new.refresh")
    }

    @Test("재시도는 메서드와 본문을 그대로 보낸다")
    func retryKeepsMethodAndBody() async throws {
        let stub = rotatingServer(body: "")
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")

        try await makeApis(stub, tokens: tokens).user.deleteAccount(request: AccountDeletionRequest(password: "p"))

        let retry = try #require(stub.requests.last)
        #expect(retry.method == "DELETE")
        #expect(retry.bodyString == #"{"password":"p"}"#)
        #expect(retry.header("Authorization") == "Bearer new.access")
    }

    @Test("새 토큰으로도 401 이면 한 번만 재시도하고 401 을 올린다")
    func secondUnauthorizedSurfaces() async throws {
        let stub = StubServer { request in
            if request.path == "/api/v1/auth/reissue" {
                return StubResponse(status: 200, body: #"{"accessToken":"new.access","refreshToken":"new.refresh"}"#)
            }
            return StubResponse(status: 401, body: #"{"code":"USER005","message":"로그인이 필요합니다."}"#)
        }
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")

        let error = await #expect(throws: HttpException.self) {
            _ = try await makeApis(stub, tokens: tokens).user.getMyProfile()
        }

        #expect(error?.code() == 401)
        #expect(stub.requests.count == 3)
        #expect(tokens.sessionExpiredCount == 0)
    }

    /// 재발급 요청이 401 을 맞아도 다시 재발급을 부르지 않는다 — 인증 API 를 별도 클라이언트로 둔 이유다.
    @Test("재발급이 401 이면 세션을 비우고 다시 재발급하지 않는다")
    func reissueUnauthorized() async throws {
        let stub = StubServer(status: 401, body: #"{"code":"USER001","message":"무효"}"#)
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")

        await #expect(throws: HttpException.self) {
            _ = try await makeApis(stub, tokens: tokens).user.getMyProfile()
        }

        #expect(stub.requests.map(\.path) == ["/api/v1/local/users/info", "/api/v1/auth/reissue"])
        #expect(tokens.sessionExpiredCount == 1)
    }

    @Test("재발급이 503 이면 세션을 유지하고 401 을 올린다")
    func reissueUnavailableKeepsSession() async throws {
        let stub = StubServer { request in
            request.path == "/api/v1/auth/reissue"
                ? StubResponse(status: 503, body: "<html>503</html>", headers: ["Content-Type": "text/html"])
                : StubResponse(status: 401, body: "{}")
        }
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "live.refresh")

        let error = await #expect(throws: HttpException.self) {
            _ = try await makeApis(stub, tokens: tokens).user.getMyProfile()
        }

        #expect(error?.code() == 401)
        #expect(tokens.sessionExpiredCount == 0)
        #expect(tokens.refreshToken == "live.refresh")
    }

    @Test("동시 요청이 401 을 맞아도 HTTP 재발급은 한 번이다")
    func concurrentRequestsRefreshOnce() async throws {
        let stub = rotatingServer(reissueDelay: .milliseconds(150))
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")
        let place = try makeApis(stub, tokens: tokens).place

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try await place.getFavoritePlaces() }
            }
            try await group.waitForAll()
        }

        #expect(stub.requests.filter { $0.path == "/api/v1/auth/reissue" }.count == 1)
    }

    /// 회전 방식이라 재발급 응답을 버리면 옛 리프레시는 이미 죽어 있어 멀쩡한 세션이 날아간다.
    @Test("부른 쪽이 취소돼도 진행 중인 재발급은 끝까지 가서 토큰을 저장한다")
    func cancelledCallerDoesNotAbortRefresh() async throws {
        let stub = rotatingServer(reissueDelay: .milliseconds(500))
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")
        let place = try makeApis(stub, tokens: tokens).place

        let call = Task { _ = try await place.getFavoritePlaces() }
        let reissueStarted = await waitUntil { stub.requests.contains { $0.path == "/api/v1/auth/reissue" } }
        #expect(reissueStarted)
        call.cancel()

        // 부른 쪽은 재발급을 기다리지 않고 먼저 풀려난다.
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(tokens.accessToken == "old.access", "재발급이 끝나기 전에 풀려나야 한다")

        let rotated = await waitUntil { tokens.accessToken == "new.access" }
        #expect(rotated)
        #expect(tokens.refreshToken == "new.refresh")
        #expect(tokens.sessionExpiredCount == 0)
    }

    @Test("취소된 요청은 CancellationError 로 끝난다")
    func cancellationPropagates() async throws {
        let stub = StubServer { _ in StubResponse(status: 200, body: "{}", delay: .seconds(10)) }
        let api = RestConfigApi(rest: try stub.rest())

        let call = Task { _ = try await api.getConfig() }
        let started = await waitUntil { !stub.requests.isEmpty }
        #expect(started)
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
    }

    @Test("이미 취소된 태스크의 요청은 나가지 않는다")
    func alreadyCancelledDoesNotSend() async throws {
        let stub = StubServer(status: 200, body: "{}")
        let api = RestConfigApi(rest: try stub.rest())

        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await api.getConfig()
        }

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(stub.requests.isEmpty)
    }

    @Test("전송 실패는 URLError 그대로 올라온다")
    func transportFailure() async throws {
        let stub = StubServer { _ in StubResponse(failure: URLError(.notConnectedToInternet)) }

        let error = await #expect(throws: URLError.self) {
            _ = try await RestConfigApi(rest: try stub.rest()).getConfig()
        }

        #expect(error?.code == .notConnectedToInternet)
    }

    // MARK: - OkHttp 후속 요청

    @Test("408 은 한 번 다시 보내고 또 408 이면 그만둔다")
    func requestTimeoutRetriesOnce() async throws {
        let stub = StubServer(status: 408)

        await #expect(throws: HttpException.self) {
            _ = try await RestConfigApi(rest: try stub.rest()).getConfig()
        }

        #expect(stub.requests.count == 2)
    }

    @Test("408 에 Retry-After 가 있으면 다시 보내지 않는다")
    func requestTimeoutWithRetryAfter() async throws {
        let stub = StubServer(status: 408, headers: ["Retry-After": "5"])

        await #expect(throws: HttpException.self) {
            _ = try await RestConfigApi(rest: try stub.rest()).getConfig()
        }

        #expect(stub.requests.count == 1)
    }

    @Test("503 은 Retry-After 0 일 때만 다시 보낸다")
    func serviceUnavailableRetry() async throws {
        let plain = StubServer(status: 503)
        await #expect(throws: HttpException.self) {
            _ = try await RestConfigApi(rest: try plain.rest()).getConfig()
        }
        #expect(plain.requests.count == 1)

        let later = StubServer(status: 503, headers: ["Retry-After": "120"])
        await #expect(throws: HttpException.self) {
            _ = try await RestConfigApi(rest: try later.rest()).getConfig()
        }
        #expect(later.requests.count == 1)

        let immediate = StubServer(status: 503, headers: ["Retry-After": "0"])
        await #expect(throws: HttpException.self) {
            _ = try await RestConfigApi(rest: try immediate.rest()).getConfig()
        }
        #expect(immediate.requests.count == 2)
    }

    // MARK: - 세션 설정

    @Test("타임아웃은 원본 값이고 SSE 는 유한값이다")
    func timeouts() throws {
        let stub = StubServer()
        let apis = try makeApis(stub)

        let api = try #require(apis.user as? RestUserApi)
        #expect(api.rest.client.session.configuration.timeoutIntervalForRequest == 20)
        #expect(apis.streamClient.session.configuration.timeoutIntervalForRequest == 45)
        #expect(NetworkModule.SSE_READ_TIMEOUT_SECONDS == 45)
        #expect(apis.imageClient.configuration.timeoutIntervalForRequest == 15)
        // 상시 연결이라 읽기 타임아웃을 끈다.
        #expect(apis.socketClient.configuration.timeoutIntervalForRequest > 86_400)
        #expect(NetworkModule.SOCKET_PING_INTERVAL_SECONDS == 20)
        #expect(NetworkModule.SOCKET_CONNECT_TIMEOUT_SECONDS == 10)
    }

    @Test("API 세션은 쿠키도 캐시도 쓰지 않고 이미지 세션만 캐시를 쓴다")
    func sessionPolicies() throws {
        let stub = StubServer()
        let apis = try makeApis(stub)
        let api = try #require(apis.user as? RestUserApi)

        for session in [api.rest.client.session, apis.streamClient.session, apis.socketClient] {
            #expect(session.configuration.httpCookieStorage == nil)
            #expect(!session.configuration.httpShouldSetCookies)
            #expect(session.configuration.urlCache == nil)
            #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        }
        #expect(apis.imageClient.configuration.httpCookieStorage == nil)
        #expect(apis.imageClient.configuration.urlCache?.diskCapacity == 32 * 1024 * 1024)
    }

    @Test("인증 API 와 도메인 API 는 커넥션을 나눠 쓴다")
    func clientsShareSession() throws {
        let stub = StubServer()
        let apis = try makeApis(stub)
        let auth = try #require(apis.auth as? RestAuthApi)
        let user = try #require(apis.user as? RestUserApi)

        #expect(auth.rest.client.session === user.rest.client.session)
    }

    @Test("다른 출처로 가는 리다이렉트에는 Authorization 을 넘기지 않는다")
    func redirectStripsAuthorization() {
        var request = URLRequest(url: URL(string: "https://evil.example/x")!)
        request.setValue("Bearer a", forHTTPHeaderField: "Authorization")

        let otherHost = HttpRedirectDelegate.redirected(request, from: URL(string: "https://api.moyeota.co.kr/y"))
        #expect(otherHost.value(forHTTPHeaderField: "Authorization") == nil)

        let sameOrigin = HttpRedirectDelegate.redirected(request, from: URL(string: "https://evil.example/y"))
        #expect(sameOrigin.value(forHTTPHeaderField: "Authorization") == "Bearer a")

        let otherPort = HttpRedirectDelegate.redirected(request, from: URL(string: "https://evil.example:8443/y"))
        #expect(otherPort.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - 로깅

    private final class LogLines: Sendable {
        private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        var all: [String] { lines.withLock { $0 } }
        func append(_ line: String) { lines.withLock { $0.append(line) } }
    }

    /// 켜지면 채팅 메시지와 인증 토큰이 로그에 남는다 — 릴리즈에서는 반드시 꺼져야 한다.
    @Test("debugLogging 이 꺼져 있으면 아무것도 남기지 않는다")
    func loggingOff() async throws {
        let stub = StubServer(status: 200, body: #"{"accessToken":"secret.a","refreshToken":"secret.r"}"#)
        let log = LogLines()

        let apis = try makeApis(stub, debugLogging: false, logSink: { log.append($0) })
        _ = try await apis.auth.login(request: LoginRequestDto(loginId: "a", password: "pw"))
        _ = try? await apis.user.getMyProfile()

        #expect(log.all.isEmpty)
    }

    @Test("debugLogging 이 켜져 있으면 요청과 응답 본문을 남긴다")
    func loggingOn() async throws {
        let stub = StubServer(status: 200, body: #"{"exists":false}"#)
        let log = LogLines()

        let apis = try makeApis(stub, debugLogging: true, logSink: { log.append($0) })
        _ = try await apis.auth.checkNickname(request: NicknameCheckRequestDto(nickname: "모여타"))

        #expect(log.all.first == "--> POST \(stub.url("api/v1/auth/nickname/check"))")
        #expect(log.all.contains(#"{"nickname":"모여타"}"#))
        #expect(log.all.contains { $0.hasPrefix("<-- 200 ") })
        #expect(log.all.contains(#"{"exists":false}"#))
    }

    /// 로깅이 인증 인터셉터 바깥이라 원본과 같이 Bearer 를 찍지 않는다.
    @Test("요청 로그에는 인터셉터가 붙인 Bearer 가 없다")
    func loggingBeforeAuthHeader() async throws {
        let stub = StubServer(status: 200, body: "{}")
        let log = LogLines()

        let apis = try makeApis(stub, debugLogging: true, logSink: { log.append($0) })
        _ = try? await apis.user.getMyProfile()

        #expect(stub.requests.first?.header("Authorization") == "Bearer live.access")
        #expect(!log.all.contains { $0.contains("live.access") })
    }

    @Test("이미지 세션은 debugLogging 이 켜져 있어도 로그를 남기지 않는다")
    func imagesAreNotLogged() async throws {
        let stub = StubServer(status: 200, body: "png")
        let log = LogLines()

        let apis = try makeApis(stub, debugLogging: true, logSink: { log.append($0) })
        _ = try await apis.imageClient.data(from: URL(string: stub.url("a.png"))!)

        #expect(log.all.isEmpty)
    }

    // MARK: - SSE

    private func eventsRequest(_ stub: StubServer) -> URLRequest {
        var request = URLRequest(url: URL(string: stub.url("api/v1/matching/rooms/7/events"))!)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    @Test("SSE 는 2xx 면 본문을 바이트로 흘린다")
    func streamBytes() async throws {
        let stub = StubServer(status: 200, body: "event: connected\ndata: {}\n\n")

        let response = try await makeApis(stub).streamClient.stream(eventsRequest(stub))

        #expect(response.code == 200)
        #expect(stub.requests.first?.header("Accept") == "text/event-stream")
        #expect(stub.requests.first?.header("Authorization") == "Bearer live.access")
        let bytes = try #require(response.bytes)
        var received = Data()
        for try await byte in bytes { received.append(byte) }
        #expect(String(decoding: received, as: UTF8.self) == "event: connected\ndata: {}\n\n")
    }

    @Test("SSE 도 401 이면 재발급 후 다시 붙는다")
    func streamRefreshes() async throws {
        let stub = rotatingServer(body: "data: x\n\n")
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")

        let response = try await makeApis(stub, tokens: tokens).streamClient.stream(eventsRequest(stub))

        #expect(response.code == 200)
        #expect(response.priorResponse?.code == 401)
        #expect(response.bytes != nil)
        #expect(tokens.accessToken == "new.access")
    }

    /// 403 과 404 는 다시 붙지 않는다 — 호출부가 상태 코드로 가른다. 원본 okhttp-sse 처럼 본문은 읽지 않는다
    /// (`PartyEventSourceTest` 의 「본문이 도중에 멈춰도」 테스트들이 그 이유다).
    @Test("SSE 가 2xx 가 아니면 던지지 않고 본문을 읽지 않은 채 상태를 돌려준다")
    func streamFailureStatus() async throws {
        let stub = StubServer(status: 403, body: #"{"code":"NOT_MEMBER"}"#)

        let response = try await makeApis(stub).streamClient.stream(eventsRequest(stub))

        #expect(response.code == 403)
        #expect(response.bytes == nil)
        #expect(response.body.isEmpty)
    }
}
