import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureMyPage

/// 37 회원 탈퇴의 순수 로직 — 제출 가능 판정, 실패를 어디에 그릴지, 경고 문구가 서버 동작과 맞는지.
///
/// 문구를 테스트하는 게 과해 보일 수 있지만 **여기서는 문구가 계약이다.** 지워지지 않는 것을
/// 지워진다고 적으면 스토어 심사와 개인정보처리방침 양쪽에 걸리고, 되돌릴 수 없는 동작이라
/// 사용자가 그 문구를 믿고 누른 뒤에는 고칠 기회가 없다.
@Suite struct AccountDeleteRulesTest {

    // ─────────────────────────── 제출 가능 판정 ───────────────────────────

    @Test("비밀번호를 쓰면 탈퇴를 누를 수 있다")
    func passwordEnablesSubmit() {
        #expect(canSubmitAccountDeletion(password: "Passw0rd!"))
    }

    @Test("빈 비밀번호로는 누를 수 없다 - 서버 NotBlank 에 걸릴 요청이다")
    func emptyCannotSubmit() {
        #expect(!canSubmitAccountDeletion(password: ""))
    }

    /// 공백만 넣으면 서버가 400 `INVALID_REQUEST` 를 주는데, 그 문구("입력한 정보를 다시 확인해
    /// 주세요")로는 사용자가 무엇을 고쳐야 할지 모른다. 보내기 전에 막는다.
    @Test("공백만 넣어도 누를 수 없다")
    func blankCannotSubmit() {
        #expect(!canSubmitAccountDeletion(password: "   "))
        #expect(!canSubmitAccountDeletion(password: "\t"))
    }

    /// 중복 제출 차단(공통 규칙). 탈퇴는 멱등이 아니다 — 두 번째는 404·401 이 된다.
    @Test("보내는 중에는 다시 누를 수 없다")
    func submittingCannotSubmit() {
        #expect(!canSubmitAccountDeletion(password: "Passw0rd!", submitting: true))
    }

    /// **앱이 비밀번호 규칙을 다시 검사하지 않는다.** 서버는 `@NotBlank` 만 보고 해시를 비교하므로
    /// (`UserDeletionRequest`), `AuthPolicy.isValidPassword` 로 좁히면 규칙이 바뀌기 전에 가입한
    /// 계정이 **자기 비밀번호를 정확히 넣고도 버튼을 못 누르는** 상태가 된다.
    @Test("가입 규칙에 안 맞는 비밀번호도 보낼 수 있다 - 판정은 서버가 한다")
    func passwordOutsideSignupRulesCanSubmit() {
        let tooShort = "a1!"
        #expect(!AuthPolicy.isValidPassword(value: tooShort), "전제가 깨졌다 — 이 값이 가입 규칙을 통과한다")

        #expect(canSubmitAccountDeletion(password: tooShort))
    }

    // ─────────────────────────── 실패를 어디에 그리는가 ───────────────────────────

    /// 비밀번호 오타만 입력란 오류다 — 이 화면에서 고칠 수 있는 유일한 실패다.
    /// 나머지를 입력란으로 보내면 고칠 게 없는데 입력란이 빨개져 사용자가 비밀번호를 계속 다시 친다.
    @Test("비밀번호 불일치만 입력란으로 간다")
    func onlyMismatchGoesToField() {
        #expect(accountDeleteErrorSlot(error: .passwordMismatch) == .passwordField)
    }

    @Test("이 화면에서 못 고치는 실패는 전부 배너로 간다")
    func everythingElseGoesToBanner() {
        let errors: [AuthError] = [
            // 합승 화면에서 나와야 풀린다
            .ongoingPartyExists,
            // 기다려야 한다
            .network,
            // 로그인으로 가야 한다
            .sessionExpired,
            .unknown,
            .invalidRequest,
        ]
        for error in errors {
            #expect(accountDeleteErrorSlot(error: error) == .banner, "\(error.rawValue)")
        }
    }

    // ─────────────────────────── 문구 ───────────────────────────

