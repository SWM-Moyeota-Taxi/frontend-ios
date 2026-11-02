import MoyeotaDomain

extension LocalDate {
    /// 서버가 `Instant` 로 받는 birthDate 로 변환한다.
    ///
    /// UTC 자정을 쓰는 이유: 사용자가 고른 건 "날짜"뿐인데 로컬 타임존(KST, UTC+9)으로 자정을 잡으면
    /// 서버에 하루 전날(전날 15:00Z)로 저장된다. 타임존이 뭐든 같은 날짜가 유지되도록 UTC 로 고정한다.
    ///
    /// 결과 형식은 `2000-01-01T00:00:00Z` — 원본 `Instant.toString` 처럼 초까지 항상 찍는다.
    /// UTC 자정이라 달력을 거칠 일이 없어 날짜 문자열에 시각을 붙인다.
    func toBirthDateInstant() -> String {
        "\(toString())T00:00:00Z"
    }
}

extension NewUser {
    func toDto() -> RegisterRequestDto {
        RegisterRequestDto(
            loginId: loginId,
            password: password,
            // 서버가 앞뒤 공백을 strip 한 뒤 검사하므로 여기서 미리 다듬어 보낸다 — 저장되는 값도 같아진다.
            nickname: nickname.trim(),
            name: name,
            birthDate: birthDate.toBirthDateInstant(),
            // 발송·확인·가입 세 요청이 같은 형태를 쓴다 — 근거는 AuthPolicy.normalizePhoneNumber 주석.
            phoneNumber: AuthPolicy.normalizePhoneNumber(value: phoneNumber),
            gender: gender.name,
            email: email,
            verificationToken: verificationToken
        )
    }
}

