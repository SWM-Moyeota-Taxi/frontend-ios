import MoyeotaDomain

/// 가입 플로우(10 프로필 만들기 → 12 매너 서약)가 모으는 값.
///
/// 서버 `POST /api/v1/auth/register` 가 요구하는 9개 필드가 그대로 이 구조체의 필드다 — 계정 유형이나
/// 학교·재직 인증 결과는 API 에 자리가 없어 담지 않는다(그 화면들이 가입 경로에서 빠진 이유이기도 하다).
///
/// | 필드 | 수집 화면 |
/// |---|---|
/// | `nickname` | 10 프로필 만들기 (1/2, 「프로필」 절) |
/// | `name` · `birthDate` · `gender` · `phoneNumber` | 10 프로필 만들기 (1/2, 「기본 정보」 절) |
/// | `verificationToken` | 10 프로필 만들기 (1/2, 휴대폰 번호 아래 인증 블록) |
/// | `loginId` · `password` · `email` | 10 프로필 만들기 (1/2, 「로그인 정보」 절) |
///
/// 09 본인 인증이 앞 절반을 받던 시절의 흔적으로 필드가 화면을 넘나드는 구조가 남아 있다.
/// 지금은 10 이 한 번에 다 채우지만, 실제 본인 인증이 붙으면 다시 나뉠 자리라 그대로 뒀다.
///
/// 제출은 12 매너 서약의 「동의하고 가입 완료」 한 곳에서만 일어난다.
///
/// 원본 이 파일의 `authUserMessage`·`authErrorMessage` 는 다른 기능도 쓰므로 `PresentationCore` 로 옮겼다.
public struct SignupDraft: Equatable, Sendable {
    public var email: String
    /// 서버 가입 필수 필드. 동승자에게 보이는 유일한 이름이고 실명(`name`)은 공개되지 않는다.
    /// 규칙은 `NicknamePolicy` — 서버 도메인 VO 와 같은 정규식이다.
    public var nickname: String
    public var name: String
    public var phoneNumber: String
    public var birthDate: LocalDate?
    public var gender: Gender?
    public var loginId: String
    public var password: String
    /// 문자 인증을 통과했다는 증표. 10 프로필 만들기의 인증 블록
    /// (`PhoneVerifyState.token`)이 채우고, 12 매너 서약의 제출이 그대로 서버로 싣는다.
    ///
    /// **`phoneNumber` 와 한 쌍이다** — 서버가 토큰에 묶인 번호와 가입 번호의 해시를 비교하므로
    /// 번호만 고치면 가입이 400 `USER207` 로 떨어진다. 그래서 10 은 번호가 바뀌는 순간 토큰을 버리고
    /// (`onPhoneDigitsChanged`) 인증을 다시 받게 한다 — 이 초안에 토큰만 남아 있는 상태는 생기지 않는다.
    ///
    /// 수명 10분, **가입 성공 시에만** 소진된다. 아이디·닉네임 중복(409)으로 가입이 실패했다면
    /// 이 값을 그대로 두고 입력만 고쳐 재시도하는 게 맞다(상세는 `NewUser.verificationToken` 주석).
    public var verificationToken: String

    public init(
        email: String = "",
        nickname: String = "",
        name: String = "",
        phoneNumber: String = "",
        birthDate: LocalDate? = nil,
        gender: Gender? = nil,
        loginId: String = "",
        password: String = "",
        verificationToken: String = ""
    ) {
        self.email = email
        self.nickname = nickname
        self.name = name
        self.phoneNumber = phoneNumber
        self.birthDate = birthDate
        self.gender = gender
        self.loginId = loginId
        self.password = password
        self.verificationToken = verificationToken
    }

    /// 서버 요청 모델로 변환. 아직 못 받은 값이 있으면 nil 이다.
    ///
    /// nil 은 "플로우를 건너뛰어 필수 값이 비었다"는 뜻 — 화면 순서가 바뀌었을 때
    /// 400 을 맞고 나서야 알아차리는 대신 제출 전에 걸러낸다.
    public func toNewUser() -> NewUser? {
        guard let birth = birthDate else { return nil }
        guard let genderValue = gender else { return nil }
        if loginId.isBlank || password.isBlank { return nil }
        if name.isBlank || phoneNumber.isBlank || email.isBlank { return nil }
        // 닉네임은 2026-09 서버 변경으로 가입 필수가 됐다 — 비어 있으면 400 을 맞기 전에 걸러낸다
        let trimmedNickname = nickname.trim()
        if trimmedNickname.isBlank { return nil }
        // 문자 인증 토큰은 2026-10 서버 변경으로 가입 필수가 됐다 — 닉네임과 같은 방식으로 먼저 걸러낸다
        // (없이 보내면 서버가 400 `INVALID_REQUEST` 로 전부 튕긴다).
        if verificationToken.isBlank { return nil }
        return NewUser(
            loginId: loginId,
            password: password,
            nickname: trimmedNickname,
            name: name,
            birthDate: birth,
            phoneNumber: phoneNumber,
            gender: genderValue,
            email: email,
            verificationToken: verificationToken
        )
    }
}
