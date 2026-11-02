/// 경로 기준: user/interfaces/AuthController.java (@RequestMapping("/api/v1/auth")).
/// 앱이 쓰는 인증 엔드포인트가 **전부 이 한 컨트롤러로 모였다** — 가입·로그인이 `/api/v1/users*` 에 있던
/// 이전 배치는 사라졌다(실측: `POST /api/v1/users/login` → 401, Security 가 보호 경로로 잡는다).
///
/// 이 프리픽스가 Security 의 사실상 유일한 permitAll 구간이기도 하다 — 현행 `SecurityConfig` 가 열어 두는 건
/// `/api/v1/auth/` 하위 전체, `/api/v1/config`, `/ws-chat/` 하위 전체, 그리고 운영 점검 경로
/// (`/health`·`/prometheus`·`/info`)뿐이고 나머지는 `anyRequest().authenticated()` 다.
/// 즉 **여기 말고는 토큰 없이 부를 수 있는 도메인 API 가 없다.**
///
/// 예전 목록에 있던 `/api/v1/local/users` 는 열린 경로가 아니다 — 그 가입 엔드포인트 자체가 삭제됐고
/// (`LocalUserController` 에는 이제 토큰이 필요한 `GET /users/info` 만 남았다) permitAll 목록에서도 빠졌다.
/// 문자 인증 두 경로가 `/api/v1/auth/sms/...` 인 것도 이 구간에 들어오기 위한 것이다.
///
/// **이 API 는 Bearer 헤더도, 401 재발급도 붙지 않은 별도 클라이언트로 만든다**
/// (`NetworkModule.create` 참조). 그렇게 하지 않으면 재발급이 실패했을 때 재발급 요청 자체가
/// 다시 재발급을 트리거해 무한 루프에 빠진다.
public protocol AuthApi: Sendable {

    /// 문자 인증번호 발송. **204 No Content** — 본문이 없어 반환값이 없다(`logout` 과 같은 모양이다).
    ///
    /// 경로 기준: `user/verification/presentation/SmsVerificationController.java`
    /// (`@RequestMapping("/api/v1/auth/sms")` + `@ResponseStatus(NO_CONTENT)`).
    /// **컨트롤러가 `/api/v1/auth` 하위라는 게 중요하다** — Security 의 permitAll 구간이 그 프리픽스라
    /// 가입 전(무토큰)에 부를 수 있고, 그래서 이 메서드가 `AuthApi` 에 있어야 한다.
    func sendSmsCode(request: SmsSendRequestDto) async throws

    /// 문자 인증번호 확인. 200 `{"verificationToken":"<uuid>"}`.
    ///
    /// 성공 시 서버가 인증번호를 지우므로 **같은 코드로 두 번 성공할 수 없다**
    /// — 두 번째는 400 `USER204`(저장된 코드 없음)다.
    func verifySmsCode(request: SmsVerifyRequestDto) async throws -> SmsVerifyResponse

    /// 201. 성공해도 토큰은 없다(uuid 만) — 가입 직후 `login` 을 이어서 불러야 한다.
    ///
    /// **`RegisterRequestDto.verificationToken` 이 필수다**(2026-10 서버 변경).
    /// 서버가 중복 검사보다 **먼저** 토큰을 확인하므로(`LocalUserService.register` 첫 줄),
    /// 토큰이 틀리면 아이디·닉네임이 멀쩡해도 400 `USER207` 로 끝난다.
    func register(request: RegisterRequestDto) async throws -> RegisterResponse

    /// 200 / 401 `USER102`.
    ///
    /// 응답은 재발급과 **똑같은 `TokenResponse` 다** — 예전에 있던 `userId` 필드가 사라졌다.
    /// 사용자 UUID 는 액세스 토큰의 `sub` 클레임에서 읽는다(`jwtSubject`).
    func login(request: LoginRequestDto) async throws -> TokenResponse

    /// 200 / 401 UNAUTHORIZED. 회전 방식이라 성공 응답의 refreshToken 까지 저장해야 한다.
    ///
    /// 여기서만 `Response` 를 돌려준다(원본의 `Call.execute()` 자리) — 상태 코드와 에러 본문을 재발급 쪽이
    /// 직접 판정해야 하기 때문이다(`RetrofitTokenRefresher`). 전송 실패와 2xx 본문 파싱 실패만 던진다.
    func reissue(request: RefreshTokenRequestDto) async throws -> Response<TokenResponse>

    /// 204 No Content, 멱등. 이미 무효화된 리프레시를 보내도 성공한다.
    func logout(request: RefreshTokenRequestDto) async throws

