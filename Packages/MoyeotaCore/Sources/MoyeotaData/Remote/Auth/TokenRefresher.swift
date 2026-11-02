import MoyeotaDomain

/// 재발급으로 받은 새 토큰 쌍. 서버가 회전 방식이라 리프레시도 함께 바뀐다.
public struct TokenPair: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// 재발급 시도의 결과. **"실패"를 한 값으로 뭉개지 않는 것이 이 타입의 존재 이유다.**
///
/// 예전에는 `TokenPair?` 하나로 돌려줬는데, 그러면 「서버가 리프레시를 거절했다」와
/// 「서버에 닿지도 못했다」가 똑같이 null 이 되어 `TokenAuthenticator` 가 둘 다 세션 파기로 처리했다.
/// 운영 액세스 토큰 수명이 30분이라 활성 사용자는 30분마다 반드시 이 경로를 한 번 타는데,
/// 지하철·엘리베이터·셀↔와이파이 전환이나 배포 중 503(ALB 가 HTML 본문을 준다)·429 가 겹치면
/// **서버에서는 아무 일도 없었고 리프레시도 14일 수명 그대로 유효한데** 화면에
/// 「세션이 만료됐어요」가 떴다. 매칭 대기 중에는 SSE 재연결이 3초마다 같은 경로를 타므로
/// 노출이 반복된다.
public enum RefreshResult: Equatable, Sendable {
    /// 재발급 성공. 회전된 리프레시까지 저장해야 한다.
    case rotated(tokens: TokenPair)

    /// 서버가 리프레시를 명시적으로 거절했다 — 재로그인만이 답이다.
    case rejected

    /// 답을 못 받았다(네트워크·타임아웃·5xx·429). 세션은 멀쩡할 수 있으니 비우지 않는다.
    case unavailable
}

/// 리프레시 토큰으로 새 토큰 쌍을 받아오는 창구.
///
/// HTTP 를 몰라도 되도록 프로토콜로 분리해 두면 `TokenAuthenticator` 의 재시도·경합 로직을
/// 실제 HTTP 없이 단위 테스트할 수 있다.
public protocol TokenRefresher: Sendable {
    /// 성공·거절·연결 불가를 구분해 돌려준다 — 구분하는 이유는 `RefreshResult` 주석.
    func refresh(refreshToken: String) async -> RefreshResult
}

/// `AuthApi` 구현. **Bearer 인터셉터도 Authenticator 도 붙지 않은 클라이언트**의 `AuthApi` 를 받아야 한다
/// — 재발급 요청이 401 을 맞았을 때 다시 재발급을 트리거하면 무한 루프가 된다.
public struct RetrofitTokenRefresher: TokenRefresher {
    private let authApi: any AuthApi

    public init(authApi: any AuthApi) {
        self.authApi = authApi
    }

    public func refresh(refreshToken: String) async -> RefreshResult {
        // 응답 자체를 못 받은 경우(URLError·타임아웃·DNS)와 본문 파싱 실패가 여기로 떨어진다.
        // 둘 다 "서버의 답"이 아니므로 세션 판정의 근거가 될 수 없다.
        let response: Response<TokenResponse>
        do {
            response = try await authApi.reissue(request: RefreshTokenRequestDto(refreshToken: refreshToken))
        } catch {
            return .unavailable
        }

        if !response.isSuccessful { return toFailure(response) }

        // 2xx 인데 본문이 비어 있는 경우(204 등)는 서버 쪽 사고다. 거절로 단정하지 않고 다음 요청에
        // 다시 맡긴다 — 멀쩡한 세션을 날리는 쪽이 더 비싼 실수이고, 재시도는 MAX_RETRY 가 막는다.
        guard let body = response.body() else { return .unavailable }

        // 200 인데 토큰이 비었으면 서버 계약 위반이라 재시도해도 같은 답이 온다 — 재로그인으로 보낸다.
        if body.accessToken.isBlank || body.refreshToken.isBlank { return .rejected }

        return .rotated(tokens: TokenPair(accessToken: body.accessToken, refreshToken: body.refreshToken))
    }

    /// 비정상 응답을 「서버의 거절」과 「답을 못 받았다」로 가른다.
    ///
    /// 거절로 보는 것은 **401·403 과 토큰 계열 에러 코드**뿐이다. 401 들끼리는 사유를 구분하지 않는다
    /// — 만료·회전됨·용도불일치·재사용·로그아웃·탈퇴가 전부 "재로그인" 하나로 귀결되기 때문이다
    /// (`USER001`~`USER005`, 표는 `toAuthException` 주석).
    ///
    /// 나머지(429·5xx·503·404…)는 전부 `.unavailable` 이다. 서버가 "이 리프레시는
    /// 못 쓴다"고 말한 적이 없으므로 세션을 비울 근거가 못 된다.
    private func toFailure(_ response: Response<TokenResponse>) -> RefreshResult {
        if response.code() == Self.HTTP_UNAUTHORIZED || response.code() == Self.HTTP_FORBIDDEN { return .rejected }
        // 본문에서 code 를 못 읽었으면(HTML·빈 본문) 상태 코드만으로 판정한 셈이 된다.
        // 파싱 실패가 예외로 번지면 안 된다 — 503 은 ALB 가 만든 HTML 본문이고, 스프링이 직접 만든 404 는
        // 본문이 비어 있다. `decodeApiError` 가 그런 경우 null 로 떨어뜨린다.
        guard let errorCode = decodeApiError(errorBody: response.errorBody())?.code else { return .unavailable }
        return Self.REJECTING_ERROR_CODES.contains(errorCode) ? .rejected : .unavailable
    }

    private static let HTTP_UNAUTHORIZED = 401
    private static let HTTP_FORBIDDEN = 403

    /// 토큰 무효/만료/용도불일치/재사용/무토큰. 다섯 다 재로그인 외에 길이 없다.
    private static let REJECTING_ERROR_CODES: Set<String> = ["USER001", "USER002", "USER003", "USER004", "USER005"]
}
