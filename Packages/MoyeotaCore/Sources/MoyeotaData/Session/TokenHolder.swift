/// 인터셉터/Authenticator 가 보는 토큰 창구.
///
/// 원본은 OkHttp 인터셉터가 non-suspend 라 동기 창구였고 I/O 스레드를 잠깐 막는 것을 허용했다.
/// 이쪽 HTTP 계층은 전부 `async` 라 스레드를 막지 않고 기다린다 — 읽기 두 개가 `async` 인 이유다.
public protocol TokenHolder: Sendable {
    /// 미로그인이면 null. 앱 시작 직후라면 디스크 복원이 끝날 때까지 기다린 뒤 답한다.
    func currentAccessToken() async -> String?

    func currentRefreshToken() async -> String?

    /// 재발급 성공 — 회전된 리프레시까지 함께 갱신한다.
    func onTokensRefreshed(accessToken: String, refreshToken: String)

    /// 재발급 **거절**(서버가 "이 리프레시는 못 쓴다"고 답했다) 또는 리프레시 부재 —
    /// 세션을 비우고 로그아웃 상태로 전환한다.
    ///
    /// **네트워크·타임아웃·5xx 로 답을 못 받은 경우는 여기 오지 않는다.** 그건 세션을 비울 근거가
    /// 못 되기 때문이다(`RefreshResult` 주석에 사정을 적었다).
    func onSessionExpired()
}
