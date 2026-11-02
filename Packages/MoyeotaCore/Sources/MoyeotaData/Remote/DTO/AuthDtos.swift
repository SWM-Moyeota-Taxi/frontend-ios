/// POST /api/v1/auth/register — 백엔드 `UserRegisterRequest` 와 필드 1:1.
///
/// `birthDate` 는 서버가 `Instant` 로 받는다(예: "2000-01-01T00:00:00Z"). 날짜만 보내면
/// Jackson 이 역직렬화에 실패해 400 이 나므로 매퍼에서 UTC 자정으로 확장해 넣는다.
/// `gender` 는 서버 enum 이름 그대로 "MALE" / "FEMALE" / "UNDISCLOSED"(선택 안 함)다.
/// 서버 필드는 `@NotNull` 이라 **셋 중 하나가 반드시 실려야 한다** — 「선택 안 함」도 빈 문자열이나
/// 필드 누락이 아니라 `"UNDISCLOSED"` 라는 이름을 보내는 것이다(그래서 이 필드는 nullable 이 아니다).
///
/// `"UNDISCLOSED"` 는 백엔드 PR #235 가 2026-10-15 운영에 배포되면서 받아들여진다 — 운영 스펙
/// (`/v3/api-docs`)의 이 필드가 `["MALE","FEMALE","UNDISCLOSED"]` 인 것을 확인하고 화면 노출을 켰다.
/// 노출 스위치는 presentation 의 `ServerAcceptsUndisclosedGender` 한 곳이다(롤백 대비로 남겨 뒀다).
///
/// `nickname` 은 나중에 추가된 **필수** 필드다(서버 record 필드 순서도 password 다음이다).
/// 빠뜨리면 400, 형식이 틀리면 400 `USER107`, 이미 쓰는 값이면 409 `USER108` 이다.
///
/// `verificationToken` 도 **필수**다(2026-10). 빠뜨리면 400 `INVALID_REQUEST`
/// (`message = "verificationToken: 휴대폰 인증이 필요합니다."`)라서, 서버 변경 직후 앱이
/// 가입 자체를 못 하는 상태가 됐던 필드다.
public struct RegisterRequestDto: Codable, Equatable, Sendable {
    public var loginId: String
    public var password: String
    public var nickname: String
    public var name: String
    public var birthDate: String
    public var phoneNumber: String
    public var gender: String
    public var email: String
    public var verificationToken: String

    public init(
        loginId: String,
        password: String,
        nickname: String,
        name: String,
        birthDate: String,
        phoneNumber: String,
        gender: String,
        email: String,
        verificationToken: String
    ) {
        self.loginId = loginId
        self.password = password
        self.nickname = nickname
        self.name = name
        self.birthDate = birthDate
        self.phoneNumber = phoneNumber
        self.gender = gender
        self.email = email
        self.verificationToken = verificationToken
    }
}

/// POST /api/v1/auth/sms/send 의 요청 본문 — 백엔드 `SmsSendRequest`.
///
/// 필드가 하나뿐이고 `@Pattern(^01[016-9]-?\d{3,4}-?\d{4}$)` 가 걸려 있어 **형식 위반은 VO 가 아니라
/// Bean Validation 에 먼저 걸린다** → 400 `INVALID_REQUEST`(`USER105` 가 아니다).
/// 확인 요청(`SmsVerifyRequestDto`)과 갈리는 지점이라 에러 매핑에서 헷갈리기 쉽다.
///
/// 응답은 **본문 없는 204** 다.
public struct SmsSendRequestDto: Codable, Equatable, Sendable {
    public var phoneNumber: String

    public init(phoneNumber: String) {
        self.phoneNumber = phoneNumber
    }
}

/// POST /api/v1/auth/sms/verify 의 요청 본문 — 백엔드 `SmsVerifyRequest`.
///
/// `phoneNumber` 에는 `@NotBlank` 만 있다(발송 쪽과 달리 `@Pattern` 이 없다) — 형식이 틀리면
/// 서버가 `PhoneNumber` VO 를 만들다 400 `USER105` 를 낸다.
/// `code` 는 `@Pattern(^\d{6}$)` — 6자리가 아니면 비교 전에 400 `INVALID_REQUEST` 다.
public struct SmsVerifyRequestDto: Codable, Equatable, Sendable {
    public var phoneNumber: String
    public var code: String

    public init(phoneNumber: String, code: String) {
        self.phoneNumber = phoneNumber
        self.code = code
    }
}

/// 200 응답 — 백엔드 `SmsVerifyResponse(String verificationToken)`. 서버는 UUID 문자열을 담는다.
///
/// 기본값 빈 문자열은 방어다. 다만 빈 값으로 가입을 보내면 400 이 나므로
/// Repository 가 여기서 끊는다(`RemoteAuthRepository.verifyPhoneCode`).
public struct SmsVerifyResponse: Decodable, Equatable, Sendable {
    public var verificationToken: String

    public init(verificationToken: String = "") {
        self.verificationToken = verificationToken
    }

    private enum CodingKeys: String, CodingKey {
        case verificationToken
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verificationToken = try c.decodeOrDefault(.verificationToken, default: "")
    }
}

/// 201 응답. 토큰은 주지 않는다 — 가입 후 로그인을 따로 해야 한다.
///
/// 서버 `UserResponse` 는 2026-10-15 배포(Backend #235)로 `imageUrl` 이 붙어 두 필드가 됐지만,
/// 가입 직후 화면이 쓰는 값은 `uuid` 하나뿐이라 여기선 받지 않는다(디코더가 모르는 키를 흘린다).
public struct RegisterResponse: Decodable, Equatable, Sendable {
    public var uuid: String

