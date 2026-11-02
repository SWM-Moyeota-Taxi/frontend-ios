import Foundation
import MoyeotaDomain
import os

/// 401 을 만나면 리프레시로 재발급하고 원요청을 **한 번** 재시도한다.
///
/// 설계 포인트 세 가지.
/// 1. **경합 시 재발급은 한 번만.** 서버가 회전(rotation) 방식이라 두 요청이 같은 리프레시로
///    동시에 재발급하면 늦은 쪽이 "이미 회전됨" 401 을 맞고 멀쩡한 세션이 날아간다.
///    그래서 갱신 구간 전체를 순서대로 하나씩만 돌리고, 차례가 왔을 때 토큰이 이미 바뀌어 있으면
///    (= 앞선 요청이 갱신을 끝냈으면) 재발급하지 않고 그 토큰으로 바로 재시도한다.
/// 2. **세션 만료는 서버가 거절했을 때만 알린다.** `RefreshResult.rejected` 면
///    `TokenHolder.onSessionExpired` 가 authState 를 unauthenticated 로 바꾸고, presentation 이
///    그걸 보고 로그인 화면으로 보낸다. 반대로 `RefreshResult.unavailable` — 즉 **답을 못 받은 경우**
///    에는 세션을 건드리지 않는다. 예전에는 둘을 구분하지 않아, 지하철에서 토큰이 만료되거나 배포 중
///    503 을 맞은 멀쩡한 사용자가 로그인 화면으로 쫓겨났다(근거는 `RefreshResult` 주석).
/// 3. **재시도는 1회.** 새 토큰으로도 401 이면 재발급으로 풀릴 문제가 아니다(권한 없음 등).
///    무한 루프 대신 401 을 호출부로 올려보낸다.
///
/// 이 Authenticator 는 인증 엔드포인트에는 달지 않는다 — 재발급 자체가 재발급을 부르면 안 된다.
public final class TokenAuthenticator: Authenticator {
    private let tokens: any TokenHolder
    private let refresher: any TokenRefresher

    /// 원본 `synchronized(this)` 의 자리. 앞선 구간이 끝나야 다음 구간이 시작한다.
    /// 부른 태스크의 취소를 물려받지 않는 별도 태스크로 돌린다 — 근거는 `HttpClient.followUpRequest` 주석.
    private let lastCriticalSection = OSAllocatedUnfairLock<Task<String?, Never>?>(initialState: nil)

    private static let MAX_RETRY = 1

    public init(tokens: any TokenHolder, refresher: any TokenRefresher) {
        self.tokens = tokens
        self.refresher = refresher
    }

    public func authenticate(response: HttpRawResponse) async -> URLRequest? {
        // 애초에 토큰을 안 실은 요청의 401 은 재발급으로 풀 수 없다(미로그인 상태의 보호 API 접근).
        guard let failedAccessToken = bearerToken(of: response.request) else { return nil }

        if retryCount(of: response) >= Self.MAX_RETRY { return nil }

        let task = lastCriticalSection.withLock { last -> Task<String?, Never> in
            let previous = last
            let next = Task { [self] () -> String? in
                _ = await previous?.value
                return await resolveAccessToken(failedAccessToken: failedAccessToken)
            }
            last = next
            return next
        }
        guard let newAccessToken = await task.value else { return nil }

        var retry = response.request
        retry.setValue(BEARER_PREFIX + newAccessToken, forHTTPHeaderField: HEADER_AUTHORIZATION)
        return retry
    }

    private func resolveAccessToken(failedAccessToken: String) async -> String? {
        let current = await tokens.currentAccessToken()
        // 앞선 요청이 이미 갱신을 끝냈다 — 재발급 없이 새 토큰으로 재시도한다.
        if let current, current != failedAccessToken { return current }

        guard let refreshToken = await tokens.currentRefreshToken() else {
            tokens.onSessionExpired()
            return nil
        }

        switch await refresher.refresh(refreshToken: refreshToken) {
        case .rotated(let refreshed):
            tokens.onTokensRefreshed(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken)
            return refreshed.accessToken

        // 서버가 "이 리프레시는 못 쓴다"고 답했다 — 재로그인 외에 길이 없다.
        case .rejected:
            // 사용자를 로그인 화면으로 쫓아내는 **유일한** 경로다. 정상 만료(14일)로도
            // 오지만, 회전 버그나 서버 계약 변경으로 터질 때도 여기로 온다 — 둘을 앱에서
            // 가를 수 없으므로 건수 추이로 본다. 평소보다 치솟으면 그게 신호다.
            // 토큰 값은 넘기지 않는다(예외를 새로 만들어 종류만 남긴다).
            // 이 예외는 취소가 아니므로 report 가 던질 일이 없다.
            try? Diagnostics.report(
                site: .tokenRefreshRejected,
                throwable: IllegalStateException("refresh rejected by server")
            )
            tokens.onSessionExpired()
            return nil

        // 답을 못 받았을 뿐이다. 세션을 **비우지 않고** 401 을 호출부로 올려보낸다 —
        // 리프레시는 14일 수명 그대로 유효하므로 다음 요청이 재발급을 다시 시도한다.
        case .unavailable:
            return nil
        }
    }

    private func bearerToken(of request: URLRequest) -> String? {
        guard let header = request.value(forHTTPHeaderField: HEADER_AUTHORIZATION),
              header.hasPrefix(BEARER_PREFIX)
        else { return nil }
        let token = String(header.dropFirst(BEARER_PREFIX.count))
        return token.isBlank ? nil : token
    }

    // HttpClient 는 재시도의 앞선 응답을 priorResponse 로 이어 붙인다.
    private func retryCount(of response: HttpRawResponse) -> Int {
        var count = 0
        var prior = response.priorResponse
        while let current = prior {
            count += 1
            prior = current.priorResponse
        }
        return count
    }
}
