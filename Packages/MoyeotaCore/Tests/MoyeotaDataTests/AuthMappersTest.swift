import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

@Suite struct AuthMappersTest {

    private let newUser = NewUser(
        loginId: "moyeota_test",
        password: "Passw0rd!",
        nickname: "모여타",
        name: "홍길동",
        birthDate: LocalDate(year: 2000, month: 1, dayOfMonth: 1)!,
        phoneNumber: "010-1234-5678",
        gender: .male,
        email: "test@moyeota.com",
        verificationToken: "3f2b8c1e-0000-4000-8000-000000000001"
    )

    private func newUser(gender: Gender) -> NewUser {
        var user = newUser
        user.gender = gender
        return user
    }

    @Test("birthDate 는 UTC 자정 Instant 문자열로 변환된다")
    func birthDateInstant() throws {
        #expect(try LocalDate.of(2000, 1, 1).toBirthDateInstant() == "2000-01-01T00:00:00Z")
        #expect(try LocalDate.of(1999, 12, 31).toBirthDateInstant() == "1999-12-31T00:00:00Z")
    }

    @Test("가입 요청 DTO 는 서버 필드명과 값 형식을 그대로 만든다")
    func registerDtoShape() throws {
        let dto = newUser.toDto()

        #expect(dto.loginId == "moyeota_test")
        // 닉네임은 나중에 추가된 필수 필드다 — 빠지면 400 이고, 이름(name)과는 다른 값이다.
        #expect(dto.nickname == "모여타")
        #expect(dto.name == "홍길동")
        // 서버가 Instant 로 받으므로 날짜만 보내면 400 이다.
        #expect(dto.birthDate == "2000-01-01T00:00:00Z")
        // 발송·확인과 같은 형태(하이픈 없는 숫자열)로 통일한다 — 서버도 하이픈을 떼고 저장·비교한다.
        #expect(dto.phoneNumber == "01012345678")
        // 서버 enum 이름 그대로여야 역직렬화된다.
        #expect(dto.gender == "MALE")
        #expect(dto.email == "test@moyeota.com")

        let encoded = try encodeJSON(dto)
        for field in [
            "loginId", "password", "nickname", "name", "birthDate",
            "phoneNumber", "gender", "email", "verificationToken",
        ] {
            #expect(encoded.contains("\"\(field)\""), "\(field) 필드가 빠졌다: \(encoded)")
        }
    }

    /// 2026-10 서버 변경으로 `verificationToken` 이 `@NotBlank` 필수가 됐다 — 빠뜨리면
    /// 가입이 **전부** 400 `INVALID_REQUEST` 다. 본문에 실제로 실리는지까지 못 박는다.
    @Test("가입 요청 본문에 문자 인증 토큰이 실린다")
    func registerBodyCarriesToken() throws {
        let dto = newUser.toDto()

        #expect(dto.verificationToken == "3f2b8c1e-0000-4000-8000-000000000001")

        let encoded = try encodeJSON(dto)
        #expect(
            encoded.contains(#""verificationToken":"3f2b8c1e-0000-4000-8000-000000000001""#),
            "토큰이 본문에 없다: \(encoded)"
        )
    }

    /// 성별은 **세 값 모두** enum 이름 그대로 나가야 서버가 `Gender` 로 역직렬화한다.
    ///
    /// `UNDISCLOSED`(선택 안 함)를 못 박는 게 목적이다. 서버 필드는 `@NotNull` 이 그대로라
    /// 「밝히지 않음」도 **필드를 비우는 게 아니라 값을 보내는 것**인데, 도메인에 세 번째 상수를 더하는
    /// 대신 빈 문자열이나 필드 누락으로 "구현"하면 가입이 전부 400 으로 막힌다.
    ///
    /// **받는 쪽은 테스트할 게 없다** — 서버 `UserResponse(uuid, name)` 에 성별이 없고, 앱의 어떤
    /// 응답 DTO 도 `gender` 를 갖지 않는다(2026-10-15, Backend PR #235 포함해 확인). 즉 성별은
    /// 지금 **요청 전용 필드**다. 응답에 생기면 모르는 값에 대한 폴백부터 정해야 한다.
    @Test("성별 세 값이 모두 서버 enum 이름 그대로 실려 나간다")
    func genderValues() {
        let sent = Dictionary(
            uniqueKeysWithValues: Gender.allCases.map { ($0, newUser(gender: $0).toDto().gender) }
        )

        #expect(sent[.male] == "MALE")
        #expect(sent[.female] == "FEMALE")
        #expect(sent[.undisclosed] == "UNDISCLOSED")
        // 값이 늘면 서버가 모르는 이름이 나가 400 이 된다 — 백엔드 enum 과 같이 늘려야 한다.
        #expect(Gender.allCases.count == 3, "백엔드 Gender 와 값 개수가 어긋났다: \(Gender.allCases)")
    }