    public init(uuid: String = "") {
        self.uuid = uuid
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeOrDefault(.uuid, default: "")
    }
}

/// POST /api/v1/auth/nickname/check 의 요청 본문 — 백엔드 `NicknameCheckRequest(@NotBlank String nickname)`.
///
/// 가입 폼에서 로그인 전에 부르는 값이라 `AuthApi` 쪽(Bearer 미부착 클라이언트)에 있다.
/// 컨트롤러 프리픽스가 `/api/v1/auth` 인 것도 같은 이유다 — 이 구간만 permitAll 이다.
public struct NicknameCheckRequestDto: Codable, Equatable, Sendable {
    public var nickname: String

    public init(nickname: String) {
        self.nickname = nickname
    }
}

/// 200 응답 — 백엔드 `NicknameCheckResponse(boolean exists)`.
///
/// 기본값 false 는 방어다: 필드가 빠진 응답을 "사용 중"으로 읽어 멀쩡한 닉네임을 막는 것보다
/// 통과시키고 가입에서 409 로 걸리는 편이 낫다.
public struct NicknameCheckResponse: Decodable, Equatable, Sendable {
    public var exists: Bool

    public init(exists: Bool = false) {
        self.exists = exists
    }

    private enum CodingKeys: String, CodingKey {
        case exists
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exists = try c.decodeOrDefault(.exists, default: false)
    }
}

/// POST /api/v1/auth/phone/check 의 요청 본문 — 백엔드 `PhoneCheckRequest(@NotBlank String phoneNumber)`.
///
/// `NicknameCheckRequestDto` 와 같은 자리에 있는 이유도 같다 — 가입 전(무토큰) 호출이라
/// `/api/v1/auth` 프리픽스의 permitAll 구간이어야 하고, Bearer 가 붙지 않는 클라이언트로 보내야 한다.
///
/// 서버 필드에 `@Pattern` 이 **없다**(`SmsSendRequestDto` 와 갈리는 지점이다) — 형식이 틀리면
/// Bean Validation 이 아니라 서버 `PhoneNumber` VO 가 걸러 **400 `USER105`** 다
/// (실측 2026-11-01, 로컬 :8080 — `{"phoneNumber":"abc"}` → `{"code":"USER105",...}`).
/// 빈 값·필드 누락만 400 `INVALID_REQUEST`(`"phoneNumber: 공백일 수 없습니다"`)로 온다.
public struct PhoneCheckRequestDto: Codable, Equatable, Sendable {
    public var phoneNumber: String

    public init(phoneNumber: String) {
        self.phoneNumber = phoneNumber
    }
}

/// 200 응답 — 백엔드 `PhoneCheckResponse(boolean exists)`. 닉네임 쪽과 모양이 같다
/// (실측 2026-11-01, 로컬 :8080 — `{"exists":true}` / `{"exists":false}`).
///
/// 기본값 false 는 `NicknameCheckResponse` 와 같은 방어다: 필드가 빠진 응답을 「가입됨」으로 읽어
/// 멀쩡한 번호를 막는 것보다, 통과시키고 문자 발송의 409 `USER104` 에서 걸리는 편이 낫다.
///
/// **`exists=false` 는 「가입할 수 있다」는 뜻이 아니다.** 서버가 보는 건 활성 프로필
/// (`user_profile.phone_hash`) 한 테이블뿐이고 탈퇴 기록(`user_deletion`)은 보지 않는다 —
/// 탈퇴한 번호도 false 로 온다(실측 2026-11-01: `010-7777-0101` → `{"exists":false}` 200인데
/// 같은 번호의 `POST /auth/sms/send` 는 409 `USER109`). 재가입 제한은 발송 단계에서만 드러난다.
public struct PhoneCheckResponse: Decodable, Equatable, Sendable {
    public var exists: Bool

    public init(exists: Bool = false) {
        self.exists = exists
    }

    private enum CodingKeys: String, CodingKey {
        case exists
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exists = try c.decodeOrDefault(.exists, default: false)
    }
}

/// POST /api/v1/auth/login — 백엔드 `UserLoginRequest`.
public struct LoginRequestDto: Codable, Equatable, Sendable {
    public var loginId: String
    public var password: String

    public init(loginId: String, password: String) {
        self.loginId = loginId
        self.password = password
    }
}

/// POST /api/v1/auth/reissue 및 /api/v1/auth/logout 의 공통 본문 — 백엔드 `TokenRequest`.
public struct RefreshTokenRequestDto: Codable, Equatable, Sendable {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// **로그인과 재발급이 공유하는** 200 응답. 백엔드 `TokenResponse(accessToken, refreshToken)`.
///
/// 로그인 응답에 있던 `userId` 는 사라졌다 — 사용자 UUID 는 액세스 토큰의 `sub` 클레임에서 읽는다
/// (`jwtSubject`).
///
/// **회전(rotation) 방식이라 리프레시도 새 값으로 바뀐다** — 응답의 refreshToken 을 반드시 저장해야
/// 다음 재발급이 가능하다. 옛 리프레시는 서버에서 즉시 삭제돼 재사용 시 401 `USER001` 이다(실측).
public struct TokenResponse: Decodable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String

    public init(accessToken: String = "", refreshToken: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decodeOrDefault(.accessToken, default: "")
        refreshToken = try c.decodeOrDefault(.refreshToken, default: "")
    }
}
