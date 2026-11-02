import MoyeotaDomain
import Testing
@testable import FeatureAuth

/// 10 프로필 만들기의 문자 인증 블록 상태 전이.
///
/// 왜 테스트가 필요한가: 이 블록이 틀려도 **화면에는 아무 증상이 없다**. 토큰이 비거나 번호와
/// 어긋난 채로 제출되면 가입이 400 으로 떨어지는데, 사용자에게는 "입력한 정보를 다시 확인해
/// 주세요" 한 줄만 보인다(서버가 토큰 문제와 입력 문제를 같은 400 으로 뭉친다). 그래서
/// 전이 규칙은 뷰 밖의 순수 함수로 빼 두고 여기서 못 박는다.
///
/// 타이머는 기한(epoch millis) 기반이라 실제 시간이 흐르기를 기다리지 않는다 — `NOW` 를 옮겨 쓴다.
///
/// 원본의 `assertSame` 은 값 타입이라 `==` 로 옮겼다. 필드 하나만 달라도 실패한다.
@Suite struct PhoneVerifyStateTest {
    /// 임의의 고정 시각. 값 자체에 의미는 없고, 계산이 상대값으로만 이뤄지는지를 보려고 큰 수를 쓴다.
    private let NOW: Int64 = 1_800_000_000_000
    private let PHONE = "01012345678"
    private let CODE_TTL_MS = Int64(AuthPolicy.SMS_CODE_TTL_SECONDS) * 1000
    private let COOLDOWN_MS = Int64(AuthPolicy.SMS_RESEND_COOLDOWN_SECONDS) * 1000

    /// 발송까지 끝난 상태(= 인증번호 입력칸이 열린 상태).
    private func sent(_ now: Int64? = nil) -> PhoneVerifyState {
        PhoneVerifyState().onRequestStart(phone: PHONE).onCodeSent(nowMillis: now ?? NOW)
    }

    /// 인증까지 끝난 상태.
    private func verified(_ now: Int64? = nil) -> PhoneVerifyState {
        sent(now).onCodeChanged(raw: "123456").onVerified(verificationToken: "tok-1")
    }

    // ─────────────────────────────── 남은 초 계산·표시 ───────────────────────────────

    @Test("남은 초는 올림한다 - 0_2초 남았으면 1초로 보여야 사라지지 않는다")
    func secondsRoundUp() {
        #expect(secondsUntil(deadlineMillis: NOW + 200, nowMillis: NOW) == 1)
        #expect(secondsUntil(deadlineMillis: NOW + 1_000, nowMillis: NOW) == 1)
        #expect(secondsUntil(deadlineMillis: NOW + 1_001, nowMillis: NOW) == 2)
    }

    @Test("기한이 지났거나 없으면 0")
    func secondsZero() {
        #expect(secondsUntil(deadlineMillis: NOW, nowMillis: NOW) == 0)
        #expect(secondsUntil(deadlineMillis: NOW - 5_000, nowMillis: NOW) == 0)
        #expect(secondsUntil(deadlineMillis: NO_DEADLINE, nowMillis: NOW) == 0)
    }

    @Test("카운트다운 표시는 m ss")
    func countdownFormat() {
        #expect(formatRemainingSeconds(totalSeconds: 180) == "3:00")
        #expect(formatRemainingSeconds(totalSeconds: 65) == "1:05")
        #expect(formatRemainingSeconds(totalSeconds: 9) == "0:09")
        #expect(formatRemainingSeconds(totalSeconds: 0) == "0:00")
    }

    @Test("시계가 뒤로 가도 음수를 그리지 않는다")
    func countdownNegative() {
        #expect(formatRemainingSeconds(totalSeconds: -7) == "0:00")
    }

    // ─────────────────────────────── 발송 버튼 판정 ───────────────────────────────

