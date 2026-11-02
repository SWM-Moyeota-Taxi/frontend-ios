import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

// 원본에 없는 테스트. 원본은 이 규칙들을 화면 본문에 두어 단위 테스트가 없다.
// 문구·경계값이 그대로 옮겨졌는지 뷰 없이 확인한다.

@Suite struct ProfileSetupValidationTest {
    private let today = date(2026, 11, 2)
    private let verified = PhoneVerifyState(stage: .verified, boundPhone: "01012345678", token: "tok-1")

    private func validate(
        nickname: String = "모여",
        realName: String = "홍길동",
        birthDigits: String = "19950315",
        gender: Gender? = .female,
        phoneDigits: String = "01012345678",
        loginId: String = "moyeota",
        password: String = "abcd1234!",
        email: String = "moyeota@example.com",
        nicknameCheck: NicknameCheckState = .available,
        phoneVerify: PhoneVerifyState? = nil
    ) -> ProfileSetupValidation {
        ProfileSetupValidation(
            nickname: nickname,
            realName: realName,
            birthDigits: birthDigits,
            gender: gender,
            phoneDigits: phoneDigits,
            loginId: loginId,
            password: password,
            email: email,
            today: today,
            nicknameCheck: nicknameCheck,
            phoneVerify: phoneVerify ?? verified
        )
    }

    @Test("다 채우고 인증까지 끝내면 다음이 열린다")
    func allFilled() {
        #expect(validate().isValid)
    }

    @Test("문자 인증을 끝내지 않으면 다음이 닫힌다")
    func needsVerification() {
        #expect(!validate(phoneVerify: PhoneVerifyState()).isValid)
    }

    @Test("중복 확인이 진행 중이거나 실패해도 다음은 막지 않는다", arguments: [
        NicknameCheckState.idle, .checking, .unknown,
    ])
    func unknownDoesNotBlock(check: NicknameCheckState) {
        #expect(validate(nicknameCheck: check).isValid)
    }

    @Test("닉네임 중복·서버 형식 오류는 각자 문구를 낸다")
    func nicknameServerErrors() {
        #expect(validate(nicknameCheck: .taken).nicknameError == "이미 사용 중인 닉네임이에요")
        #expect(validate(nicknameCheck: .invalidFormat).nicknameError == "닉네임은 한글·영문·숫자 2~10자로 입력해 주세요")
        #expect(!validate(nicknameCheck: .taken).isValid)
    }

    @Test("빈 닉네임은 오류를 말하지 않지만 다음은 닫힌다")
    func emptyNickname() {
        let result = validate(nickname: "", nicknameCheck: .idle)
        #expect(result.nicknameError == nil)
        #expect(!result.isValid)
    }

    @Test("이름은 한글 또는 영문 2~20자다")
    func realName() {
        #expect(validate(realName: "").realNameError == nil)
        #expect(validate(realName: "홍").realNameError == "이름은 한글 또는 영문 2~20자로 입력해 주세요")
        #expect(validate(realName: "John").realNameError == nil)
    }

    @Test("휴대폰 문구는 원본 분기 순서 그대로다")
    func phoneMessages() {
        #expect(validate(phoneDigits: "").phoneError == nil)
        // 1·2자리는 3..10 범위 밖이라 원본에서도 형식 문구가 뜬다.
        #expect(validate(phoneDigits: "0").phoneError == "휴대폰 번호는 010 + 숫자 8자리로 입력해 주세요")
        #expect(validate(phoneDigits: "01").phoneError == "휴대폰 번호는 010 + 숫자 8자리로 입력해 주세요")
        #expect(validate(phoneDigits: "010").phoneError == nil)
        #expect(validate(phoneDigits: "0101234567").phoneError == nil)
        #expect(validate(phoneDigits: "01112345678").phoneError == "010으로 시작하는 휴대폰 번호만 입력할 수 있어요")
        #expect(validate(phoneDigits: "01012345678").phoneError == nil)
    }

