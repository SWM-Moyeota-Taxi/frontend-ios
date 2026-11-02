import Foundation
import Testing
@testable import MoyeotaData

/// `RetrofitTokenRefresher` 가 **「서버가 거절했다」와 「답을 못 받았다」를 가르는지**를 확인한다.
///
/// ### 왜 이 테스트가 있어야 하는가
/// 이 판정이 틀리면 세션이 조용히 날아간다. 운영 액세스 토큰 수명이 30분이라 활성 사용자는 30분마다
/// 반드시 이 코드를 한 번 타고, 그 순간 지하철·엘리베이터·셀↔와이파이 전환이나 서버 배포 중
/// 503(ALB 가 **HTML 본문**을 준다)·429 를 맞을 수 있다. 전부 `.unavailable` 이어야
/// 하는데 `.rejected` 로 떨어지면 **서버에서는 아무 일도 없었는데** 사용자가
/// 로그인 화면으로 쫓겨난다. 반대로 진짜 401 을 unavailable 로 보면 401 루프가 된다.
@Suite struct RetrofitTokenRefresherTest {

    /// 정해진 응답 하나를 돌려주는 `AuthApi`. `contentType` 은 503 의 HTML 본문을 흉내 내는 데 쓴다.
    private func refresher(
        status: Int,
        body: String,
        contentType: String = "application/json"
    ) throws -> RetrofitTokenRefresher {
        let stub = StubServer(status: status, body: body, headers: ["Content-Type": contentType])
        return RetrofitTokenRefresher(authApi: RestAuthApi(rest: try stub.rest()))
    }

    /// 응답 대신 예외를 던지는 변종 — 연결 실패·타임아웃을 재현한다.
    private func failingRefresher(_ failure: URLError) throws -> RetrofitTokenRefresher {
        let stub = StubServer { _ in StubResponse(failure: failure) }
        return RetrofitTokenRefresher(authApi: RestAuthApi(rest: try stub.rest()))
    }

    @Test("200 이면 회전된 토큰 쌍을 돌려준다")
    func okRotates() async throws {
        let result = try await refresher(
            status: 200,
            body: #"{"accessToken":"new.access","refreshToken":"new.refresh"}"#
        ).refresh(refreshToken: "old.refresh")

        #expect(result == .rotated(tokens: TokenPair(accessToken: "new.access", refreshToken: "new.refresh")))
    }

    /// 401 은 만료·회전됨·재사용·로그아웃·탈퇴가 전부 섞여 있지만 대응은 하나다 — 재로그인.
    @Test("401 은 서버의 거절로 본다")
    func unauthorizedRejects() async throws {
        let result = try await refresher(
            status: 401,
            body: #"{"code":"USER002","message":"만료된 토큰입니다."}"#
        ).refresh(refreshToken: "expired.refresh")

        #expect(result == .rejected)
    }

    /// 403 도 "이 리프레시로는 안 된다"는 서버의 답이다.
    @Test("403 도 서버의 거절로 본다")
    func forbiddenRejects() async throws {
        let result = try await refresher(status: 403, body: "").refresh(refreshToken: "forbidden.refresh")

        #expect(result == .rejected)
    }

    /// 상태 코드가 401·403 이 아니어도 본문의 토큰 계열 코드(`USER001`~`USER005`)는 거절로 읽는다
    /// — 서버가 같은 뜻을 다른 상태로 감싸 보내는 경우까지 덮어 두려는 것이다.
    @Test("토큰 계열 에러 코드는 상태 코드와 무관하게 거절로 본다")
    func tokenErrorCodeRejects() async throws {
        let result = try await refresher(
            status: 400,
            body: #"{"code":"USER004","message":"이미 사용된 리프레시 토큰입니다."}"#
        ).refresh(refreshToken: "reused.refresh")

        #expect(result == .rejected)
    }