    /// 탈퇴 계열 셋이 서로 다른 말을 해야 한다. 특히 둘은 **같은 409** 라 한 문구로 뭉치기 쉽다:
    /// `USER109`(재가입 제한)와 `USER110`(진행 중 합승)은 할 일이 전혀 다르다.
    @Test("탈퇴 계열 세 에러가 서로 다른 말을 한다")
    func threeErrorsSayDifferentThings() {
        let messages = [AuthError.ongoingPartyExists, .passwordMismatch, .rejoinRestricted]
            .map { authErrorMessage(error: $0) }

        #expect(messages.count == Set(messages).count, "문구가 겹친다: \(messages)")
        for message in messages {
            #expect(!message.isBlank, "빈 문구가 있다")
            // 409 폴백 문구가 새어 나오면 탈퇴 화면에 아이디 이야기가 뜬다 — 그 자체가 결함 신호다.
            #expect(!message.contains("아이디"), "409 폴백 문구가 섞였다: \(message)")
        }
    }

    /// 진행 중 합승 안내는 **무엇을 먼저 해야 하는지**를 말해야 한다. "잠시 후 다시"로는 영영 안 풀린다.
    @Test("진행 중 합승 안내는 합승에서 나가라고 말한다")
    func ongoingPartySaysLeaveFirst() {
        let message = authErrorMessage(error: .ongoingPartyExists)

        #expect(message.contains("합승"), "\(message)")
        #expect(message.contains("나간"), "\(message)")
    }

    /// 재가입 제한 기간은 서버 `UserDeletions.RETENTION` 과 같은 수여야 한다.
    @Test("재가입 제한 안내의 기간은 서버 상수를 따른다")
    func rejoinPeriodFollowsServerConstant() {
        #expect(AuthPolicy.REJOIN_RESTRICTED_DAYS == 30)
        #expect(authErrorMessage(error: .rejoinRestricted).contains("\(AuthPolicy.REJOIN_RESTRICTED_DAYS)일"))
    }

    // ─────────────────────────── 경고 목록 ───────────────────────────

    /// 네 줄 전부 서버가 실제로 하는 일이어야 한다. 근거는 `UserDeletionService.delete` 와
    /// `ChatRoomUserDeletionListener`·`FavoritePlaceUserDeletionListener` 다.
    @Test("경고 목록은 서버가 실제로 하는 네 가지를 말한다")
    func warningsSayFourThings() {
        let all = AccountDeletionWarnings.joined(separator: " ")

        #expect(AccountDeletionWarnings.count == 4)
        // localUsers.deleteByUserId — 아이디·비밀번호가 삭제된다
        #expect(all.contains("로그인"), "\(all)")
        // ChatRoomUserDeletionListener + User.DELETED_DISPLAY_NAME
        #expect(all.contains("채팅방"), "\(all)")
        #expect(all.contains("탈퇴한 사용자"), "\(all)")
        // FavoritePlaceUserDeletionListener
        #expect(all.contains("자주 가는 곳"), "\(all)")
        // userDeletions.record → SmsVerificationService.send 의 USER109
        #expect(all.contains("\(AuthPolicy.REJOIN_RESTRICTED_DAYS)일"), "\(all)")
    }

    /// **서버가 하지 않는 일을 약속하지 않는다.** 지난 합승 기록은 지워지지 않는다 —
    /// 끝난 방의 멤버로는 남고 이름만 「탈퇴한 사용자」로 가려진다. "모든 기록이 사라져요" 같은
    /// 문구를 넣으면 지킬 수 없는 약속이 된다(docs/BACKEND-GAP-CLEANUP.md 의 원칙).
    @Test("경고 목록은 지워지지 않는 것을 지워진다고 말하지 않는다")
    func warningsDoNotOverpromise() {
        let all = AccountDeletionWarnings.joined(separator: " ")

        for forbidden in ["모든 기록", "탑승 기록", "전부 삭제", "모두 삭제"] {
            #expect(!all.contains(forbidden), "서버가 하지 않는 일을 약속한다: \(forbidden)")
        }
    }

    /// 진행 중 합승 제약은 경고가 아니라 **실패 사유**다. 앱은 "지금 내가 타고 있는 방"을 서버에
    /// 물을 수 없어(그 엔드포인트가 없다) 미리 알 수 없고, 눌러 본 뒤 409 로 알게 된다.
    /// 경고 목록에 섞으면 합승이 없는 사용자에게도 못 할 것처럼 읽힌다.
    @Test("진행 중 합승은 경고가 아니라 실패 사유로 다룬다")
    func ongoingPartyIsNotAWarning() {
        let all = AccountDeletionWarnings.joined(separator: " ")

        #expect(!all.contains("진행 중"), "경고 목록이 실패 사유를 미리 말한다: \(all)")
    }
}
