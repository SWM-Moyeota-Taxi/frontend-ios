import Foundation
import Testing
@testable import MoyeotaData

@Suite struct TokenAuthenticatorTest {
    private static let threadCount = 4

    private func rotated(_ accessToken: String, _ refreshToken: String) -> RefreshResult {
        .rotated(tokens: TokenPair(accessToken: accessToken, refreshToken: refreshToken))
    }

    private func unauthorized(_ accessToken: String?, prior: HttpRawResponse? = nil) -> HttpRawResponse {
        var request = URLRequest(url: URL(string: "http://localhost:8080/api/v1/matching/rooms")!)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return HttpRawResponse(request: request, code: 401, priorResponse: prior)
    }

    @Test("401 이면 재발급한 액세스 토큰으로 원요청을 재시도한다")
    func retriesWithNewToken() async throws {
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")
        let refresher = FakeRefresher(rotated("new.access", "new.refresh"))

        let retry = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: unauthorized("old.access"))

        let request = try #require(retry, "재시도 요청이 만들어져야 한다")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new.access")
        // 경로/메서드는 원요청 그대로여야 한다.
        #expect(request.url?.absoluteString == "http://localhost:8080/api/v1/matching/rooms")
        #expect(request.httpMethod == "GET")
        #expect(refresher.usedRefreshTokens == ["old.refresh"])
    }

    @Test("재발급 성공 시 회전된 리프레시까지 저장한다")
    func storesRotatedRefresh() async {
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")
        let refresher = FakeRefresher(rotated("new.access", "new.refresh"))

        _ = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: unauthorized("old.access"))

        #expect(tokens.accessToken == "new.access")
        // 옛 리프레시는 서버에서 이미 무효화됐다 — 저장하지 않으면 다음 재발급이 401 이다.
        #expect(tokens.refreshToken == "new.refresh")
        #expect(tokens.sessionExpiredCount == 0)
    }

    /// 서버가 "이 리프레시는 못 쓴다"고 답한 경우(401·403·USER001~005). 재로그인 외에 길이 없다.
    @Test("서버가 재발급을 거절하면 세션 만료를 알리고 재시도를 포기한다")
    func rejectedExpiresSession() async {
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "revoked.refresh")
        let refresher = FakeRefresher(.rejected)

        let retry = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: unauthorized("old.access"))

        #expect(retry == nil)
        #expect(tokens.sessionExpiredCount == 1)
        #expect(tokens.accessToken == nil)
        #expect(tokens.refreshToken == nil)
    }

    /// **이 테스트가 이번 수정의 핵심이다.** 운영 액세스 토큰 수명이 30분이라 활성 사용자는 30분마다
    /// 반드시 재발급을 한 번 타는데, 그 순간 지하철·엘리베이터에 있거나 서버 배포 중 503 을 맞으면
    /// 예전 구현은 「응답을 못 받았다」를 「서버가 거절했다」와 똑같이 보고 멀쩡한 세션을 지웠다
    /// — 서버에서는 아무 일도 없었고 리프레시는 14일 수명 그대로 유효한데 「세션이 만료됐어요」가 떴다.
    ///
    /// 세션을 유지한 채 null 을 돌려주면 401 이 호출부로 올라가고, 다음 요청이 재발급을 다시 시도한다.
    @Test("재발급 응답을 못 받으면 세션을 유지한 채 재시도만 포기한다")
    func unavailableKeepsSession() async {
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "live.refresh")
        let refresher = FakeRefresher(.unavailable)

        let retry = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: unauthorized("old.access"))

        #expect(retry == nil, "답을 못 받았으면 재시도할 토큰이 없다")
        #expect(tokens.sessionExpiredCount == 0, "네트워크 실패로 세션을 지웠다")
        // 다음 요청이 같은 리프레시로 재발급을 다시 시도할 수 있어야 한다.
        #expect(tokens.accessToken == "old.access")
        #expect(tokens.refreshToken == "live.refresh")
    }

    @Test("리프레시 토큰이 없으면 재발급을 시도하지 않고 세션을 만료시킨다")
    func noRefreshExpires() async {
        let tokens = FakeTokenHolder(accessToken: "orphan.access", refreshToken: nil)
        let refresher = FakeRefresher(rotated("new.access", "new.refresh"))

        let retry = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: unauthorized("orphan.access"))

        #expect(retry == nil)
        #expect(refresher.callCount == 0)
        #expect(tokens.sessionExpiredCount == 1)
    }

    @Test("토큰을 싣지 않은 요청의 401 은 건드리지 않는다")
    func noTokenLeftAlone() async {
        let tokens = FakeTokenHolder(accessToken: "any.access", refreshToken: "any.refresh")
        let refresher = FakeRefresher(rotated("new.access", "new.refresh"))

        // 미로그인 상태에서 보호 API 를 호출한 경우 — 재발급으로 풀 수 있는 문제가 아니다.
        let retry = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: unauthorized(nil))

        #expect(retry == nil)
        #expect(refresher.callCount == 0)
        #expect(tokens.sessionExpiredCount == 0)
    }

    @Test("새 토큰으로도 401 이면 무한 루프 대신 포기한다")
    func secondFailureGivesUp() async {
        let tokens = FakeTokenHolder(accessToken: "new.access", refreshToken: "old.refresh")
        let refresher = FakeRefresher(rotated("newer.access", "newer.refresh"))
        let secondFailure = unauthorized("new.access", prior: unauthorized("old.access"))

        let retry = await TokenAuthenticator(tokens: tokens, refresher: refresher)
            .authenticate(response: secondFailure)

        #expect(retry == nil)
        #expect(refresher.callCount == 0)
    }

    @Test("동시에 401 을 맞아도 재발급은 한 번만 일어난다")
    func concurrentRefreshOnce() async {
        let tokens = FakeTokenHolder(accessToken: "old.access", refreshToken: "old.refresh")
        // 재발급이 느린 상황을 만들어 뒤따르는 요청이 반드시 차례를 기다리게 한다.
        let refresher = FakeRefresher(rotated("new.access", "new.refresh"), delay: .milliseconds(200))
        let authenticator = TokenAuthenticator(tokens: tokens, refresher: refresher)

        let retries = await withTaskGroup(of: URLRequest?.self) { group in
            for _ in 0..<Self.threadCount {
                let response = unauthorized("old.access")
                group.addTask { await authenticator.authenticate(response: response) }
            }
            var collected: [URLRequest?] = []
            for await retry in group { collected.append(retry) }
            return collected
        }

        // 서버가 회전 방식이라 두 번 재발급하면 늦은 쪽이 "이미 회전됨" 401 을 맞고 세션이 날아간다.
        #expect(refresher.callCount == 1)
        #expect(retries.count == Self.threadCount)
        // 재발급하지 않은 요청도 갱신된 토큰을 받아 정상 재시도해야 한다.
        for retry in retries {
            #expect(retry?.value(forHTTPHeaderField: "Authorization") == "Bearer new.access")
        }
        #expect(tokens.sessionExpiredCount == 0)
    }
}
