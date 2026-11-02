import MoyeotaDomain
import Testing
@testable import PresentationCore

/// 기능 모듈에서 PresentationCore 로 옮겨 온 규칙들.
@Suite struct MovedSymbolsTest {
    // ─── authUserMessage (원본 SignupDraftTest 의 해당 부분) ───

    @Test("번호 형식 오류는 발송과 확인 어느 쪽에서 와도 같은 안내로 모인다")
    func phoneFormatMessagesConverge() {
        let fromVerify = authErrorMessage(error: .invalidPhoneNumber)
        let fromSend = authErrorMessage(error: .invalidRequest, serverMessage: "phoneNumber: 올바른 형식이 아닙니다")
        #expect(fromVerify == fromSend)
    }

    @Test("AuthException 이 아닌 예외는 안내 문구로 뭉갠다")
    func nonAuthErrorsCollapse() {
        #expect(IllegalStateException("boom").authUserMessage() == "잠시 후 다시 시도해 주세요")
        #expect(
            AuthException(error: .phoneNotVerified).authUserMessage()
                == authErrorMessage(error: .phoneNotVerified)
        )
    }

    @Test("서버 원문을 우선하되 닉네임 형식 오류는 한 문구로 모은다")
    func invalidRequestMessages() {
        #expect(authErrorMessage(error: .invalidRequest, serverMessage: "nickname: x") == authErrorMessage(error: .invalidNickname))
        #expect(authErrorMessage(error: .invalidRequest, serverMessage: "email: 형식") == "email: 형식")
        #expect(authErrorMessage(error: .invalidRequest) == "입력한 정보를 다시 확인해 주세요")
    }

    @Test("숫자가 든 문구는 도메인 상수를 끼워 쓴다")
    func policyNumbersInMessages() {
        #expect(authErrorMessage(error: .rejoinRestricted).hasPrefix("탈퇴한 번호는 30일 동안"))
        #expect(authErrorMessage(error: .smsDailyLimitExceeded).contains("하루 5번"))
        #expect(authErrorMessage(error: .smsTooManyAttempts).hasPrefix("인증번호를 5번"))
    }

    // ─── NicknamePolicy ───

    @Test("닉네임 규칙 - 왜 틀렸는지를 말한다")
    func nicknameValidation() {
        #expect(NicknamePolicy.validate(raw: "  ") == "닉네임을 입력해 주세요")
        #expect(NicknamePolicy.validate(raw: "성 윤") == "한글·영문·숫자만 쓸 수 있어요 (공백·특수문자·이모지 불가)")
        #expect(NicknamePolicy.validate(raw: "성윤!") == "한글·영문·숫자만 쓸 수 있어요 (공백·특수문자·이모지 불가)")
        #expect(NicknamePolicy.validate(raw: "가") == "닉네임은 2~10자로 입력해 주세요")
        #expect(NicknamePolicy.validate(raw: "가나다라마바사아자차카") == "닉네임은 2~10자로 입력해 주세요")
        #expect(NicknamePolicy.validate(raw: "모여타짱") == "사용할 수 없는 닉네임이에요")
        #expect(NicknamePolicy.validate(raw: "xadminx") == "사용할 수 없는 닉네임이에요")
        #expect(NicknamePolicy.validate(raw: " 길동이 ") == nil)
        #expect(NicknamePolicy.isValid(raw: "abc123"))
        #expect(NicknamePolicy.MAX_LENGTH == 10)
    }

    /// 자모로 풀어 쓴 「가」는 서버가 거절한다 — 문자소 단위 비교로 통과시키면 안 된다.
    @Test("닉네임 규칙 - 풀어 쓴 한글(NFD)은 문자 규칙에서 걸린다")
    func nicknameRejectsDecomposedHangul() {
        #expect(NicknamePolicy.validate(raw: "\u{1100}\u{1161}\u{1100}\u{1161}") == "한글·영문·숫자만 쓸 수 있어요 (공백·특수문자·이모지 불가)")
    }

    // ─── ChatForeground ───

    @Test("화면에 떠 있는 채팅방 id 를 적고 지운다")
    func chatForeground() {
        ChatForeground.visibleRoomId = 9
        #expect(ChatForeground.visibleRoomId == 9)
        ChatForeground.visibleRoomId = nil
        #expect(ChatForeground.visibleRoomId == nil)
    }
}