    /// **이 테스트가 가장 중요하다.** ALB 가 배포 중에 내보내는 503 은 본문이 JSON 이 아니라 HTML 이다.
    /// 파싱을 시도하다 예외가 나거나 이걸 거절로 오해하면, 서버 배포 한 번에 쓰고 있던 사용자 전원이
    /// 로그아웃된다.
    @Test("503 과 HTML 본문은 연결 불가로 본다")
    func htmlServiceUnavailable() async throws {
        let result = try await refresher(
            status: 503,
            body: "<html><head><title>503 Service Temporarily Unavailable</title></head></html>",
            contentType: "text/html"
        ).refresh(refreshToken: "live.refresh")

        #expect(result == .unavailable)
    }

    /// 429 는 "잠시 뒤 다시"다. 세션을 비울 근거가 전혀 없다.
    @Test("429 는 연결 불가로 본다")
    func tooManyRequests() async throws {
        let result = try await refresher(status: 429, body: "").refresh(refreshToken: "live.refresh")

        #expect(result == .unavailable)
    }

    /// 스프링이 직접 만든 404 는 본문에 code 가 없다 — 상태 코드만으로 판정해 연결 불가로 떨어진다.
    @Test("code 가 없는 비정상 응답은 연결 불가로 본다")
    func noCodeIsUnavailable() async throws {
        let result = try await refresher(status: 404, body: #"{"error":"Not Found","path":"/api/v1/auth/reissue"}"#)
            .refresh(refreshToken: "live.refresh")

        #expect(result == .unavailable)
    }

    /// 지하철·엘리베이터. 응답 자체를 못 받았으니 리프레시는 여전히 멀쩡하다.
    @Test("연결 실패는 연결 불가로 본다")
    func connectionFailure() async throws {
        let result = try await failingRefresher(URLError(.cannotConnectToHost)).refresh(refreshToken: "live.refresh")

        #expect(result == .unavailable)
    }

    @Test("읽기 타임아웃도 연결 불가로 본다")
    func readTimeout() async throws {
        let result = try await failingRefresher(URLError(.timedOut)).refresh(refreshToken: "live.refresh")

        #expect(result == .unavailable)
    }

    /// 200 인데 토큰이 비어 있으면 서버 계약 위반이다. 다시 물어도 같은 답이 오므로 재시도는 의미가
    /// 없고, 그 토큰을 저장하면 Bearer 가 빈 문자열인 요청이 나가 401 루프가 된다 — 재로그인으로 보낸다.
    @Test("200 인데 액세스 토큰이 비어 있으면 거절로 본다")
    func blankAccessToken() async throws {
        let result = try await refresher(
            status: 200,
            body: #"{"accessToken":"","refreshToken":"new.refresh"}"#
        ).refresh(refreshToken: "old.refresh")

        #expect(result == .rejected)
    }

    /// 회전 방식이라 리프레시가 비어 있어도 다음 재발급을 할 수 없다 — 같은 이유로 거절이다.
    @Test("200 인데 리프레시 토큰이 비어 있으면 거절로 본다")
    func blankRefreshToken() async throws {
        let result = try await refresher(
            status: 200,
            body: #"{"accessToken":"new.access","refreshToken":""}"#
        ).refresh(refreshToken: "old.refresh")

        #expect(result == .rejected)
    }

    /// 재발급 요청이 **리프레시 토큰을 본문에 싣는지**까지 본다. 여기가 비면 서버는 400 을 주고
    /// 모든 재발급이 영구히 실패한다 — 위의 분기 판정이 다 맞아도 소용이 없어진다.
    @Test("재발급 요청은 리프레시 토큰을 본문에 싣는다")
    func sendsRefreshTokenInBody() async throws {
        let stub = StubServer(status: 200, body: #"{"accessToken":"new.access","refreshToken":"new.refresh"}"#)
        let refresher = RetrofitTokenRefresher(authApi: RestAuthApi(rest: try stub.rest()))

        _ = await refresher.refresh(refreshToken: "old.refresh")

        let body = try #require(stub.requests.first?.bodyString)
        #expect(stub.requests.count == 1)
        #expect(body.contains("old.refresh"), "본문에 리프레시가 실리지 않았다: \(body)")
    }
}