    /// 「선택 안 함」이 본문에 **값으로** 실리는지. 위 테스트가 DTO 필드를 보는 것과 달리 이쪽은
    /// 직렬화 결과를 본다 — 빈 문자열이나 필드 누락(둘 다 서버 `@NotNull` 에서 400)과 갈리는 지점이다.
    @Test("성별 선택 안 함은 빈 값이 아니라 UNDISCLOSED 로 직렬화된다")
    func undisclosedIsEncodedAsValue() throws {
        let encoded = try encodeJSON(newUser(gender: .undisclosed).toDto())

        #expect(encoded.contains(#""gender":"UNDISCLOSED""#), "gender 가 값으로 실리지 않았다: \(encoded)")
        #expect(!encoded.contains(#""gender":"""#), "빈 값을 보내면 서버가 400 이다: \(encoded)")
    }

    /// 발송·확인·가입 세 요청이 같은 번호 형태를 써야 한다. 서버는 요청마다 `PhoneNumber` VO 로
    /// 하이픈을 떼고 해시하므로 결과는 같지만, 앱이 화면마다 다른 형태를 보내면
    /// "인증은 통과했는데 가입이 400"을 추적할 때 번호 표기부터 의심해야 한다.
    @Test("전화번호는 하이픈과 공백을 떼고 보낸다")
    func normalizesPhoneNumber() {
        #expect(AuthPolicy.normalizePhoneNumber(value: "010-1234-5678") == "01012345678")
        #expect(AuthPolicy.normalizePhoneNumber(value: "01012345678") == "01012345678")
        #expect(AuthPolicy.normalizePhoneNumber(value: " 010 1234 5678 ") == "01012345678")
        // 서버 VO 는 앞뒤 공백만 strip 해서 중간 공백이 남은 값을 400 으로 떨군다 — 앱이 먼저 지운다.
        #expect(AuthPolicy.isValidPhoneNumber(value: AuthPolicy.normalizePhoneNumber(value: "010 1234 5678")))
        // 011/016~019 도 서버 정규식이 받는다(가입 번호 길이가 10자리인 경우).
        #expect(AuthPolicy.normalizePhoneNumber(value: "011-123-4567") == "0111234567")
    }

    /// 서버 `SmsVerifyRequest.code` 의 `@Pattern(^\d{6}$)` 과 같은 판정.
    @Test("인증번호는 숫자 6자리만 통과한다")
    func verificationCodeFormat() {
        #expect(AuthPolicy.isValidVerificationCode(value: "000000"))
        #expect(AuthPolicy.isValidVerificationCode(value: "123456"))
        #expect(!AuthPolicy.isValidVerificationCode(value: "12345"), "5자리는 안 된다")
        #expect(!AuthPolicy.isValidVerificationCode(value: "1234567"), "7자리는 안 된다")
        #expect(!AuthPolicy.isValidVerificationCode(value: "12345a"), "숫자가 아니면 안 된다")
        #expect(!AuthPolicy.isValidVerificationCode(value: ""))
    }

    /// 서버 `@Past` 는 **Instant** 비교이고 앱은 날짜를 UTC 자정으로 올려 보낸다.
    /// 그래서 "오늘"은 09:00 KST 이전이면 아직 미래다 — 그 틈을 도메인에서 미리 막는다.
    @Test("생년월일은 UTC 기준 오늘보다 이른 날짜만 통과한다")
    func birthDateMustBeBeforeUtcToday() throws {
        let todayUtc = LocalDate.now(LocalDate.utcZone)

        #expect(AuthPolicy.isValidBirthDate(value: try LocalDate.of(2000, 1, 1)))
        #expect(AuthPolicy.isValidBirthDate(value: todayUtc.minusDays(1)))
        #expect(!AuthPolicy.isValidBirthDate(value: todayUtc), "오늘은 UTC 자정이 미래일 수 있다")
        #expect(!AuthPolicy.isValidBirthDate(value: todayUtc.plusDays(1)))
    }