    @Test("번호가 11자리 010 이면 인증번호를 받을 수 있다")
    func canRequestComplete() {
        #expect(PhoneVerifyState().canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    @Test("번호가 아직 덜 찼으면 받을 수 없다")
    func cannotRequestIncomplete() {
        #expect(!PhoneVerifyState().canRequestCode(phoneDigits: "0101234", nowMillis: NOW))
        #expect(!PhoneVerifyState().canRequestCode(phoneDigits: "", nowMillis: NOW))
        // 010 이 아닌 번호는 이 화면이 받지 않는다(안내 문구도 010 기준이다)
        #expect(!PhoneVerifyState().canRequestCode(phoneDigits: "01112345678", nowMillis: NOW))
    }

    @Test("쿨다운 중에는 받을 수 없고 끝나면 다시 받을 수 있다")
    func cooldownBlocks() {
        let state = sent()
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW + COOLDOWN_MS - 1))
        #expect(state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW + COOLDOWN_MS))
    }

    @Test("보내는 중에는 두 번 눌리지 않는다")
    func requestingBlocks() {
        #expect(!PhoneVerifyState().onRequestStart(phone: PHONE).canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    @Test("인증을 끝냈으면 더 받을 수 없다")
    func verifiedBlocks() {
        #expect(!verified().canRequestCode(phoneDigits: PHONE, nowMillis: NOW + CODE_TTL_MS))
    }

    @Test("이미 가입된 번호와 일일 한도는 재시도를 열지 않는다")
    func duplicatedAndDailyLimitBlock() {
        let duplicated = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .phoneNumberDuplicated, message: "이미", nowMillis: NOW)
        #expect(!duplicated.canRequestCode(phoneDigits: PHONE, nowMillis: NOW + COOLDOWN_MS))

        let dailyLimit = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .smsDailyLimitExceeded, message: "한도", nowMillis: NOW)
        #expect(!dailyLimit.canRequestCode(phoneDigits: PHONE, nowMillis: NOW + COOLDOWN_MS))
    }

    @Test("버튼 문구는 상태마다 다르다")
    func buttonLabels() {
        #expect(PhoneVerifyState().requestButtonLabel(nowMillis: NOW) == "인증번호 받기")
        #expect(PhoneVerifyState().onRequestStart(phone: PHONE).requestButtonLabel(nowMillis: NOW) == "인증번호 보내는 중…")
        #expect(sent().requestButtonLabel(nowMillis: NOW) == "60초 후 다시 받기")
        #expect(sent().requestButtonLabel(nowMillis: NOW + COOLDOWN_MS - 1) == "1초 후 다시 받기")
        #expect(sent().requestButtonLabel(nowMillis: NOW + COOLDOWN_MS) == "인증번호 다시 받기")
    }

    // ─────────────────────────────── 번호 변경 → 무효화 ───────────────────────────────

    @Test("번호를 고치면 인증이 무효가 된다")
    func changingNumberInvalidates() {
        let before = verified()
        #expect(before.token == "tok-1")

        let after = before.onPhoneDigitsChanged(phoneDigits: "01099998888")
        #expect(after.stage == .idle)
        #expect(after.token == "")
        #expect(after.boundPhone == "")
        #expect(after.code == "")
    }

    @Test("한 글자만 지워도 무효다 - 서버가 토큰을 번호에 묶는다")
    func deletingOneDigitInvalidates() {
        let after = verified().onPhoneDigitsChanged(phoneDigits: "0101234567")
        #expect(after.stage == .idle)
        #expect(after.token == "")
    }

    @Test("같은 번호면 상태를 그대로 둔다 - 하이픈 표기 차이는 무효화가 아니다")
    func sameNumberKeepsState() {
        let before = verified()
        #expect(before == before.onPhoneDigitsChanged(phoneDigits: PHONE))
        #expect(before == before.onPhoneDigitsChanged(phoneDigits: "010-1234-5678"))
    }

    @Test("발송 중에 번호가 바뀌면 묶인 번호도 바뀐다 - 늦게 온 응답을 버릴 근거")
    func changingWhileRequesting() {
        let requesting = PhoneVerifyState().onRequestStart(phone: PHONE)
        #expect(requesting.boundPhone == PHONE)
        let changed = requesting.onPhoneDigitsChanged(phoneDigits: "01099998888")
        // boundPhone 이 비므로 뷰모델이 "이 응답은 남의 것"이라고 판정할 수 있다
        #expect(changed.boundPhone == "")
        #expect(!changed.requesting)
    }

    @Test("번호 변경 버튼은 안내 문구를 남기지 않고 가입 거절은 남긴다")
    func invalidatedMessage() {
        #expect(verified().invalidated().phoneMessage == nil)
        #expect(verified().invalidated(message: "만료됐어요").phoneMessage == "만료됐어요")
    }

    // ─────────────────────────────── 발송 성공·실패 ───────────────────────────────

    @Test("발송 성공은 3분 만료와 1분 쿨다운을 같이 건다")
    func sentStartsBothTimers() {
        let state = sent()
        #expect(state.stage == .codeSent)
        #expect(state.codeRemainingSeconds(nowMillis: NOW) == AuthPolicy.SMS_CODE_TTL_SECONDS)
        #expect(state.resendRemainingSeconds(nowMillis: NOW) == AuthPolicy.SMS_RESEND_COOLDOWN_SECONDS)
        #expect(!state.requesting)
    }

    @Test("재발송은 입력값과 직전 오류를 비운다 - 서버도 오입력 횟수를 되돌린다")
    func resendClears() {
        let stale = sent()
            .onCodeChanged(raw: "111111")
            .onVerifyFailure(error: .smsCodeMismatch, message: "틀렸어요")
        #expect(stale.codeMessage == "틀렸어요")

        let resent = stale.onRequestStart(phone: PHONE).onCodeSent(nowMillis: NOW + COOLDOWN_MS)
        #expect(resent.code == "")
        #expect(resent.codeMessage == nil)
        #expect(resent.codeRemainingSeconds(nowMillis: NOW + COOLDOWN_MS) == AuthPolicy.SMS_CODE_TTL_SECONDS)
    }

    @Test("이미 가입된 번호는 인증번호 입력칸을 열지 않는다")
    func duplicatedKeepsCodeClosed() {
        let state = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .phoneNumberDuplicated, message: "이미 가입된 번호예요", nowMillis: NOW)
        #expect(state.stage == .idle)
        #expect(state.alreadyRegistered)
        #expect(state.phoneMessage == "이미 가입된 번호예요")
        #expect(state.codeRemainingSeconds(nowMillis: NOW) == 0)
    }

    // ───────────────────── 누르기 전 선확인(POST /auth/phone/check) ─────────────────────

    /// 선확인이 「이미 가입된 번호」라고 답하면 발송 409 와 **같은 자리로 간다** — 문구는 번호 입력란
    /// 아래, 버튼은 잠금, 인증번호 입력칸은 열지 않음. 새 상태도 새 문구도 만들지 않는다.
    @Test("누르기 전 선확인도 인증번호 입력칸을 열지 않는다")
    func precheckKeepsCodeClosed() {
        let state = PhoneVerifyState().onPhonePrecheckTaken(message: "이미 가입된 번호예요")

        #expect(state.stage == .idle)
        #expect(state.alreadyRegistered)
        #expect(state.phoneMessage == "이미 가입된 번호예요")
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    /// ★ 이 작업에서 가장 쉽게 나는 결함을 막는다.
    ///
    /// 선확인은 발송을 시도한 적이 없으므로 묶인 번호가 없다. `PhoneVerifyState.boundPhone` 을
    /// 채워 두면 `PhoneVerifyState.onPhoneDigitsChanged` 가 「같은 번호」로 보고 상태를 **그대로 둬서**,
    /// 사용자가 번호를 고쳤다 되돌릴 때 「이미 가입된 번호예요」와 잠긴 버튼이 풀리지 않는다.
    @Test("선확인은 boundPhone 을 묶지 않는다")
    func precheckDoesNotBind() {
        let blocked = PhoneVerifyState().onPhonePrecheckTaken(message: "이미 가입된 번호예요")

        #expect(blocked.boundPhone == "")
        // 같은 번호가 다시 들어와도 묶인 번호가 없으니 상태가 비워진다 → 잠금이 풀린다.
        #expect(blocked.onPhoneDigitsChanged(phoneDigits: PHONE) == PhoneVerifyState())
    }

    /// ★ 사용자가 디바운스가 끝나는 순간 「인증번호 받기」를 누르면 두 경로가 겹친다.
    ///
    /// 늦게 온 선확인이 그대로 적용되면 `PhoneVerifyState.onRequestStart` 가 켠 진행 표시를 되돌리고
    /// (그쪽은 `alreadyRegistered` 를 false 로 리셋한다) 진행 중인 발송 위에 「이미 가입된 번호」가 뜬다.
    @Test("발송이 시작된 뒤 도착한 선확인은 무시된다")
    func precheckIgnoredWhileRequesting() {
        let requesting = PhoneVerifyState().onRequestStart(phone: PHONE)

        let state = requesting.onPhonePrecheckTaken(message: "이미 가입된 번호예요")

        #expect(state == requesting)
        #expect(state.requesting)
        #expect(!state.alreadyRegistered)
        #expect(state.phoneMessage == nil)
    }

    /// 인증을 이미 끝낸 뒤 늦게 온 선확인도 같다 — 통과한 인증을 되돌리지 않는다.
    @Test("인증을 끝낸 뒤 도착한 선확인은 무시된다")
    func precheckIgnoredAfterVerified() {
        let done = verified()

        #expect(done == done.onPhonePrecheckTaken(message: "이미 가입된 번호예요"))
    }

    @Test("선확인이 켠 상태도 번호를 고치면 풀린다")
    func precheckReleasedByChange() {
        let blocked = PhoneVerifyState().onPhonePrecheckTaken(message: "이미 가입된 번호예요")

        let other = blocked.onPhoneDigitsChanged(phoneDigits: "01099998888")

        #expect(other == PhoneVerifyState())
        #expect(other.canRequestCode(phoneDigits: "01099998888", nowMillis: NOW))
    }

    /// ★★ 선확인을 붙이는 바람에 **지금보다 나빠지는** 유일한 경로를 막는다.
    ///
    /// 실측(2026-11-01, 로컬 :8080): 탈퇴한 번호는 `POST /auth/phone/check` 에서 `{"exists":false}` 200
    /// 인데 `POST /auth/sms/send` 에서는 409 `USER109` 다 — 서버가 선확인에서는 활성 프로필 한 테이블만
    /// 보고 탈퇴 기록을 보지 않는다. 즉 **`exists=false` 는 「가입 가능」이 아니다.**
    ///
    /// 그래서 `exists=false` 에는 대응하는 전이가 없고(상태가 그대로다), 버튼은 열린 채로 남아
    /// 재가입 제한은 **발송 응답에서만** 드러난다. 구현자가 false 로 버튼을 열거나
    /// `rejoinRestricted` 를 미리 끄거나 두 플래그를 하나로 합치면, 사용자는 「쓸 수 있는 번호」라고
    /// 안심한 뒤 눌러서 「30일 동안 가입 불가」를 듣는다.
    @Test("선확인이 비어 있다고 해도 재가입 제한은 발송에서만 드러난다")
    func rejoinOnlyFromSend() {
        // exists=false → 전이가 없으므로 상태는 초기값 그대로다.
        let idle = PhoneVerifyState()
        #expect(!idle.alreadyRegistered, "false 를 보고 무언가를 열어 두면 안 된다")
        #expect(!idle.rejoinRestricted)
        #expect(idle.canRequestCode(phoneDigits: PHONE, nowMillis: NOW), "선확인은 발송을 막지 않는다 — 최종 판정이 그쪽에 있다")

        let blocked = idle.onRequestStart(phone: PHONE)
            .onRequestFailure(error: .rejoinRestricted, message: "30일 동안 다시 가입할 수 없어요", nowMillis: NOW)

        #expect(blocked.rejoinRestricted)
        #expect(!blocked.alreadyRegistered, "재가입 제한을 「로그인하면 된다」로 말하게 된다")
        #expect(!blocked.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    /// 탈퇴한 번호의 재가입 제한(409 `USER109`, 2026-10). 발송 단계에서 나는 것까지는
    /// `AuthError.phoneNumberDuplicated` 와 같지만 **같은 플래그로 묶으면 안 된다** —
    /// 저쪽은 "로그인하세요"로 보내는데 여기엔 로그인할 계정이 없다.
    /// 오늘 다시 눌러도 같은 409 뿐이라 버튼을 잠근다.
    @Test("재가입 제한은 입력칸을 열지 않고 버튼을 잠근다")
    func rejoinLocks() {
        let state = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .rejoinRestricted, message: "30일 동안 다시 가입할 수 없어요", nowMillis: NOW)

        #expect(state.stage == .idle)
        #expect(state.rejoinRestricted)
        #expect(!state.alreadyRegistered, "이미 가입된 번호로 오해하게 만든다")
        #expect(state.phoneMessage == "30일 동안 다시 가입할 수 없어요")
        #expect(state.codeRemainingSeconds(nowMillis: NOW) == 0)
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    /// 다른 번호로는 가입할 수 있다 — 번호를 고치면 상태 전체가 비워져 버튼이 풀린다.
    @Test("재가입 제한은 번호를 고치면 풀린다")
    func rejoinReleasedByChange() {
        let blocked = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .rejoinRestricted, message: "30일 동안 다시 가입할 수 없어요", nowMillis: NOW)

        let other = blocked.onPhoneDigitsChanged(phoneDigits: "01098765432")

        #expect(!other.rejoinRestricted)
        #expect(other.canRequestCode(phoneDigits: "01098765432", nowMillis: NOW))
    }

    @Test("쿨다운 429 는 남은 시간을 최대치로 다시 잡는다 - 서버가 남은 초를 주지 않는다")
    func cooldownResets() {
        // 앱을 껐다 켠 직후: 발송 시점을 모르니 쿨다운이 0 인 상태에서 눌러 429 를 맞는다
        let restarted = PhoneVerifyState().onRequestStart(phone: PHONE)
        let state = restarted.onRequestFailure(error: .smsCooldown, message: "1분에 한 번", nowMillis: NOW)
        #expect(state.resendRemainingSeconds(nowMillis: NOW) == AuthPolicy.SMS_RESEND_COOLDOWN_SECONDS)
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    @Test("쿨다운 429 가 이미 걸린 타이머를 앞당기지는 않는다")
    func cooldownNotShortened() {
        // 남은 쿨다운이 더 길 수도 있다(서버 기준이 앞서 있는 경우) — 짧은 쪽으로 덮으면 또 429 다
        let later = sent(NOW + 30_000)
        let state = later.onRequestFailure(error: .smsCooldown, message: "1분에 한 번", nowMillis: NOW)
        #expect(state.resendRemainingSeconds(nowMillis: NOW) == 90)
    }

    @Test("쿨다운 429 는 열려 있는 입력칸을 닫지 않는다")
    func cooldownKeepsCode() {
        let state = sent().onCodeChanged(raw: "12")
            .onRequestFailure(error: .smsCooldown, message: "1분에 한 번", nowMillis: NOW + 1_000)
        #expect(state.stage == .codeSent)
        #expect(state.code == "12")
    }

    @Test("일일 한도는 버튼을 잠근다")
    func dailyLimitLocks() {
        let state = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .smsDailyLimitExceeded, message: "하루 5번", nowMillis: NOW)
        #expect(state.dailyLimitReached)
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
    }

    @Test("문자 서비스 장애는 바로 다시 누를 수 있다 - 서버가 쿨다운을 풀어 준다")
    func unavailableRetries() {
        let state = PhoneVerifyState().onRequestStart(phone: PHONE)
            .onRequestFailure(error: .smsUnavailable, message: "잠시 뒤", nowMillis: NOW)
        #expect(state.canRequestCode(phoneDigits: PHONE, nowMillis: NOW))
        #expect(state.phoneMessage == "잠시 뒤")
    }

    // ─────────────────────────────── 인증번호 입력·확인 ───────────────────────────────

    @Test("인증번호는 숫자 6자리만 받는다")
    func codeDigitsOnly() {
        #expect(sent().onCodeChanged(raw: "12ab34-56789").code == "123456")
        #expect(sent().onCodeChanged(raw: "1234").code == "1234")
    }

    @Test("발송 전에는 인증번호를 받지 않는다")
    func codeIgnoredBeforeSend() {
        let idle = PhoneVerifyState()
        #expect(idle == idle.onCodeChanged(raw: "123456"))
    }

    @Test("6자리를 채우기 전에는 확인할 수 없다")
    func submitNeedsSix() {
        #expect(!sent().onCodeChanged(raw: "12345").canSubmitCode(nowMillis: NOW))
        #expect(sent().onCodeChanged(raw: "123456").canSubmitCode(nowMillis: NOW))
    }

    @Test("만료된 뒤에는 확인할 수 없다")
    func submitBlockedAfterExpiry() {
        let state = sent().onCodeChanged(raw: "123456")
        #expect(state.canSubmitCode(nowMillis: NOW + CODE_TTL_MS - 1))
        #expect(!state.canSubmitCode(nowMillis: NOW + CODE_TTL_MS))
    }

    @Test("확인 중에는 두 번 보내지 않는다")
    func submitBlockedWhileVerifying() {
        #expect(!sent().onCodeChanged(raw: "123456").onVerifyStart().canSubmitCode(nowMillis: NOW))
    }

    @Test("인증 성공은 토큰을 들고 타이머를 멈춘다")
    func verifiedStopsTimers() {
        let state = verified()
        #expect(state.stage == .verified)
        #expect(state.token == "tok-1")
        #expect(state.codeRemainingSeconds(nowMillis: NOW) == 0)
        #expect(state.resendRemainingSeconds(nowMillis: NOW) == 0)
        #expect(!state.hasRunningCountdown(nowMillis: NOW))
        #expect(state.codeMessage == nil)
    }

    @Test("불일치는 입력칸만 비우고 같은 인증번호를 계속 쓴다")
    func mismatchKeepsCode() {
        let state = sent().onCodeChanged(raw: "111111")
            .onVerifyFailure(error: .smsCodeMismatch, message: "일치하지 않아요")
        #expect(state.stage == .codeSent)
        #expect(state.code == "")
        #expect(state.codeMessage == "일치하지 않아요")
        // 아직 서버에 인증번호가 남아 있다 → 타이머도 그대로
        #expect(state.codeRemainingSeconds(nowMillis: NOW) == AuthPolicy.SMS_CODE_TTL_SECONDS)
    }

    @Test("5회 초과와 만료는 입력칸을 닫고 재발송으로 보낸다")
    func tooManyAndExpiredClose() {
        for error in [AuthError.smsTooManyAttempts, AuthError.smsCodeExpired] {
            let state = sent().onCodeChanged(raw: "111111").onVerifyFailure(error: error, message: "다시 받아 주세요")
            #expect(state.codeRemainingSeconds(nowMillis: NOW) == 0, "\(error.name)")
            #expect(state.code == "", "\(error.name)")
            #expect(state.codeMessage != nil, "\(error.name)")
            // 쿨다운은 건드리지 않는다 — 발송 1분 안에 5회를 틀릴 수 있어서 그때는 기다려야 한다
            #expect(state.resendRemainingSeconds(nowMillis: NOW) == AuthPolicy.SMS_RESEND_COOLDOWN_SECONDS, "\(error.name)")
        }
    }

    @Test("번호 형식 오류는 1단계로 되돌린다 - 고칠 곳이 인증번호가 아니다")
    func invalidPhoneGoesBack() {
        let state = sent().onCodeChanged(raw: "123456")
            .onVerifyFailure(error: .invalidPhoneNumber, message: "형식을 확인해 주세요")
        #expect(state.stage == .idle)
        #expect(state.phoneMessage == "형식을 확인해 주세요")
        #expect(state.codeMessage == nil)
    }

    @Test("네트워크 실패는 입력값을 남겨 둔다 - 확인 버튼으로 재시도한다")
    func networkKeepsInput() {
        let state = sent().onCodeChanged(raw: "123456")
            .onVerifyFailure(error: .network, message: "연결을 확인해 주세요")
        #expect(state.code == "123456")
        #expect(state.canSubmitCode(nowMillis: NOW))
    }

    // ─────────────────────────────── 3분 자체 만료 ───────────────────────────────

    @Test("3분이 지나면 서버에 묻지 않고 입력칸을 닫는다")
    func selfExpiry() {
        let state = sent().onCodeChanged(raw: "123456").onCodeExpired(message: "만료됐어요")
        #expect(state.code == "")
        #expect(state.codeRemainingSeconds(nowMillis: NOW) == 0)
        #expect(state.codeMessage == "만료됐어요")
        #expect(!state.canSubmitCode(nowMillis: NOW))
    }

    @Test("만료 전이는 두 번 적용되지 않는다 - 틱마다 불려도 안전해야 한다")
    func expiryIdempotent() {
        let expired = sent().onCodeExpired(message: "만료됐어요")
        #expect(expired == expired.onCodeExpired(message: "다른 문구"))
    }

    @Test("인증을 끝낸 뒤에는 만료 전이가 상태를 건드리지 않는다")
    func expiryIgnoredAfterVerified() {
        let state = verified()
        #expect(state == state.onCodeExpired(message: "만료됐어요"))
    }

    @Test("카운트다운이 남아 있는 동안만 틱이 필요하다")
    func tickOnlyWhileCounting() {
        let state = sent()
        #expect(state.hasRunningCountdown(nowMillis: NOW))
        #expect(state.hasRunningCountdown(nowMillis: NOW + COOLDOWN_MS))
        #expect(!state.hasRunningCountdown(nowMillis: NOW + CODE_TTL_MS))
    }

    // ─────────────────────────────── 가입 실패 후 재시도 ───────────────────────────────

    @Test("가입 실패로 인증을 되돌리는 경우는 PHONE_NOT_VERIFIED 하나뿐이다")
    func reverifyOnlyForPhoneNotVerified() {
        #expect(signupErrorNeedsReverify(error: .phoneNotVerified))
        // 토큰은 가입이 다 저장된 뒤에야 소진된다 — 중복 409 는 같은 토큰으로 재시도할 수 있다
        #expect(!signupErrorNeedsReverify(error: .nicknameDuplicated))
        #expect(!signupErrorNeedsReverify(error: .loginIdDuplicated))
        #expect(!signupErrorNeedsReverify(error: .phoneNumberDuplicated))
        #expect(!signupErrorNeedsReverify(error: .invalidNickname))
        #expect(!signupErrorNeedsReverify(error: .network))
        #expect(!signupErrorNeedsReverify(error: nil))
    }
}
