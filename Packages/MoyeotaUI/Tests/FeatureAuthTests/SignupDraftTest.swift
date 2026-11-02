import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

/// 가입 초안의 제출 가능 판정과 에러 문구 표.
///
/// 토큰 누락은 **서버에서 400 `INVALID_REQUEST` 로만 드러나고**, 그 문구는 "입력한 정보를 다시
/// 확인해 주세요"라서 사용자도 개발자도 원인을 못 짚는다. 그래서 제출 전에 걸러내는 조건을 고정한다.
@Suite struct SignupDraftTest {
    private let filled = SignupDraft(
        email: "moyeota@example.com",
        nickname: "모여",
        name: "홍길동",
        phoneNumber: "01012345678",
        birthDate: date(1995, 3, 15),
        gender: .female,
        loginId: "moyeota",
        password: "abcd1234!",
        verificationToken: "tok-1"
    )

    /// `copy(...)` 자리.
    private func filledWith(_ change: (inout SignupDraft) -> Void) -> SignupDraft {
        var draft = filled
        change(&draft)
        return draft
    }

    @Test("아홉 값이 다 차면 가입 요청으로 바뀐다")
    func nineValues() throws {
        let newUser = try #require(filled.toNewUser())
        #expect(newUser.verificationToken == "tok-1")
        #expect(newUser.phoneNumber == "01012345678")
    }

    @Test("문자 인증 토큰이 비면 제출하지 않는다 - 보내면 전부 400 이다")
    func emptyToken() {
        #expect(filledWith { $0.verificationToken = "" }.toNewUser() == nil)
    }

    @Test("닉네임은 앞뒤 공백을 떼고 담는다 - 서버도 strip 후 검사한다")
    func trimsNickname() {
        #expect(filledWith { $0.nickname = "  모여  " }.toNewUser()?.nickname == "모여")
    }

    @Test("빈 초안은 제출되지 않는다")
    func emptyDraft() {
        #expect(SignupDraft().toNewUser() == nil)
    }

    // ─────────────────────────────── 성별 ───────────────────────────────
    //
    // 「선택 안 함」(Gender.undisclosed)이 생기면서 **비슷해 보이지만 반대인 두 상태**가 생겼다:
    //  · gender == nil         → 아직 고르지 않았다 → 제출 불가
    //  · gender == undisclosed → 밝히지 않기로 **골랐다** → 제출된다
    // 둘을 한쪽으로 뭉개면 성별이 선택 사항이 되거나(서버 @NotNull 위반 → 400) 비공개를
    // 고른 사람이 가입을 못 하게 된다. 그래서 양방향을 함께 못 박는다.

    @Test("성별을 선택 안 함으로 골라도 가입 요청이 만들어진다")
    func undisclosedSubmits() throws {
        let newUser = try #require(filledWith { $0.gender = .undisclosed }.toNewUser())
        // 값이 비거나 다른 성별로 바뀌어 실리지 않는다 — data 매퍼가 이 이름을 그대로 보낸다
        #expect(newUser.gender == .undisclosed)
    }

    @Test("성별을 고르지 않으면 제출하지 않는다 - 선택 안 함과 미선택은 다르다")
    func noGender() {
        #expect(filledWith { $0.gender = nil }.toNewUser() == nil)
    }

    /// 성별 상수가 더 늘어도 **제출 가능 여부가 값에 따라 갈리지 않는다.** 특정 값만 통과시키는
    /// 분기가 생기면 "고를 수는 있는데 가입은 안 되는 선택지"가 만들어진다.
    @Test("모든 성별 값으로 가입 요청이 만들어진다")
    func everyGender() {
        for gender in Gender.allCases {
            #expect(filledWith { $0.gender = gender }.toNewUser() != nil, "\(gender.name)")
        }
    }

    // ─────────────────────────────── 에러 문구 표 ───────────────────────────────

    @Test("같은 상태 코드로 뭉쳐 오는 실패들이 서로 다른 말을 한다")
    func groupedStatusesDiffer() {
        // 429 세 개 — "잠시 후 다시 시도" 하나로 뭉치면 일일 한도에 걸린 사용자가 1분마다 재전송을 누른다
        let tooManyRequests = [AuthError.smsCooldown, .smsDailyLimitExceeded, .smsTooManyAttempts]
            .map { authErrorMessage(error: $0) }
        #expect(Set(tooManyRequests).count == 3, "\(tooManyRequests)")

        // 400 세 개 — 되돌릴 단계가 서로 다르다(재입력 / 재발송 / 인증 처음부터)
        let badRequests = [AuthError.smsCodeMismatch, .smsCodeExpired, .phoneNotVerified]
            .map { authErrorMessage(error: $0) }
        #expect(Set(badRequests).count == 3, "\(badRequests)")
    }

    @Test("모든 AuthError 에 문구가 있다 - 빈 문구나 코드 이름이 새어 나가면 안 된다")
    func everyErrorHasMessage() {
        for error in AuthError.allCases {
            let message = authErrorMessage(error: error)
            #expect(!message.isBlank, "\(error.name)")
            #expect(!message.contains(error.name), "\(error.name)")
        }
    }

    @Test("서버 제한값은 문구에 직접 적지 않고 도메인 상수를 쓴다")
    func limitsFromPolicy() {
        #expect(authErrorMessage(error: .smsDailyLimitExceeded).contains("하루 5번"))
        #expect(authErrorMessage(error: .smsTooManyAttempts).contains("5번"))
    }

    @Test("번호 형식 오류는 발송과 확인 어느 쪽에서 와도 같은 안내로 모인다")
    func phoneFormatSameMessage() {
        let fromVerify = authErrorMessage(error: .invalidPhoneNumber)
        let fromSend = authErrorMessage(error: .invalidRequest, serverMessage: "phoneNumber: 올바른 형식이 아닙니다")
        #expect(fromVerify == fromSend)
    }

    @Test("AuthException 이 아닌 예외는 안내 문구로 뭉갠다")
    func nonAuthError() {
        #expect(IllegalStateException("boom").authUserMessage() == "잠시 후 다시 시도해 주세요")
        #expect(
            AuthException(error: .phoneNotVerified).authUserMessage()
                == authErrorMessage(error: .phoneNotVerified)
        )
    }
}