    /// 인증 확인 성공 응답은 토큰 하나뿐이다 — 백엔드 `SmsVerifyResponse`.
    @Test("문자 인증 200 응답에서 verificationToken 을 읽는다")
    func decodesSmsVerifyResponse() throws {
        let body = #"{"verificationToken":"3f2b8c1e-0000-4000-8000-000000000001"}"#

        let response = try decodeJSON(SmsVerifyResponse.self, body)

        #expect(response.verificationToken == "3f2b8c1e-0000-4000-8000-000000000001")
        // 필드가 빠진 응답은 빈 값으로 방어한다(끊는 건 Repository 몫이다).
        #expect(try decodeJSON(SmsVerifyResponse.self, "{}").verificationToken == "")
    }

    /// 발송 요청 본문은 번호 하나다 — 백엔드 `SmsSendRequest`.
    @Test("문자 발송 요청 본문은 phoneNumber 하나다")
    func smsSendBody() throws {
        let encoded = try encodeJSON(SmsSendRequestDto(phoneNumber: "01012345678"))

        #expect(encoded == #"{"phoneNumber":"01012345678"}"#)
    }

    // 원본의 기대값은 `{"phoneNumber":…,"code":…}` 이다. 키 순서만 `docs/IOS-DIFFERENCES.md` 대로 알파벳순이고
    // 키 이름·값·개수는 원본과 같다 — 문자열 전체를 비교하는 단언의 세기는 그대로 둔다.
    @Test("문자 확인 요청 본문은 번호와 코드다")
    func smsVerifyBody() throws {
        let encoded = try encodeJSON(SmsVerifyRequestDto(phoneNumber: "01012345678", code: "123456"))

        #expect(encoded == #"{"code":"123456","phoneNumber":"01012345678"}"#)
    }

    /// **429 가 세 가지 뜻을 갖는다** — 재발송 대기(USER202)·하루 한도(USER203)·입력 초과(USER206).
    /// 상태 코드로 폴백하면 셋 다 `AuthError.unknown` 이 되어 "잠시 후 다시 시도해 주세요"가 뜨는데,
    /// 하루 한도에 그 문구를 띄우면 사용자가 1분마다 재전송을 누르며 하루를 보낸다.
    @Test("429 세 코드는 서로 다른 사유로 갈린다")
    func throttleCodes() {
        let throttles = [
            #"{"code":"USER202","message":"인증번호는 1분에 한 번만 요청할 수 있습니다."}"#,
            #"{"code":"USER203","message":"오늘 인증번호 요청 횟수를 초과했습니다."}"#,
            #"{"code":"USER206","message":"입력 횟수를 초과했습니다. 인증번호를 다시 요청해 주세요."}"#,
        ].map { httpException(429, $0).toAuthException().error }

        #expect(throttles == [.smsCooldown, .smsDailyLimitExceeded, .smsTooManyAttempts])
    }

    /// 400 도 세 가지다 — 만료(USER204)·불일치(USER205)·가입 토큰 무효(USER207).
    /// 폴백은 셋을 모두 `AuthError.invalidRequest` 로 뭉쳐 "입력한 정보를 다시 확인해 주세요"를 띄우는데,
    /// USER207 은 입력이 아니라 **인증 단계로 되돌려야 하는** 상황이다.
    @Test("문자 인증 400 세 코드는 서로 다른 사유로 갈린다")
    func smsBadRequestCodes() {
        let badRequests = [
            #"{"code":"USER204","message":"인증번호가 만료되었습니다. 다시 요청해 주세요."}"#,
            #"{"code":"USER205","message":"인증번호가 일치하지 않습니다."}"#,
            #"{"code":"USER207","message":"휴대폰 인증이 필요합니다."}"#,
        ].map { httpException(400, $0).toAuthException().error }

        #expect(badRequests == [.smsCodeExpired, .smsCodeMismatch, .phoneNotVerified])
    }

