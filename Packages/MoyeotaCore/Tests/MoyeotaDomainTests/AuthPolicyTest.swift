import Testing
@testable import MoyeotaDomain

/// 원본 판정(java.util.regex·UTF-16 `length`·Kotlin 문자 판정)과 Swift 기본값이 갈리는 자리를 못 박는다.
/// 원본 테스트(`AuthMappersTest`·`BirthDateRulesTest`)는 그쪽 계층을 옮길 때 함께 옮긴다.
@Suite struct AuthPolicyTest {
    @Test("정규식 상수는 원본과 글자까지 같다")
    func patternsAreVerbatim() {
        #expect(AuthPolicy.LOGIN_ID_PATTERN == "^[a-z][a-z0-9_]{3,19}$")
        #expect(AuthPolicy.PASSWORD_PATTERN == "^(?=.*[A-Za-z])(?=.*\\d)(?=.*[!@#$%^&*()_+\\-=\\[\\]{};':\"\\\\|,.<>/?]).+$")
        #expect(AuthPolicy.PHONE_PATTERN == "^01[016-9]-?\\d{3,4}-?\\d{4}$")
        #expect(AuthPolicy.NICKNAME_PATTERN == "^[가-힣a-zA-Z0-9]{2,10}$")
    }

    @Test("아이디 형식")
    func loginId() {
        #expect(AuthPolicy.isValidLoginId(value: "moyeota_1"))
        #expect(AuthPolicy.isValidLoginId(value: "abcd"))
        #expect(!AuthPolicy.isValidLoginId(value: "abc"))
        #expect(!AuthPolicy.isValidLoginId(value: "1abcd"))
        #expect(!AuthPolicy.isValidLoginId(value: "Abcd"))
        #expect(!AuthPolicy.isValidLoginId(value: "abcd\n"))
        #expect(!AuthPolicy.isValidLoginId(value: String(repeating: "a", count: 21)))
    }

    @Test("비밀번호는 UTF-16 길이로 8~64자, 영문·ASCII 숫자·특수문자를 모두 포함")
    func password() {
        #expect(AuthPolicy.isValidPassword(value: "abcd123!"))
        #expect(!AuthPolicy.isValidPassword(value: "abc123!"))
        #expect(!AuthPolicy.isValidPassword(value: "abcdefgh!"))
        #expect(!AuthPolicy.isValidPassword(value: "12345678!"))
        #expect(!AuthPolicy.isValidPassword(value: "abcd12345"))
        #expect(AuthPolicy.isValidPassword(value: "a1\\" + String(repeating: "b", count: 61)))
        #expect(!AuthPolicy.isValidPassword(value: "a1!" + String(repeating: "b", count: 62)))
        // 아랍 숫자는 Java `\d` 가 아니다.
        #expect(!AuthPolicy.isValidPassword(value: "abcdefg٣!"))
        // 줄 끝 문자는 `.` 이 넘지 못한다. 그러나 `\u{0B}` 은 Java 의 줄 끝 문자가 아니다.
        #expect(!AuthPolicy.isValidPassword(value: "abcd123!\n"))
        #expect(!AuthPolicy.isValidPassword(value: "abcd\r123!"))
        #expect(AuthPolicy.isValidPassword(value: "abcd123!\u{0B}"))
        // 이모지 하나는 Kotlin `length` 로 2다 — 7글자로 보여도 8 로 센다.
        #expect(AuthPolicy.isValidPassword(value: "ab1!😀cd"))
        // `A-Za-z` 를 뺀 특수문자 전부가 글자 묶음 안에 있다.
        for special in "!@#$%^&*()_+-=[]{};':\"\\|,.<>/?" {
            #expect(AuthPolicy.isValidPassword(value: "abcd1234\(special)"), "\(special)")
        }
        #expect(!AuthPolicy.isValidPassword(value: "abcd1234~"))
    }

    @Test("전화번호")
    func phone() {
        #expect(AuthPolicy.isValidPhoneNumber(value: "01012345678"))
        #expect(AuthPolicy.isValidPhoneNumber(value: "010-1234-5678"))
        #expect(AuthPolicy.isValidPhoneNumber(value: "011-123-4567"))
        #expect(!AuthPolicy.isValidPhoneNumber(value: "012-1234-5678"))
        #expect(!AuthPolicy.isValidPhoneNumber(value: "010-1234-567"))
        #expect(!AuthPolicy.isValidPhoneNumber(value: "010-1234-5678\n"))
        #expect(!AuthPolicy.isValidPhoneNumber(value: "٠١٠١٢٣٤٥٦٧٨"))
        #expect(!AuthPolicy.isValidPhoneNumber(value: "010١٢٣٤٥٦٧٨"))
    }