extension Error {
    /// 전송 계층 예외를 `AuthException` 으로 좁힌다. presentation 이 HTTP 를 알 필요가 없게 하는 경계다.
    ///
    /// 서버 본문의 `code` 를 우선 보고, 없으면(스프링이 직접 만든 404 등) 상태 코드로 폴백한다
    /// — `ApiErrorDto` 주석대로 code 가 있어야 "서버가 의도한 에러"다.
    ///
    /// **코드 값이 이름에서 번호로 바뀌었다.** 인증 개편으로 서버 `UserErrorCode` 가
    /// `LOGIN_FAILED` 같은 enum 이름 대신 `USER102` 같은 고정 코드를 내보낸다(실측):
    ///
    /// | 코드 | 상태 | 뜻 |
    /// |---|---|---|
    /// | `USER001`~`USER005` | 401 | 토큰 무효/만료/용도불일치/재사용/무토큰 |
    /// | `USER101` | 409 | 아이디 중복 |
    /// | `USER102` | 401 | 로그인 실패 |
    /// | `USER103` | 404 | 사용자 없음 |
    /// | `USER104` | 409 | 전화번호 중복 |
    /// | `USER105` | 400 | 전화번호 형식 위반 |
    /// | `USER106` | 400 | FCM 토큰이 비어 있음 |
    /// | `USER107` | 400 | 닉네임 형식 위반 |
    /// | `USER108` | 409 | 닉네임 중복 |
    /// | `USER109` | 409 | 탈퇴한 번호의 재가입 제한 기간(30일) |
    /// | `USER110` | 409 | 진행 중인 합승이 있어 탈퇴 불가 |
    /// | `USER111` | 400 | 탈퇴 본인 확인 비밀번호 불일치 |
    /// | `USER112` | 400 | 제공하지 않는 프로필 이미지 키 |
    /// | `USER201` | 502 | 문자 발송 실패 |
    /// | `USER202` | 429 | 재발송 대기(1분) |
    /// | `USER203` | 429 | 하루 발송 한도(5회) 초과 |
    /// | `USER204` | 400 | 인증번호 만료/없음 |
    /// | `USER205` | 400 | 인증번호 불일치 |
    /// | `USER206` | 429 | 입력 시도(5회) 초과 |
    /// | `USER207` | 400 | 가입 토큰 무효(만료·소진·번호 불일치) |
    /// | `USER208` | 503 | 인증 저장소 장애 |
    /// | `INVALID_REQUEST` | 400 | 검증 실패 (이름 그대로 남았다) |
    ///
    /// **문자 인증 계열은 상태 코드 폴백으로는 전혀 갈리지 않는다** — 429 가 셋(`USER202`·`USER203`·`USER206`),
    /// 400 이 셋(`USER204`·`USER205`·`USER207`)이고 각각 화면의 대응이 다르다(재전송 카운트다운 /
    /// 재시도 포기 / 인증 단계로 되돌리기). 게다가 429 는 폴백 표에 아예 없어서 코드를 놓치면
    /// 전부 `AuthError.unknown` = "잠시 후 다시 시도해 주세요" 하나로 뭉쳐진다.
    ///
    /// 특히 **로그인 실패와 세션 만료가 둘 다 401** 이라 상태 코드 폴백만으로는 구분되지 않는다
    /// — `USER102` 를 놓치면 아이디/비밀번호 오류에 "다시 로그인해 주세요"가 뜬다.
    ///
    /// 같은 이유로 **409 는 다섯 가지 뜻을 갖는다** — 아이디(`USER101`)·전화번호(`USER104`)·닉네임(`USER108`)
    /// 중복에, 탈퇴 계열 둘(`USER109` 재가입 제한 · `USER110` 진행 중 합승)이 2026-10 에 더해졌다.
    /// 가입 쪽 셋은 서버 검사 순서가 loginId → phoneNumber → nickname 이라 하나만 올라오고,
    /// 코드를 놓치고 상태 코드로 폴백하면 무엇이 겹쳤든 "이미 사용 중인 아이디예요"가 떠서
    /// 사용자가 아이디만 계속 바꾸게 된다. **탈퇴 화면에서는 그 폴백이 더 나쁘다** — 아이디를 입력한 적도
    /// 없는 화면에 아이디 중복 안내가 뜬다.
    func toAuthException() -> AuthException {
        if let failure = self as? AuthException { return failure }

        if let http = self as? HttpException {
            let body = http.readApiError()
            let error: AuthError
            switch body?.code {
            case "USER102": error = .loginFailed
            case "USER101": error = .loginIdDuplicated
            case "USER104": error = .phoneNumberDuplicated
            case "USER105": error = .invalidPhoneNumber
            case "USER107": error = .invalidNickname
            case "USER108": error = .nicknameDuplicated
            // 탈퇴 계열(2026-10, Backend #206). 셋 다 화면 대응이 서로 다르므로 하나도 합치지 않는다 —
            // 109 는 가입(문자 발송) 경로, 110·111 은 탈퇴 경로에서 난다.
            case "USER109": error = .rejoinRestricted
            case "USER110": error = .ongoingPartyExists
            case "USER111": error = .passwordMismatch
            // 제공 목록 밖의 프로필 이미지 키(Backend #235). 400 폴백이 INVALID_REQUEST 라
            // 코드를 놓치면 서버 원문(「제공하지 않는 프로필 이미지입니다」)이 그대로 떠서
            // 사용자가 할 일을 알 수 없다. 사용자 입력 문제가 아니라 앱이 잘못된 키를 보낸 것이다.
            case "USER112": error = .invalidProfileImage
            // 문자 인증. 둘(201/208)만 합치고 나머지는 그대로 남긴다 — 위 표 아래 주석에 근거.
            case "USER201", "USER208": error = .smsUnavailable
            case "USER202": error = .smsCooldown
            case "USER203": error = .smsDailyLimitExceeded
            case "USER204": error = .smsCodeExpired
            case "USER205": error = .smsCodeMismatch
            case "USER206": error = .smsTooManyAttempts
            case "USER207": error = .phoneNotVerified
            // 빈 FCM 토큰. 사용자가 고칠 수 있는 입력이 아니라 앱 쪽 문제이므로 일반 검증 실패로 둔다
            // (푸시 등록 실패는 FcmTokenRegistrar 가 삼키므로 여기까지 올라오지도 않는다).
            case "USER106": error = .invalidRequest
            case "INVALID_REQUEST": error = .invalidRequest
            // 토큰 계열 + 사용자 없음: 앱의 대응은 모두 "재로그인"이다.
            case "USER001", "USER002", "USER003", "USER004", "USER005", "USER103": error = .sessionExpired
            default:
                switch http.code() {
                case 400: error = .invalidRequest
                case 401: error = .sessionExpired
                case 409: error = .loginIdDuplicated
                default: error = .unknown
                }
            }
            return AuthException(error: error, serverMessage: body?.message, cause: http)
        }

        // 응답 자체를 못 받은 경우(연결 거부·타임아웃·DNS). 사용자에게는 재시도를 안내한다.
        // URLError(.cancelled) 는 취소이지 전송 실패가 아니다 — 그 도메인이 같아 먼저 거른다.
        if !isCancellation(throwable: self), isIOFailure(throwable: self) {
            return AuthException(error: .network, cause: self)
        }

        return AuthException(error: .unknown, cause: self)
    }
}

/// 인증 계열 호출을 감싸 실패를 `AuthException` 으로 통일한다.
/// 취소는 그대로 통과시킨다 — 취소를 에러로 바꾸면 화면 이탈이 에러 토스트로 보인다.
func authCall<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ block: () async throws -> T
) async throws -> T {
    do {
        return try await block()
    } catch let error where isCancellation(throwable: error) {
        throw error
    } catch {
        throw error.toAuthException()
    }
}