    /// 가입 폼의 닉네임 중복 확인. 200 `{"exists":boolean}`.
    ///
    /// **`/api/v1/users` 가 아니라 여기(auth 프리픽스)에 있는 게 핵심이다.** 이 호출은 가입 도중,
    /// 즉 로그인 전에 일어나므로 토큰이 없다. auth 구간만 permitAll 이라 경로도 이쪽이어야 하고,
    /// 클라이언트도 Bearer 가 붙지 않는 이 API 여야 한다 — 만료된 토큰이 세션에 남아 있는 상태에서
    /// 인증 클라이언트로 보내면 permitAll 경로인데도 JWT 필터에 걸려 401 이 날 수 있다.
    ///
    /// 형식이 틀리면 exists 판정 전에 400 `USER107` 이다(서버가 `Nickname` VO 를 먼저 만든다).
    func checkNickname(request: NicknameCheckRequestDto) async throws -> NicknameCheckResponse

    /// 전화번호 가입 여부 확인. 200 `{"exists":boolean}`.
    ///
    /// `checkNickname` 과 같은 이유로 이 API(Bearer 미부착)에 있다 — 가입 도중 호출이라 토큰이 없고,
    /// **깨진 토큰을 실으면 permitAll 경로인데도 JWT 필터가 401 `USER001` 을 낸다**
    /// (실측 2026-11-01, 로컬 :8080 — 헤더 없음 200 / 유효 토큰 200 / `Bearer not.a.jwt` 401).
    /// 인증 클라이언트로 보내면 **세션이 만료된 사용자가 가입을 다시 시도할 때만** 나는 결함이 된다.
    ///
    /// 형식이 틀리면 exists 판정 전에 400 `USER105` 다(서버가 `PhoneNumber` VO 를 먼저 만든다).
    /// 발송(`sendSmsCode`)은 같은 상황에서 `@Pattern` 에 먼저 걸려 `INVALID_REQUEST` 가 오므로
    /// **두 경로의 형식 오류 코드가 다르다** — 에러 매핑에서 헷갈리기 쉽다.
    ///
    /// **`exists=false` 를 「가입 가능」으로 읽지 마라.** 탈퇴한 번호도 false 다
    /// (`PhoneCheckResponse` 주석 참조) — 이 호출은 막는 데만 쓴다.
    func checkPhone(request: PhoneCheckRequestDto) async throws -> PhoneCheckResponse
}

enum AuthApiRoute: String, CaseIterable, ApiRouteSet {
    case sendSmsCode, verifySmsCode, register, login, reissue, logout, checkNickname, checkPhone

    var route: ApiRoute {
        switch self {
        case .sendSmsCode: .POST("api/v1/auth/sms/send")
        case .verifySmsCode: .POST("api/v1/auth/sms/verify")
        case .register: .POST("api/v1/auth/register")
        case .login: .POST("api/v1/auth/login")
        case .reissue: .POST("api/v1/auth/reissue")
        case .logout: .POST("api/v1/auth/logout")
        case .checkNickname: .POST("api/v1/auth/nickname/check")
        case .checkPhone: .POST("api/v1/auth/phone/check")
        }
    }
}

struct RestAuthApi: AuthApi {
    let rest: RestClient

    func sendSmsCode(request: SmsSendRequestDto) async throws {
        try await rest.callUnit(AuthApiRoute.sendSmsCode.route, body: request)
    }

    func verifySmsCode(request: SmsVerifyRequestDto) async throws -> SmsVerifyResponse {
        try await rest.call(AuthApiRoute.verifySmsCode.route, body: request)
    }

    func register(request: RegisterRequestDto) async throws -> RegisterResponse {
        try await rest.call(AuthApiRoute.register.route, body: request)
    }

    func login(request: LoginRequestDto) async throws -> TokenResponse {
        try await rest.call(AuthApiRoute.login.route, body: request)
    }

    func reissue(request: RefreshTokenRequestDto) async throws -> Response<TokenResponse> {
        try await rest.response(AuthApiRoute.reissue.route, body: request)
    }

    func logout(request: RefreshTokenRequestDto) async throws {
        try await rest.callUnit(AuthApiRoute.logout.route, body: request)
    }

    func checkNickname(request: NicknameCheckRequestDto) async throws -> NicknameCheckResponse {
        try await rest.call(AuthApiRoute.checkNickname.route, body: request)
    }

    func checkPhone(request: PhoneCheckRequestDto) async throws -> PhoneCheckResponse {
        try await rest.call(AuthApiRoute.checkPhone.route, body: request)
    }
}