    /// 발송 실패(502)와 저장소 장애(503)는 앱의 대응이 같아 하나로 합쳤다.
    /// 합친 게 의도라는 걸 남겨 둔다 — 나중에 둘을 다르게 안내하려면 여기부터 갈라야 한다.
    @Test("발송 실패와 저장소 장애는 한 사유로 합친다")
    func smsUnavailableCodes() {
        #expect(
            httpException(502, #"{"code":"USER201","message":"인증번호 발송에 실패했습니다. 잠시 후 다시 시도해 주세요."}"#)
                .toAuthException().error == .smsUnavailable
        )
        #expect(
            httpException(503, #"{"code":"USER208","message":"지금은 인증을 진행할 수 없습니다. 잠시 후 다시 시도해 주세요."}"#)
                .toAuthException().error == .smsUnavailable
        )
    }

    /// 번호 형식 위반이 **두 코드로 갈린다**: 발송은 `@Pattern` 이 먼저 걸려 `INVALID_REQUEST`,
    /// 확인은 `@NotBlank` 뿐이라 `PhoneNumber` VO 까지 내려가 `USER105` 다. 화면 문구는 같아야 한다.
    @Test("400 USER105 는 전화번호 형식 오류로 좁힌다")
    func user105() throws {
        let fromVo = httpException(400, #"{"code":"USER105","message":"전화번호 형식이 올바르지 않습니다."}"#)
            .toAuthException()
        #expect(fromVo.error == .invalidPhoneNumber)

        let fromBeanValidation = httpException(
            400,
            #"{"code":"INVALID_REQUEST","message":"phoneNumber: 전화번호 형식이 올바르지 않습니다."}"#
        ).toAuthException()
        #expect(fromBeanValidation.error == .invalidRequest)
        #expect(try #require(fromBeanValidation.serverMessage).hasPrefix("phoneNumber: "))
    }

    /// 발송 단계에서 이미 가입된 번호를 거른다 — 기존 409 매핑이 그대로 쓰인다.
    @Test("발송 409 USER104 는 이미 가입된 번호다")
    func user104() {
        let exception = httpException(409, #"{"code":"USER104","message":"이미 가입된 전화번호입니다."}"#)
            .toAuthException()

        #expect(exception.error == .phoneNumberDuplicated)
    }

    /// 토큰이 빠진 가입 요청에 서버가 내는 본문. 필드명이 그대로 보여야 화면이 원인을 짚을 수 있다.
    @Test("토큰 누락 400 은 필드명이 담긴 검증 실패로 온다")
    func missingTokenBadRequest() throws {
        let exception = httpException(
            400,
            #"{"code":"INVALID_REQUEST","message":"verificationToken: 휴대폰 인증이 필요합니다."}"#
        ).toAuthException()

        #expect(exception.error == .invalidRequest)
        #expect(try #require(exception.serverMessage).hasPrefix("verificationToken: "))
    }

    @Test("가입 201 응답에서 uuid 를 읽는다")
    func decodesRegisterResponse() throws {
        let body = #"{"uuid":"7f6c1e2a-0f4b-4a53-9b5c-1c2d3e4f5a6b"}"#

        let response = try decodeJSON(RegisterResponse.self, body)

        #expect(response.uuid == "7f6c1e2a-0f4b-4a53-9b5c-1c2d3e4f5a6b")
    }

    /// 로그인 응답은 재발급과 같은 `TokenResponse` 이고 `userId` 는 없다.
    /// 서버가 옛 필드를 다시 실어 보내도 무시되는지까지 확인한다.
    @Test("로그인 200 응답은 토큰 쌍뿐이다")
    func decodesLoginResponse() throws {
        let body = #"{"accessToken":"access.jwt.value","refreshToken":"refresh.jwt.value"}"#

        let response = try decodeJSON(TokenResponse.self, body)

        #expect(response.accessToken == "access.jwt.value")
        #expect(response.refreshToken == "refresh.jwt.value")

        let withLegacyField =
            #"{"userId":"7f6c1e2a-0f4b-4a53-9b5c-1c2d3e4f5a6b","accessToken":"a","refreshToken":"r"}"#
        #expect(try decodeJSON(TokenResponse.self, withLegacyField).accessToken == "a")
    }

    @Test("재발급 응답은 리프레시까지 새 값으로 온다")
    func decodesReissueResponse() throws {
        let body = #"{"accessToken":"new.access","refreshToken":"new.refresh"}"#

        let response = try decodeJSON(TokenResponse.self, body)

        #expect(response.accessToken == "new.access")
        // 회전 방식 — 이 값을 저장하지 않으면 다음 재발급이 401 이 된다.
        #expect(response.refreshToken == "new.refresh")
    }

    /// **401 이 두 가지 뜻을 갖는다** — 로그인 실패(USER102)와 세션 만료(USER001~005).
    /// 코드를 안 보고 상태 코드로만 폴백하면 아이디/비밀번호 오류에 "다시 로그인해 주세요"가 뜬다.
    /// 본문은 실서버 응답 그대로다.
    @Test("401 USER102 는 세션 만료가 아니라 로그인 실패다")
    func user102() {
        let exception = httpException(401, #"{"code":"USER102","message":"아이디나 비밀번호가 다릅니다."}"#)
            .toAuthException()

        #expect(exception.error == .loginFailed)
        #expect(exception.serverMessage == "아이디나 비밀번호가 다릅니다.")
    }

    @Test("409 USER101 은 중복 아이디로 매핑된다")
    func user101() {
        let exception = httpException(409, #"{"code":"USER101","message":"이미 존재하는 아이디입니다."}"#)
            .toAuthException()

        #expect(exception.error == .loginIdDuplicated)
    }

    /// **409 는 다섯 가지 뜻을 갖는다.** 셋은 중복(아이디 `USER101`·전화번호 `USER104`·닉네임 `USER108`),
    /// 둘은 탈퇴가 들어오면서 생겼다 (2026-10, Backend #206).
    /// 신규 둘은 중복과 아무 상관이 없다:
    /// - `USER109` 재가입 제한 — 가입(문자 발송) 경로. 그 번호로 탈퇴한 계정이 있다.
    /// - `USER110` 진행 중 합승 — 탈퇴 경로. 합승에서 먼저 나와야 한다.
    ///
    /// 상태 코드로만 폴백하면 다섯이 전부 `AuthError.loginIdDuplicated` = "이미 사용 중인
    /// 아이디예요"가 된다. 가입에서는 사용자가 아이디만 계속 바꾸게 되고, **탈퇴 화면에서는 더 나쁘다**
    /// — 아이디를 입력한 적도 없는 화면에 아이디 중복 안내가 뜬다.
    @Test("409 다섯 코드가 전부 다른 값으로 갈린다 - 탈퇴 둘 포함")
    func conflictCodes() {
        let conflicts = [
            #"{"code":"USER101","message":"이미 존재하는 아이디입니다."}"#,
            #"{"code":"USER104","message":"이미 가입된 전화번호입니다."}"#,
            #"{"code":"USER108","message":"이미 사용 중인 닉네임입니다."}"#,
            #"{"code":"USER109","message":"탈퇴 후 30일 동안은 같은 번호로 다시 가입할 수 없습니다."}"#,
            #"{"code":"USER110","message":"진행 중인 합승이 있어 탈퇴할 수 없습니다. 합승을 나간 뒤 다시 시도해 주세요."}"#,
        ].map { httpException(409, $0).toAuthException().error }

        #expect(
            conflicts == [
                .loginIdDuplicated,
                .phoneNumberDuplicated,
                .nicknameDuplicated,
                .rejoinRestricted,
                .ongoingPartyExists,
            ]
        )
        // 같은 상태 코드에 다섯 뜻이 있으면 하나라도 겹치는 순간 그 화면은 틀린 말을 한다.
        #expect(Set(conflicts).count == conflicts.count, "409 매핑이 서로 겹친다")
    }

    /// `USER111` 비밀번호 불일치는 **400** 이다 — 로그인 실패(`USER102`, 401)와 다르다.
    ///
    /// 401 로 뭉치거나 `AuthError.sessionExpired` 로 보내면 비밀번호를 한 번 틀린 사용자가
    /// 로그인 화면으로 쫓겨난다. 세션은 그대로 살아 있다.
    @Test("400 USER111 은 세션 만료가 아니라 비밀번호 불일치다")
    func user111() {
        let exception = httpException(400, #"{"code":"USER111","message":"비밀번호가 일치하지 않습니다."}"#)
            .toAuthException()

        #expect(exception.error == .passwordMismatch)
        #expect(exception.serverMessage == "비밀번호가 일치하지 않습니다.")
    }

    /// `USER109` 는 **탈퇴가 아니라 가입 경로**에서 난다 — 서버 `SmsVerificationService.send` 가
    /// 번호 중복을 본 바로 다음 줄에서 탈퇴 기록을 본다. 즉 사용자는 「인증번호 받기」를 누르고
    /// 이 에러를 만난다. `AuthError.phoneNumberDuplicated` 와 합치면 안 된다:
    /// 저쪽 안내는 "로그인하세요"인데 여기엔 로그인할 계정이 없다.
    @Test("409 USER109 는 전화번호 중복과 다른 값이다")
    func user109() {
        let rejoin = httpException(409, #"{"code":"USER109","message":"탈퇴 후 30일 동안은 같은 번호로 다시 가입할 수 없습니다."}"#)
            .toAuthException()
        let duplicated = httpException(409, #"{"code":"USER104","message":"이미 가입된 전화번호입니다."}"#)
            .toAuthException()

        #expect(rejoin.error == .rejoinRestricted)
        #expect(duplicated.error == .phoneNumberDuplicated)
        #expect(rejoin.serverMessage == "탈퇴 후 30일 동안은 같은 번호로 다시 가입할 수 없습니다.")
    }

    @Test("409 USER108 은 아이디가 아니라 닉네임 중복이다")
    func user108() {
        let exception = httpException(409, #"{"code":"USER108","message":"이미 사용 중인 닉네임입니다."}"#)
            .toAuthException()

        #expect(exception.error == .nicknameDuplicated)
        #expect(exception.serverMessage == "이미 사용 중인 닉네임입니다.")
    }

    /// 닉네임 형식 위반은 일반 검증 실패와 달리 "중복 확인" 화면이 따로 안내해야 한다.
    @Test("400 USER107 은 닉네임 형식 오류로 좁힌다")
    func user107() {
        let exception = httpException(
            400,
            #"{"code":"USER107","message":"닉네임은 2~10자의 한글, 영문, 숫자만 가능합니다."}"#
        ).toAuthException()

        #expect(exception.error == .invalidNickname)
    }

    /// `USER112` 는 **서버가 제공하지 않는 이미지 키**를 보냈을 때다. 기본 이미지 키
    /// (`profile/presets/default.png`)를 「되돌리기」 삼아 보내는 게 전형적인 경우다 —
    /// 그 키는 프리셋 16장 밖이라 거절되고, 되돌리기는 `DELETE /api/v1/users/me/profile-image` 뿐이다.
    ///
    /// 400 폴백(`AuthError.invalidRequest`)에 맡기면 「입력한 정보를 다시 확인해 주세요」가 떠서,
    /// 고칠 입력이 없는 사용자가 닉네임만 고치며 맴돈다. 서버가 imageKey 를 닉네임 중복보다 **먼저**
    /// 검사하므로 이 코드가 오면 닉네임도 함께 안 바뀐 상태다 — 화면은 목록을 다시 불러오게 안내해야 한다.
    ///
    /// 기준: 백엔드 `user/common/exception/UserErrorCode.java` 의 `INVALID_PROFILE_IMAGE`.
    @Test("400 USER112 는 일반 검증 실패가 아니라 프로필 이미지 오류다")
    func user112() {
        let exception = httpException(400, #"{"code":"USER112","message":"제공하지 않는 프로필 이미지입니다."}"#)
            .toAuthException()

        #expect(exception.error == .invalidProfileImage)
        #expect(exception.error != .invalidRequest)
        #expect(exception.serverMessage == "제공하지 않는 프로필 이미지입니다.")
    }

    /// USER106(빈 FCM 토큰)은 사용자가 고칠 입력이 아니다 — 일반 검증 실패로 둔다.
    @Test("400 USER106 은 일반 검증 실패로 취급한다")
    func user106() {
        let exception = httpException(400, #"{"code":"USER106","message":"FCM 토큰이 비어 있습니다."}"#)
            .toAuthException()

        #expect(exception.error == .invalidRequest)
    }

    @Test("400 INVALID_REQUEST 는 필드 사유 메시지를 그대로 보존한다")
    func invalidRequestKeepsMessage() throws {
        let exception = httpException(
            400,
            #"{"code":"INVALID_REQUEST","message":"password: 비밀번호는 영문, 숫자, 특수문자를 각각 하나 이상 포함해야 합니다."}"#
        ).toAuthException()

        #expect(exception.error == .invalidRequest)
        #expect(try #require(exception.serverMessage).hasPrefix("password: "))
    }

    /// 토큰 계열 USER001~005 와 사용자 없음 USER103 은 앱 대응이 "재로그인" 하나로 같다.
    @Test("토큰 계열 코드는 세션 만료 하나로 뭉친다")
    func tokenCodesAreSessionExpired() {
        let cases: [(Int, String)] = [
            (401, #"{"code":"USER001","message":"유효하지 않은 토큰입니다."}"#),
            (401, #"{"code":"USER002","message":"만료된 토큰입니다."}"#),
            (401, #"{"code":"USER003","message":"토큰 용도가 올바르지 않습니다."}"#),
            (401, #"{"code":"USER004","message":"다시 로그인해 주세요."}"#),
            (401, #"{"code":"USER005","message":"로그인이 필요합니다."}"#),
            (404, #"{"code":"USER103","message":"존재하지 않는 사용자입니다."}"#),
        ]

        for (status, body) in cases {
            #expect(httpException(status, body).toAuthException().error == .sessionExpired, "\(body)")
        }
    }

    @Test("code 없는 응답은 상태 코드로 폴백한다")
    func fallsBackToStatusCode() {
        // 스프링이 직접 만드는 404 처럼 ErrorResponse shape 이 아닌 본문.
        #expect(httpException(400, "").toAuthException().error == .invalidRequest)
        #expect(httpException(500, "<html>oops</html>").toAuthException().error == .unknown)
    }

    @Test("연결 실패는 NETWORK 로 매핑되고 서버 메시지는 없다")
    func connectionFailure() {
        let exception = IOException("failed to connect").toAuthException()

        #expect(exception.error == .network)
        #expect(exception.serverMessage == nil)
    }

    @Test("AuthPolicy 는 서버 검증 규칙과 같은 판정을 낸다")
    func authPolicyMatchesServer() {
        #expect(AuthPolicy.isValidLoginId(value: "moyeota_1"))
        #expect(!AuthPolicy.isValidLoginId(value: "1moyeota"), "숫자로 시작하면 안 된다")
        #expect(!AuthPolicy.isValidLoginId(value: "abc"), "4자 미만은 안 된다")
        #expect(!AuthPolicy.isValidLoginId(value: "Moyeota"), "대문자는 안 된다")

        #expect(AuthPolicy.isValidPassword(value: "Passw0rd!"))
        #expect(!AuthPolicy.isValidPassword(value: "Password1"), "특수문자가 없다")
        #expect(!AuthPolicy.isValidPassword(value: "Pa0!"), "8자 미만이다")

        #expect(AuthPolicy.isValidPhoneNumber(value: "010-1234-5678"))
        #expect(AuthPolicy.isValidPhoneNumber(value: "01012345678"), "하이픈 없이도 통과한다")
        #expect(!AuthPolicy.isValidPhoneNumber(value: "02-123-4567"))
    }

    /// 서버 도메인 VO `Nickname` 과 같은 판정이어야 왕복 400 을 줄일 수 있다.
    @Test("닉네임 규칙은 서버 Nickname VO 와 같다")
    func nicknamePolicy() {
        #expect(AuthPolicy.isValidNickname(value: "모여타"))
        #expect(AuthPolicy.isValidNickname(value: "moyeota99"), "영문·숫자 혼용도 통과한다")
        #expect(AuthPolicy.isValidNickname(value: "  모여타  "), "서버도 strip 한 뒤 검사한다")
        #expect(!AuthPolicy.isValidNickname(value: "김"), "2자 미만은 안 된다")
        #expect(!AuthPolicy.isValidNickname(value: "가나다라마바사아자차카"), "10자 초과는 안 된다")
        #expect(!AuthPolicy.isValidNickname(value: "모여 타"), "가운데 공백은 안 된다")
        #expect(!AuthPolicy.isValidNickname(value: "모여타!"), "특수문자는 안 된다")
        #expect(!AuthPolicy.isValidNickname(value: "ㄱㄴㄷ"), "자모 낱자는 안 된다")
    }

    private func httpException(_ code: Int, _ body: String) -> HttpException {
        HttpException(Response<Void>.error(code, body))
    }
}
