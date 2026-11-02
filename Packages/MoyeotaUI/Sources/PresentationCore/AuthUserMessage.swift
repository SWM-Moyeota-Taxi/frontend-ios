import MoyeotaDomain

public extension Error {
    /// `AuthError` → 사용자에게 보여줄 한국어 문구. 가입·로그인·문자 인증이 **이 표 하나**를 쓴다.
    ///
    /// 문구 기준: 사용자가 **지금 무엇을 해야 하는지**가 한 줄에 들어가야 한다. 특히 서버가 같은 상태
    /// 코드로 뭉쳐 보내는 묶음(429 세 개 · 400 세 개)은 할 일이 서로 다르므로 절대 같은 말을 쓰지 않는다
    /// — "잠시 후 다시 시도해 주세요"를 일일 한도 초과에 띄우면 사용자가 1분마다 재전송을 누르며 하루를 보낸다.
    func authUserMessage() -> String {
        guard let authException = self as? AuthException else { return "잠시 후 다시 시도해 주세요" }
        return authErrorMessage(error: authException.error, serverMessage: authException.serverMessage)
    }
}

/// 예외가 아니라 `AuthError` 만 들고 문구를 꺼내는 입구.
///
/// 앱이 **스스로 아는 실패**에도 같은 문구가 필요해서 나눠 뒀다 — 인증번호 3분 만료는 서버에
/// 묻지 않아도 알 수 있고(`PhoneVerifyState.onCodeExpired`), 가입이 토큰을 거절해 인증 단계로
/// 되돌릴 때도(`PhoneVerifyViewModel.onSignupRejectedPhone`) 예외 값이 손에 없다.
///
/// `switch` 에 `default` 를 두지 않는 것이 중요하다: `AuthError` 가 늘어나면 컴파일이 깨져서
/// 문구를 빠뜨린 채 "잠시 후 다시 시도해 주세요"로 뭉개는 일이 생기지 않는다(이번 문자 인증 8종이
/// 그렇게 발견됐다).
public func authErrorMessage(error: AuthError, serverMessage: String? = nil) -> String {
    switch error {
    case .loginFailed: return "아이디 또는 비밀번호가 올바르지 않아요"
    case .loginIdDuplicated: return "이미 사용 중인 아이디예요"
    // 전화번호 중복은 "계정이 이미 있다"는 뜻이라, 고칠 곳(로그인)을 함께 알려준다.
    // 2026-10 부터는 가입이 아니라 **인증번호 발송 단계**에서 먼저 난다 — 문자를 기다리게 하지 않는다.
    case .phoneNumberDuplicated: return "이미 가입된 번호예요. 로그인해서 이어가 주세요"
    // 같은 409, 같은 발송 단계인데 할 일이 정반대다 — 위쪽은 "로그인하세요"지만 여기엔 로그인할 계정이 없다.
    // 기다리는 수밖에 없는 상황이라 재시도를 권하지 않고 쓸 수 있는 선택지(다른 번호)를 말한다.
    // 서버 쓸어내기가 하루 한 번이라 "정확히 30일 뒤"라고 약속하지 않는다(AuthPolicy.REJOIN_RESTRICTED_DAYS).
    case .rejoinRestricted:
        return "탈퇴한 번호는 \(AuthPolicy.REJOIN_RESTRICTED_DAYS)일 동안 다시 가입할 수 없어요. 기간이 지난 뒤에 가입하거나 다른 번호를 써 주세요"
    case .nicknameDuplicated: return "이미 사용 중인 닉네임이에요"
    case .invalidNickname: return "닉네임은 한글·영문·숫자 2~10자로 입력해 주세요"
    // 사용자가 고칠 입력이 아니라 앱이 목록 밖의 키를 보낸 것이다 — **같은 키로 재시도를 권하지 않는다**
    // (같은 키를 다시 눌러도 같은 400 이다).
    //
    // 「목록을 다시 불러와 주세요」라고 하지 않는 이유: 목록 재조회는 앱이 스스로 한다
    // (`ProfileEditViewModel.save()` 의 catch 가 `loadImages()` 를 부르고 고른 값을 비운다).
    // 36 에는 사용자가 누를 「다시 불러오기」 자리가 없으므로, 그 문구는 할 수 없는 일을 시킨다.
    // 사용자에게 남은 할 일은 새로 받은 격자에서 다시 고르는 것 하나뿐이다.
    //
    // 이 코드(400 `USER112`)가 뜨는 창구는 `PATCH /users/me` 뿐이다 — 가입 요청에는 imageKey 가
    // 없어서(`UpdateProfileRequest` 에만 있다) 이 문구를 보는 화면은 36 하나다.
    case .invalidProfileImage: return "지금은 고를 수 없는 이미지예요. 다시 골라 주세요"
    // 닉네임 형식 오류는 두 코드로 온다 — 서버 VO 가 먼저 걸리면 USER107, Bean Validation 이
    // 먼저 걸리면 INVALID_REQUEST(message = "nickname: …") 다. 사용자에겐 같은 사실이므로 한 문구로 모은다.
    case .invalidRequest:
        if serverMessage?.hasPrefix("nickname") == true {
            return "닉네임은 한글·영문·숫자 2~10자로 입력해 주세요"
        }
        // 발송 요청의 번호 형식 위반은 @Pattern 이 먼저 걸려 이 코드로 온다(확인 요청은 USER105).
        // 서버 원문("phoneNumber: …")보다 고칠 형식을 보여주는 쪽이 낫다.
        if serverMessage?.hasPrefix("phoneNumber") == true {
            return "휴대폰 번호를 010-1234-5678 형식으로 입력해 주세요"
        }
        return serverMessage ?? "입력한 정보를 다시 확인해 주세요"

    // ── 문자 인증 (2026-10 신규). 할 일이 전부 다르므로 한 문구도 겹치지 않는다 ──
    case .invalidPhoneNumber: return "휴대폰 번호를 010-1234-5678 형식으로 입력해 주세요"
    // 남은 초는 「다시 받기」 버튼이 카운트다운으로 보여 준다 — 서버가 남은 시간을 주지 않아
    // 문구에 숫자를 박을 수 없다(박으면 틀린 숫자가 된다).
    case .smsCooldown: return "인증번호는 1분에 한 번만 받을 수 있어요. 버튼의 남은 시간이 끝나면 다시 받아 주세요"
    // 기다려서 풀리는 문제가 아니다 — 재시도를 권하지 않고 다음 수단을 말한다
    case .smsDailyLimitExceeded:
        return "오늘 받을 수 있는 인증번호를 모두 썼어요(하루 \(AuthPolicy.SMS_DAILY_LIMIT)번). 내일 다시 시도하거나 다른 번호로 가입해 주세요"
    case .smsCodeExpired: return "인증번호가 만료됐어요. 「인증번호 다시 받기」로 새 번호를 받아 주세요"
    // 서버에 아직 인증번호가 남아 있다 — 입력칸만 비우고 다시 치면 된다(남은 시도는 서버가 센다)
    case .smsCodeMismatch: return "인증번호가 일치하지 않아요. 문자로 받은 6자리를 다시 입력해 주세요"
    // 5회를 넘기면 서버가 그 인증번호를 지운다 — 같은 번호를 더 입력해 봐야 소용없다
    case .smsTooManyAttempts:
        return "인증번호를 \(AuthPolicy.SMS_MAX_VERIFY_ATTEMPTS)번 잘못 입력했어요. 새 인증번호를 받아 주세요"
    // 토큰 만료·소진·번호 불일치가 한 코드로 온다. 셋 다 할 일은 "인증을 다시" 하나다
    case .phoneNotVerified: return "휴대폰 인증이 만료됐어요. 인증을 다시 하고 가입을 마쳐 주세요"
    // 사용자 입력 문제가 아니다 — 무엇을 고쳐야 할지 찾게 만들지 않는다
    case .smsUnavailable: return "문자 인증이 일시적으로 안 되고 있어요. 잠시 뒤 다시 시도해 주세요"

    // ── 회원 탈퇴 (2026-10 신규, 37 탈퇴 화면) ──
    // 둘 다 409 라 코드를 놓치면 "이미 사용 중인 아이디예요"(409 폴백)가 탈퇴 화면에 뜬다.
    // 할 일을 한 줄에 담는다 — 「나가기」가 어디 있는지는 사용자가 이미 안다(21·25·26 의 버튼).
    case .ongoingPartyExists: return "진행 중인 합승이 있어요. 합승에서 먼저 나간 뒤에 탈퇴해 주세요"
    // 로그인 실패(401)와 달리 세션은 살아 있다 — "다시 로그인"이 아니라 "다시 입력"이다.
    case .passwordMismatch: return "비밀번호가 일치하지 않아요"

    case .sessionExpired: return "다시 로그인해 주세요"
    case .network: return "네트워크 연결을 확인해 주세요"
    case .unknown: return "잠시 후 다시 시도해 주세요"
    }
}
