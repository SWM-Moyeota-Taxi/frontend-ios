let HEADER_AUTHORIZATION = "Authorization"
let BEARER_PREFIX = "Bearer "

/// 모든 요청에 `Authorization: Bearer {access}` 를 붙인다.
///
/// 토큰이 없으면(미로그인) 헤더 없이 그냥 보낸다. 다만 **이제 그런 요청은 반드시 401 이다** —
/// 서버가 Spring Security 로 넘어가면서 `/api/v1/auth/` 하위를 뺀 전 경로가 인증 필수가 됐고,
/// 예전에 열려 있던 목록·장소 조회도 마찬가지다.
/// 헤더 없이 보내는 건 "서버가 401 로 명확히 답하게 두는" 선택이며,
/// 그 401 은 `TokenAuthenticator` 가 재발급으로 풀지 못하므로(재시도할 토큰 자체가 없다)
/// 화면 에러로 올라간다. 즉 이 인터셉터는 미로그인 호출을 구제하지 않는다 — 화면이 막아야 한다.
///
/// 인증 엔드포인트(가입/로그인/재발급/로그아웃)는 이 인터셉터가 없는 별도 클라이언트를 쓴다
/// (`NetworkModule` 참조).
public struct AuthHeaderInterceptor: Interceptor {
    private let tokens: any TokenHolder

    public init(tokens: any TokenHolder) {
        self.tokens = tokens
    }

    public func intercept(chain: InterceptorChain) async throws -> HttpRawResponse {
        let request = chain.request
        // 이미 붙어 있으면 건드리지 않는다.
        if request.value(forHTTPHeaderField: HEADER_AUTHORIZATION) != nil {
            return try await chain.proceed(request)
        }

        guard let accessToken = await tokens.currentAccessToken() else {
            return try await chain.proceed(request)
        }

        var authorized = request
        authorized.setValue(BEARER_PREFIX + accessToken, forHTTPHeaderField: HEADER_AUTHORIZATION)
        return try await chain.proceed(authorized)
    }
}