    @Test("닉네임은 앞뒤 공백을 떼고 코드포인트 단위로 2~10자")
    func nickname() {
        #expect(AuthPolicy.isValidNickname(value: "모여타"))
        #expect(AuthPolicy.isValidNickname(value: "  moyeota1 "))
        #expect(AuthPolicy.isValidNickname(value: "가힣"))
        #expect(!AuthPolicy.isValidNickname(value: "가"))
        #expect(!AuthPolicy.isValidNickname(value: "가 나"))
        #expect(!AuthPolicy.isValidNickname(value: "닉네임!"))
        #expect(!AuthPolicy.isValidNickname(value: "abcdefghijk"))
        // 자모로 풀어 쓴 「가」는 `[가-힣]` 이 아니다.
        #expect(!AuthPolicy.isValidNickname(value: "\u{1100}\u{1161}\u{1100}\u{1161}"))
        // 한글 자모 호환 영역도 아니다.
        #expect(!AuthPolicy.isValidNickname(value: "ㄱㄴ"))
    }

    @Test("전화번호 정규화는 하이픈과 Kotlin 공백을 뗀다")
    func normalize() {
        #expect(AuthPolicy.normalizePhoneNumber(value: " 010-1234 5678\n") == "01012345678")
        #expect(AuthPolicy.normalizePhoneNumber(value: "010\u{00A0}1234\u{3000}5678\u{1C}") == "01012345678")
        // U+0085 는 Kotlin 공백이 아니다.
        #expect(AuthPolicy.normalizePhoneNumber(value: "010\u{85}") == "010\u{85}")
    }

    @Test("인증번호는 UTF-16 6칸의 유니코드 숫자")
    func verificationCode() {
        #expect(AuthPolicy.isValidVerificationCode(value: "000000"))
        #expect(!AuthPolicy.isValidVerificationCode(value: "00000"))
        #expect(!AuthPolicy.isValidVerificationCode(value: "0000000"))
        #expect(!AuthPolicy.isValidVerificationCode(value: "00000a"))
        // Kotlin `isDigit` 은 유니코드 Nd 전부를 받는다 — 서버가 400 으로 거른다.
        #expect(AuthPolicy.isValidVerificationCode(value: "٠١٢٣٤٥"))
        // BMP 밖 숫자는 UTF-16 으로 두 칸이고 칸마다 숫자가 아니다.
        #expect(!AuthPolicy.isValidVerificationCode(value: "𝟎𝟏𝟐"))
        // 로마 숫자는 Nd 가 아니다.
        #expect(!AuthPolicy.isValidVerificationCode(value: "ⅠⅡⅢⅣⅤⅥ"))
    }

    @Test("만 나이 경계")
    func oldEnough() throws {
        let today = try LocalDate.of(2026, 10, 13)
        #expect(!AuthPolicy.isOldEnough(birthDate: try LocalDate.of(2012, 10, 14), today: today))
        #expect(AuthPolicy.isOldEnough(birthDate: try LocalDate.of(2012, 10, 13), today: today))
        #expect(AuthPolicy.isOldEnough(birthDate: try LocalDate.of(2012, 10, 12), today: today))
        #expect(!AuthPolicy.isOldEnough(birthDate: try LocalDate.of(2008, 2, 29), today: try LocalDate.of(2022, 2, 27)))
        #expect(AuthPolicy.isOldEnough(birthDate: try LocalDate.of(2008, 2, 29), today: try LocalDate.of(2022, 2, 28)))
    }

    @Test("생년월일은 UTC 오늘보다 이른 날짜만")
    func birthDate() {
        let todayUtc = LocalDate.now(LocalDate.utcZone)
        #expect(AuthPolicy.isValidBirthDate(value: todayUtc.minusDays(1)))
        #expect(!AuthPolicy.isValidBirthDate(value: todayUtc.plusDays(1)))
    }
}