    @Test("생년월일이 만 14세 미만이면 다음이 닫힌다")
    func underAge() {
        let result = validate(birthDigits: "20121103")
        #expect(result.birthDate != nil)
        #expect(result.birthError == "만 14세 미만은 가입할 수 없어요. 생년월일을 다시 확인해 주세요")
        #expect(!result.isValid)
        #expect(validate(birthDigits: "20121102").isValid)
    }

    @Test("로그인 정보 문구")
    func accountMessages() {
        #expect(validate(loginId: "Abc").loginIdError == "영소문자로 시작하는 영소문자·숫자·_ 4~20자로 입력해 주세요")
        #expect(validate(password: "abcd1234").passwordError == "영문·숫자·특수문자를 각각 하나 이상 포함해 8자 이상")
        #expect(validate(email: "abc").emailError == "이메일 형식으로 입력해 주세요")
        let tooLong = String(repeating: "a", count: 90) + "@example.com"
        #expect(validate(email: tooLong).emailError == "이메일은 100자를 넘을 수 없어요")
        #expect(validate(loginId: "", password: "", email: "").loginIdError == nil)
        #expect(!validate(email: "").isValid)
    }

    @Test("입력 거르기는 원본 길이 단위(UTF-16)를 따른다")
    func inputFilters() {
        #expect(withoutWhitespace(" 모 여\u{3000}타\t") == "모여타")
        #expect(takeUtf16("가나다라", 2) == "가나")
        #expect(takeUtf16("ab", 5) == "ab")
        #expect(takeUtf16("a😀b", 3) == "a😀")
    }
}

@Suite struct AuthScreenRulesTest {
    @Test("학교 이메일 로컬파트 규칙")
    func localPart() {
        #expect(LocalPartRegex.matches("ab"))
        #expect(LocalPartRegex.matches("a.b_c-d"))
        #expect(!LocalPartRegex.matches("a"))
        #expect(!LocalPartRegex.matches("한글"))
        #expect(!LocalPartRegex.matches(String(repeating: "a", count: 65)))
        #expect(SupportedDomains == ["@pusan.ac.kr", "@pukyong.ac.kr", "@donga.ac.kr"])
    }

    @Test("회사 이메일은 형식과 무료 메일을 다른 문구로 거른다")
    func workEmail() {
        #expect(WorkEmailValidation(email: "").fieldError == nil)
        #expect(!WorkEmailValidation(email: "").emailValid)
        #expect(WorkEmailValidation(email: "abc").fieldError == "이메일 형식이 올바르지 않아요")
        #expect(WorkEmailValidation(email: "a@GMAIL.com").fieldError == "무료 메일(gmail·naver 등)은 사용할 수 없어요")
        #expect(!WorkEmailValidation(email: "a@naver.com").emailValid)
        let company = WorkEmailValidation(email: "name@company.com")
        #expect(company.emailValid)
        #expect(company.fieldError == nil)
    }

    @Test("인증 코드 남은 시간 형식")
    func secondsFormat() {
        #expect(formatSeconds(total: 271) == "4:31")
        #expect(formatSeconds(total: 600) == "10:00")
        #expect(formatSeconds(total: 0) == "0:00")
    }

    @Test("매너 서약 항목은 넷이고 문구가 그대로다")
    func pledgeItems() {
        #expect(mannerPledgeItems == [
            PledgeItem("이용약관 · 개인정보 수집에 동의해요", "실명·생년월일·연락처는 본인 확인에만 써요"),
            PledgeItem("약속한 시간과 장소를 지킬게요", "무단 취소가 반복되면 이용이 제한돼요"),
            PledgeItem("불쾌한 말과 행동을 하지 않을게요", "채팅방에서 메시지를 길게 눌러 신고할 수 있어요"),
            PledgeItem("매칭이 확정되면 꼭 나갈게요", "매칭 확정 후 오지 않으면 이용이 제한될 수 있어요"),
        ])
    }
}
