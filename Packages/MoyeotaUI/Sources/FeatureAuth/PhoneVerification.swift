import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 10 프로필 만들기 안에 들어가는 **휴대폰 문자 인증 블록** — 상태·전이 규칙·화면을 한곳에 모았다.
///
/// 2026-10 서버 변경으로 가입(`POST /api/v1/auth/register`)에 `verificationToken` 이 필수가 됐다
/// (`NewUser.verificationToken`). 토큰이 없으면 가입이 **전부 400** 이라
/// 인증은 가입 경로의 선택 단계가 아니라 통과 조건이다.
///
/// ### 왜 별도 화면(09 본인 인증)이 아닌가
/// 휴대폰 입력란은 이미 10 안에 있고, 가입 단계 표시가 1/2 · 2/2 다. 인증만을 위해 화면을 하나 더
/// 끼우면 (a) 단계 표시 체계가 2단계에서 3단계로 흔들리고, (b) 같은 번호를 두 화면이 각각 들고
/// 있어야 하며, (c) 인증 후 번호를 고치면 토큰이 무효가 되는데 그 되돌림이 화면 사이를 넘나든다.
/// 번호 입력 바로 아래에서 끝내면 세 문제가 전부 사라진다. Routes 의 09 `IDENTITY_VERIFY` 는
/// 통신사 본인 인증용으로 남겨 둔 미연결 화면이고, 이 블록이 그것을 대체하지는 않는다.
///
/// ### 서버가 알려주지 않는 것 — 앱 타이머의 한계
/// 서버는 **남은 쿨다운 초·남은 발송 횟수·남은 입력 시도 횟수를 응답에 담지 않는다**
/// (`Retry-After` 헤더도 없다). 429 는 "넘었다"만 말한다. 그래서 이 블록의 카운트다운은 전부
/// **앱이 자기 발송 시점부터 자체로 세는 값**이고, 다음 한계가 따라온다:
/// - **앱을 껐다 켜면(프로세스 종료) 쿨다운을 알 수 없다.** 뷰모델과 함께 발송 시점이 사라지므로
///   「인증번호 받기」가 곧바로 활성으로 보인다. 누르면 서버가 429 `SMS_COOLDOWN` 으로 거절하고,
///   그때 비로소 안내할 수 있다 — 이 경로에서만 쿨다운 문구가 "먼저 뜨지 않고 나중에 뜬다".
///   그 429 를 받으면 보수적으로 최대치(1분)만큼 쿨다운을 다시 잡는다(실제 남은 시간보다 길 수 있다).
/// - 일일 한도(5회)도 같은 이유로 **미리 막을 수 없다.** 한 번 429 를 받은 뒤에야 버튼을 잠근다.
/// - 입력 시도 횟수(5회)는 서버가 세고, 앱은 429 `SMS_TOO_MANY_ATTEMPTS` 로만 알게 된다.
///
/// 이 한계를 없애려면 서버가 `send` 204 응답에 남은 초/횟수를 싣거나 `Retry-After` 를 줘야 한다
/// (백엔드 요청 후보로 보고서에 적었다).
///
/// ### 상태 전이 한눈에
/// ```
/// Idle ──「인증번호 받기」 send 204──▶ CodeSent ──verify 200──▶ Verified (토큰 보관, 번호 잠금)
///  ▲                                    │                          │
///  │                                    │ 3분 만료·5회 초과 → 재발송 │
///  └──── 번호가 바뀌면 전부 무효 ◀───────┴──────────────────────────┘
/// ```
/// 번호가 바뀌면 되돌리는 이유는 서버가 토큰을 **번호 해시에 묶어** 보관하기 때문이다
/// (`checkVerified` 가 가입 번호의 해시와 비교한다) — 인증한 번호와 다른 번호로 가입하면 400 이다.
// 공개 타입인 이유: 공개 뷰 `ProfileSetupScreen` 의 파라미터로 나간다(NicknameCheckState 와 같은 자리).
// 전이 함수·뷰모델·블록 UI 는 모듈 안에서만 쓰이므로 internal 로 둔다.
public enum PhoneVerifyStage: Equatable, Sendable {
    /// 아직 인증번호를 받지 않았다(또는 받은 것이 무효가 됐다). 「인증번호 받기」만 보인다.
    case idle

    /// 발송 성공 — 6자리 입력칸과 만료 타이머가 열려 있다.
    case codeSent

    /// 인증 완료 — 토큰을 들고 있고 번호 입력란은 잠긴다.
    case verified
}

/// 타이머가 없다는 뜻의 기한 값. 0 을 쓰는 이유는 "지난 시각"과 같은 취급으로 끝나기 때문이다.
public let NO_DEADLINE: Int64 = 0

/// 카운트다운 갱신 간격. 1초 표시인데 500ms 로 도는 건 경계에서 최대 1초 늦게 보이는 걸 줄이기 위함이다.
private let TICK_INTERVAL_MS = 500

/// 번호 입력이 멈췄다고 보는 시간. 닉네임 쪽(`ProfileSetupRoute` 의 `NICKNAME_DEBOUNCE_MS`)과 같은 값이다.
///
/// 선확인 경로(POST /api/v1/auth/phone/check)는 무인증·무쿨다운·무레이트리밋이라(실측: 30연타 전부
/// 200, 2~3ms) 번호 존재 여부를 밀리초에 답해 주는 오라클이다. 타자마다 부르면 앱이 그 오라클을
/// 대신 두드리는 셈이 되므로, 디바운스 + 직전 요청 취소 + 11자리 완성 조건 셋으로 **번호당 1회**로 묶는다.
private let PHONE_PRECHECK_DEBOUNCE_MS = 500

/// 문자 인증 블록의 전체 상태. **값 + 순수 전이 함수**로만 바뀐다 —
/// 전이 규칙(어떤 에러가 입력칸을 닫는지, 번호가 바뀌면 무엇이 무효인지)이 화면 코드에 흩어지면
/// 단위 테스트가 불가능해지고, 이 블록의 실패는 "가입이 400 으로 안 된다"로만 드러나서 늦게 발견된다.
public struct PhoneVerifyState: Equatable, Sendable {
    public var stage: PhoneVerifyStage
    /// 이 상태가 묶여 있는 번호(하이픈 없는 숫자열). 발송 시도·인증 성공 모두
    /// 이 번호 기준이고, 입력란이 **다른 번호**로 바뀌면 상태 전체가 무효가 된다
    /// (`onPhoneDigitsChanged`). 요청이 날아간 뒤 응답이 돌아오는 사이 번호가 바뀌었는지를
    /// 판정하는 기준이기도 하다.
    public var boundPhone: String
    /// 인증 성공으로 받은 `verificationToken`. 가입 제출까지 이 값을 들고 있어야 한다 —
    /// 같은 인증번호로 토큰을 다시 받을 길이 없다(서버가 성공 시 인증번호를 지운다).
    public var token: String
    public var code: String
    /// 인증번호 만료 시각(epoch millis). `NO_DEADLINE` 이면 쓸 수 있는 인증번호가 없다.
    public var codeExpiresAt: Int64
    /// 재전송이 가능해지는 시각(epoch millis).
    public var resendAllowedAt: Int64
    public var requesting: Bool
    public var verifying: Bool
    /// 번호 입력란 아래에 띄울 문구. 발송 단계의 실패(중복·형식·한도·장애)가 여기 간다.
    public var phoneMessage: String?
    /// 인증번호 입력칸 아래에 띄울 문구. 확인 단계의 실패가 여기 간다.
    public var codeMessage: String?
    /// 그 번호로 이미 가입된 계정이 있다. 인증번호 입력칸을 열지 않고
    /// 로그인으로 가는 길을 보여준다 — 번호를 고치면 풀린다. **켜지는 경로가 둘이다**: 발송이
    /// 409 `PHONE_NUMBER_DUPLICATED` 로 끊긴 경우(`onRequestFailure`)와, 누르기 전에 선확인이
    /// 가입된 번호라고 답한 경우(`onPhonePrecheckTaken`). 결과가 같으므로 플래그를 나누지 않았다.
    public var alreadyRegistered: Bool
    /// 하루 발송 한도(5회)를 넘겼다. 재시도를 권하지 않고 버튼을 잠근다.
    public var dailyLimitReached: Bool
    /// 발송이 409 `USER109`(`AuthError.rejoinRestricted`)로 끊긴 상태 —
    /// 그 번호로 탈퇴한 계정이 있고 재가입 제한 기간이 아직 안 지났다. `alreadyRegistered` 와 같은 409,
    /// 같은 단계인데 **할 일이 정반대다**: 저쪽은 로그인으로 보내면 되지만 여기엔 로그인할 계정이 없다.
    /// 기다리는 것 말고 할 수 있는 게 없으므로 버튼을 잠근다 — 번호를 고치면 풀린다.
    public var rejoinRestricted: Bool

    public init(
        stage: PhoneVerifyStage = .idle,
        boundPhone: String = "",
        token: String = "",
        code: String = "",
        codeExpiresAt: Int64 = NO_DEADLINE,
        resendAllowedAt: Int64 = NO_DEADLINE,
        requesting: Bool = false,
        verifying: Bool = false,
        phoneMessage: String? = nil,
        codeMessage: String? = nil,
        alreadyRegistered: Bool = false,
        dailyLimitReached: Bool = false,
        rejoinRestricted: Bool = false
    ) {
        self.stage = stage
        self.boundPhone = boundPhone
        self.token = token
        self.code = code
        self.codeExpiresAt = codeExpiresAt
        self.resendAllowedAt = resendAllowedAt
        self.requesting = requesting
        self.verifying = verifying
        self.phoneMessage = phoneMessage
        self.codeMessage = codeMessage
        self.alreadyRegistered = alreadyRegistered
        self.dailyLimitReached = dailyLimitReached
        self.rejoinRestricted = rejoinRestricted
    }
}

/// 10 의 휴대폰 입력란이 받는 번호 — **010 + 숫자 8자리**.
///
/// 도메인 `AuthPolicy.PHONE_PATTERN` 은 011·016~019 와 10자리도 허용하지만, 이 화면의 입력 마스크가
/// 11자리 숫자만 만들고 기존 안내 문구도 010 기준이라 더 좁은 쪽으로 맞췄다. 블록과 화면이 같은
/// 함수를 쓰는 게 중요하다 — 「인증번호 받기」가 활성인데 「다음」은 번호가 틀렸다고 막는 식의
/// 어긋남을 구조적으로 없앤다.
func isCompletePhoneDigits(digits: String) -> Bool {
    digits.utf16.count == 11 && digits.utf16.starts(with: "010".utf16)
}

/// 남은 초(올림). 기한이 없거나 지났으면 0 — "1초 남음"이 0 으로 보이지 않도록 올림한다.
func secondsUntil(deadlineMillis: Int64, nowMillis: Int64) -> Int {
    if deadlineMillis <= nowMillis { return 0 }
    return Int((deadlineMillis - nowMillis + 999) / 1000)
}

/// 카운트다운 표시 문구 `m:ss`. 최대 3분이라 분은 한 자리로 둔다.
/// 음수가 들어와도 0:00 으로 접는다 — 시계가 뒤로 간(시간대 변경·시간 동기화) 경우의 방어다.
func formatRemainingSeconds(totalSeconds: Int) -> String {
    let safe = max(totalSeconds, 0)
    return String(format: "%d:%02d", safe / 60, safe % 60)
}

extension PhoneVerifyState {
    /// `copy(...)` 자리.
    private func with(_ change: (inout PhoneVerifyState) -> Void) -> PhoneVerifyState {
        var next = self
        change(&next)
        return next
    }

    /// 인증번호가 유효한 남은 시간(초).
    func codeRemainingSeconds(nowMillis: Int64) -> Int {
        secondsUntil(deadlineMillis: codeExpiresAt, nowMillis: nowMillis)
    }

    /// 재전송까지 남은 시간(초).
    func resendRemainingSeconds(nowMillis: Int64) -> Int {
        secondsUntil(deadlineMillis: resendAllowedAt, nowMillis: nowMillis)
    }

    /// 그려야 할 카운트다운이 남아 있는가 — 틱 루프를 멈출 시점 판단에 쓴다.
    func hasRunningCountdown(nowMillis: Int64) -> Bool {
        codeRemainingSeconds(nowMillis: nowMillis) > 0 || resendRemainingSeconds(nowMillis: nowMillis) > 0
    }

    /// 「인증번호 받기 / 다시 받기」를 누를 수 있는가.
    ///
    /// - 이미 인증을 끝냈으면 더 받을 이유가 없다(번호를 바꾸려면 「번호 변경」을 먼저 눌러야 한다).
    /// - 쿨다운 중에는 눌러도 429 다 — 앱이 먼저 막는다.
    /// - 이미 가입된 번호·일일 한도·재가입 제한은 **그 번호로는 끝난 상태**라 재시도를 열어 두지 않는다.
    ///   셋 다 번호를 고치면 풀린다(`onPhoneDigitsChanged` 가 상태를 비운다).
    func canRequestCode(phoneDigits: String, nowMillis: Int64) -> Bool {
        if stage == .verified { return false }
        if requesting { return false }
        if alreadyRegistered || dailyLimitReached || rejoinRestricted { return false }
        if resendRemainingSeconds(nowMillis: nowMillis) > 0 { return false }
        return isCompletePhoneDigits(digits: phoneDigits)
    }

    /// 「확인」을 누를(또는 6자리 자동 제출을 걸) 수 있는가.
    func canSubmitCode(nowMillis: Int64) -> Bool {
        stage == .codeSent &&
            !verifying &&
            AuthPolicy.isValidVerificationCode(value: code) &&
            codeRemainingSeconds(nowMillis: nowMillis) > 0
    }

    /// 발송 버튼 문구. 상태마다 다른 말을 해야 해서 순수 함수로 빼 두고 테스트한다.
    func requestButtonLabel(nowMillis: Int64) -> String {
        if requesting { return "인증번호 보내는 중…" }
        let remaining = resendRemainingSeconds(nowMillis: nowMillis)
        if remaining > 0 { return "\(remaining)초 후 다시 받기" }
        let sentBefore = stage == .codeSent || (!boundPhone.isEmpty && codeMessage != nil)
        return sentBefore ? "인증번호 다시 받기" : "인증번호 받기"
    }

    /// 번호 입력란이 바뀌었다 → **다른 번호가 됐으면 인증 상태 전체를 버린다.**
    ///
    /// 서버가 토큰을 번호에 묶으므로(`sms:verified:<token>` 의 phoneHash) 번호를 고친 뒤 옛 토큰으로
    /// 가입하면 400 `USER207` 이다. 그 400 을 가입 제출에서 맞게 두는 대신 여기서 즉시 되돌린다 —
    /// 사용자는 "번호를 고쳤으니 인증을 다시 해야 한다"를 입력하는 순간에 알게 된다.
    ///
    /// 같은 번호면 상태를 그대로 둔다(하이픈 표기 차이는 정규화로 흡수된다).
    func onPhoneDigitsChanged(phoneDigits: String) -> PhoneVerifyState {
        let normalized = AuthPolicy.normalizePhoneNumber(value: phoneDigits)
        if normalized == boundPhone { return self }
        return PhoneVerifyState()
    }

    /// 인증 상태를 통째로 버린다. 두 곳이 쓴다 —
    /// 인증 완료 후의 「번호 변경」, 그리고 가입이 `AuthError.phoneNotVerified` 로 되돌려 보낸 경우.
    ///
    /// - Parameter message: 버린 이유를 번호 입력란 아래에 남길 문구. 「번호 변경」처럼 사용자가 스스로 한
    ///   행동이면 nil — 자기가 누른 버튼의 결과를 오류처럼 말할 이유가 없다.
    func invalidated(message: String? = nil) -> PhoneVerifyState {
        PhoneVerifyState(phoneMessage: message)
    }

    /// 발송 요청 시작 — 이 번호에 상태를 묶고 진행 표시를 켠다. 직전 안내 문구는 지운다.
    func onRequestStart(phone: String) -> PhoneVerifyState {
        with {
            $0.boundPhone = phone
            $0.requesting = true
            $0.phoneMessage = nil
            $0.codeMessage = nil
            $0.alreadyRegistered = false
            $0.rejoinRestricted = false
        }
    }

    /// 발송 성공(204) — 인증번호 3분 만료와 재전송 1분 쿨다운이 **같이** 시작된다.
    ///
    /// 재발송이면 서버가 오입력 횟수를 0으로 되돌리므로(`saveCode` 가 ATTEMPT 키를 지운다)
    /// 앱도 이전 입력값·문구를 남기지 않는다.
    func onCodeSent(nowMillis: Int64) -> PhoneVerifyState {
        with {
            $0.stage = .codeSent
            $0.code = ""
            $0.token = ""
            $0.codeExpiresAt = nowMillis + Int64(AuthPolicy.SMS_CODE_TTL_SECONDS) * 1000
            $0.resendAllowedAt = nowMillis + Int64(AuthPolicy.SMS_RESEND_COOLDOWN_SECONDS) * 1000
            $0.requesting = false
            $0.verifying = false
            $0.phoneMessage = nil
            $0.codeMessage = nil
        }
    }

    /// 발송 실패. **에러마다 다른 상태로 간다** — 하나로 뭉치면 사용자가 할 일이 안 보인다.
    ///
    /// - Parameter message: 보여줄 문구(`authErrorMessage` 가 만든 값). 문구 표를 이 파일이 또 들고 있지 않도록
    ///   호출부가 넘긴다 — 테스트도 문구에 의존하지 않는다.
    func onRequestFailure(error: AuthError, message: String, nowMillis: Int64) -> PhoneVerifyState {
        switch error {
        // 이미 가입된 번호 — 인증번호를 기다리게 하면 오지 않는 문자를 기다린다. 입력칸을 열지 않고 로그인으로 보낸다.
        case .phoneNumberDuplicated:
            return with {
                $0.stage = .idle
                $0.code = ""
                $0.token = ""
                $0.codeExpiresAt = NO_DEADLINE
                $0.resendAllowedAt = NO_DEADLINE
                $0.requesting = false
                $0.verifying = false
                $0.phoneMessage = message
                $0.codeMessage = nil
                $0.alreadyRegistered = true
            }
        // 쿨다운 중이었다(앱 재시작으로 발송 시점을 잃은 경우가 대표적이다). 서버가 남은 초를 주지 않으니
        // 최대치만큼 보수적으로 잡는다 — 짧게 잡으면 또 눌러 또 429 를 받는다.
        case .smsCooldown:
            return with {
                $0.requesting = false
                $0.phoneMessage = message
                $0.resendAllowedAt = max(
                    $0.resendAllowedAt,
                    nowMillis + Int64(AuthPolicy.SMS_RESEND_COOLDOWN_SECONDS) * 1000
                )
            }
        // 하루 한도 — 기다려도 안 된다. 버튼을 잠그고 재시도를 권하지 않는다.
        case .smsDailyLimitExceeded:
            return with {
                $0.requesting = false
                $0.phoneMessage = message
                $0.dailyLimitReached = true
            }
        // 탈퇴한 번호의 재가입 제한(30일) — 오늘 다시 눌러도 같은 409 다. 버튼을 잠근다.
        // 입력칸을 열지 않는 건 phoneNumberDuplicated 와 같지만 alreadyRegistered 로 묶지 않는다:
        // 그 플래그는 "로그인하면 된다"는 뜻이고, 여기엔 로그인할 계정이 없다.
        case .rejoinRestricted:
            return with {
                $0.stage = .idle
                $0.code = ""
                $0.token = ""
                $0.codeExpiresAt = NO_DEADLINE
                $0.resendAllowedAt = NO_DEADLINE
                $0.requesting = false
                $0.verifying = false
                $0.phoneMessage = message
                $0.codeMessage = nil
                $0.rejoinRestricted = true
            }
        // 문자 서비스 장애·네트워크·형식 오류 — 상태는 그대로 두고 다시 누를 수 있게 한다.
        // (발송 실패 쪽은 서버가 쿨다운을 풀어 주므로 1분을 기다릴 필요도 없다)
        default:
            return with {
                $0.requesting = false
                $0.phoneMessage = message
            }
        }
    }

    /// 발송을 누르기 **전에** 선확인(POST /api/v1/auth/phone/check)이 「이미 가입된 번호」라고 답했다.
    ///
    /// `onRequestFailure` 의 `AuthError.phoneNumberDuplicated` 분기와 결과가 같다 — 안내 문구를
    /// 번호 입력란 아래에 남기고 `alreadyRegistered` 를 켜서 버튼을 잠그고 「로그인하러 가기」를 띄운다.
    /// 즉 이 전이가 더하는 건 **같은 안내를 버튼을 누르기 전에 보여 주는 것**뿐이고, 새 상태도 새 문구도
    /// 없다. 발송이 끊기는 경로(실측: 문자도 안 가고 쿨다운도 안 걸리고 즉시 409 `USER104`)는 그대로 둔다.
    ///
    /// **`boundPhone` 을 건드리지 않는다.** 발송을 시도한 적이 없으므로 묶인 번호가 없고, 여기서 번호를
    /// 묶으면 `onPhoneDigitsChanged` 가 「같은 번호」로 보아 상태를 비우지 않게 된다 — 사용자가 번호를
    /// 고쳤다 되돌릴 때 문구와 잠긴 버튼이 영영 풀리지 않는다.
    ///
    /// **`exists=false` 에는 대응하는 전이가 없다.** 서버가 탈퇴 기록을 보지 않으므로 false 는
    /// 「가입할 수 있다」를 뜻하지 않는다(실측 2026-11-01, 로컬 :8080 — 탈퇴한 번호도 `exists=false` 200인데
    /// 발송은 409 `USER109`). 그래서 선확인은 **막기만 하고 아무것도 열어 주지 않는다** —
    /// 재가입 제한은 지금처럼 발송 응답(`AuthError.rejoinRestricted`)으로만 드러난다.
    func onPhonePrecheckTaken(message: String) -> PhoneVerifyState {
        if stage != .idle || requesting {
            // 그 사이 사용자가 발송을 눌렀다(또는 이미 인증을 끝냈다) — 늦게 온 선확인이 진행 중인
            // 인증을 덮어 「이미 가입된 번호」를 띄우면, onRequestStart 가 켠 진행 표시가 되돌려진다.
            return self
        }
        return with {
            $0.phoneMessage = message
            $0.alreadyRegistered = true
        }
    }

    /// 인증번호 입력. 숫자 6자리만 받고, 고치는 순간 직전 오류 문구를 지운다.
    func onCodeChanged(raw: String) -> PhoneVerifyState {
        if stage != .codeSent { return self }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: raw.unicodeScalars.filter(\.isKotlinDigit).prefix(AuthPolicy.VERIFICATION_CODE_LENGTH))
        let digits = String(kept)
        if digits == code { return self }
        return with {
            $0.code = digits
            $0.codeMessage = nil
        }
    }

    /// 확인 요청 시작.
    func onVerifyStart() -> PhoneVerifyState {
        with {
            $0.verifying = true
            $0.codeMessage = nil
        }
    }

    /// 인증 성공 — 토큰을 들고 번호를 잠근다.
    ///
    /// 타이머는 둘 다 멈춘다: 인증번호는 서버에서 이미 지워졌고(재사용 불가), 재전송할 이유도 없다.
    /// 이제부터 시간 제약은 **토큰 10분**인데, 그건 앱이 세는 대신 가입 실패
    /// (`AuthError.phoneNotVerified`)로 알게 된다 — 남은 시간을 띄우면 가입 폼 위에 초읽기를
    /// 얹는 셈이라 서두르게만 만들고, 10분은 남은 입력(아이디·비밀번호·이메일)에 충분한 시간이다.
    func onVerified(verificationToken: String) -> PhoneVerifyState {
        with {
            $0.stage = .verified
            $0.token = verificationToken
            $0.verifying = false
            $0.codeExpiresAt = NO_DEADLINE
            $0.resendAllowedAt = NO_DEADLINE
            $0.phoneMessage = nil
            $0.codeMessage = nil
        }
    }

    /// 확인 실패. 여기서 갈라지는 핵심은 **서버에 인증번호가 아직 남아 있는가**다.
    ///
    /// - `AuthError.smsCodeMismatch`: 남아 있다 → 입력칸만 비우고 다시 받는다(서버가 5회까지 센다).
    /// - `AuthError.smsCodeExpired` · `AuthError.smsTooManyAttempts`: 서버가 지웠다 → 더 입력해도
    ///   같은 에러뿐이다. 입력칸을 닫고 재발송으로 보낸다. 쿨다운은 건드리지 않는다 — 5회 초과는
    ///   발송 1분 안에도 일어날 수 있어서 그때는 기다려야 한다.
    /// - `AuthError.invalidPhoneNumber`: 고칠 곳이 인증번호가 아니라 번호 입력란이다 → 1단계로 되돌린다.
    /// - 그 밖(네트워크·장애): 입력값을 남겨 둔다. 「확인」으로 그대로 재시도할 수 있어야 한다.
    func onVerifyFailure(error: AuthError, message: String) -> PhoneVerifyState {
        switch error {
        case .smsCodeMismatch:
            return with {
                $0.verifying = false
                $0.code = ""
                $0.codeMessage = message
            }
        case .smsCodeExpired, .smsTooManyAttempts:
            return with {
                $0.verifying = false
                $0.code = ""
                $0.codeExpiresAt = NO_DEADLINE
                $0.codeMessage = message
            }
        case .invalidPhoneNumber:
            return with {
                $0.stage = .idle
                $0.code = ""
                $0.codeExpiresAt = NO_DEADLINE
                $0.resendAllowedAt = NO_DEADLINE
                $0.verifying = false
                $0.phoneMessage = message
                $0.codeMessage = nil
            }
        default:
            return with {
                $0.verifying = false
                $0.codeMessage = message
            }
        }
    }

    /// 3분이 지나 인증번호가 스스로 만료됐다 — 서버에 묻지 않아도 아는 사실이라 미리 입력칸을 닫는다.
    ///
    /// 닫지 않으면 사용자가 만료된 번호를 다 입력하고 「확인」을 눌러 400 을 받은 뒤에야 알게 된다.
    /// `codeExpiresAt` 을 `NO_DEADLINE` 으로 비우므로 같은 전이가 두 번 적용되지 않는다.
    func onCodeExpired(message: String) -> PhoneVerifyState {
        if stage != .codeSent || codeExpiresAt == NO_DEADLINE { return self }
        return with {
            $0.code = ""
            $0.codeExpiresAt = NO_DEADLINE
            $0.verifying = false
            $0.codeMessage = message
        }
    }
}

/// 가입 실패가 **문자 인증을 다시 받게 만드는가**. `AuthError.phoneNotVerified` 하나뿐이다.
///
/// 아이디·닉네임·전화번호 중복(409)으로 가입이 실패해도 토큰은 **10분 동안 그대로 살아 있다** —
/// 서버가 토큰을 지우는 시점이 세 테이블 저장을 다 끝낸 뒤(`consume`)이기 때문이다.
/// 그 경우에 인증을 다시 시키면, 고칠 곳은 닉네임 한 글자인데 문자부터 다시 받게 하는 셈이다.
func signupErrorNeedsReverify(error: AuthError?) -> Bool {
    error == .phoneNotVerified
}

/// 문자 인증의 서버 호출(발송·확인)만 담당하는 뷰모델.
///
/// 10 의 내비게이션 스택 항목에 묶이므로 **12 매너 서약에 올라가 있는 동안에도 살아 있다** —
/// 닉네임 중복(409)으로 10 으로 되돌아왔을 때 토큰과 쿨다운이 그대로 남아 있어야 하기 때문이다
/// (인증을 다시 시킬 이유는 `signupErrorNeedsReverify` 뿐이다). 카운트다운도 같은 이유로
/// 뷰가 아니라 여기서 돈다: 화면을 떠난 1분이 쿨다운에서 빠지지 않으면 거짓 대기가 된다.
///
/// 남은 시간은 **기한(epoch millis)과 현재 시각의 차이**로 계산한다. 1초마다 카운터를 깎는 방식은
/// 앱이 백그라운드로 내려가 틱을 거르면 그만큼 뒤처져 쿨다운이 실제보다 길게 보인다.
@MainActor
@Observable
final class PhoneVerifyViewModel {
    private(set) var state = PhoneVerifyState()

    /// 화면이 카운트다운을 그릴 기준 시각. 틱마다 갱신되고, 셀 것이 없으면 멈춘다.
    private(set) var nowMillis: Int64

    @ObservationIgnored private let repository: any AuthRepository
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let currentTimeMillis: @Sendable () -> Int64
    @ObservationIgnored private let scope = ViewModelScope()

    /// 도는 중인 틱 루프. 끝나면 nil 이다(`Job.isActive` 의 자리).
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// 마지막으로 처리한 재인증 신호 번호. 같은 신호를 두 번 적용하지 않기 위한 기억이다.
    @ObservationIgnored private var handledReverifyRequest = 0

    // 진행 중인 선확인 조회. 다음 타자가 들어오면 취소한다 — 늦게 도착한 옛 응답이 최신 입력을
    // 덮어쓰는 사고를 구조적으로 막는다(닉네임 쪽 NicknameCheckViewModel 과 같은 장치다).
    @ObservationIgnored private var precheckJob: Task<Void, Never>?

    /// 마지막으로 들어온 입력값. 취소를 놓친 응답이 자기 번호에만 쓰도록 거르는 기준이다.
    @ObservationIgnored private var lastPhoneDigits = ""

    init(
        repository: any AuthRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        currentTimeMillis: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.repository = repository
        self.sleep = sleep
        self.currentTimeMillis = currentTimeMillis
        self.nowMillis = currentTimeMillis()
    }

    /// `MutableStateFlow.update` 자리. 같은 값이면 쓰지 않는다 — StateFlow 처럼 관찰자를 깨우지 않는다.
    private func updateState(_ transform: (PhoneVerifyState) -> PhoneVerifyState) {
        let next = transform(state)
        if next != state { state = next }
    }

    /// 번호 입력란이 바뀔 때마다. 다른 번호면 인증이 무효가 되고, 11자리가 되면 입력이 멈춘 뒤
    /// 가입 여부를 **한 번** 묻는다 — 버튼을 누르기 전에 「이미 가입된 번호예요」를 말해 주기 위한 것이다.
    ///
    /// 트리거를 `isCompletePhoneDigits` 로 두는 건 의도다. 도메인 규칙(`AuthPolicy.isValidPhoneNumber`)은
    /// 011·016~019 와 10자리도 통과시키지만 이 화면은 010 + 11자리만 받으므로(기존 안내 문구도 그 기준),
    /// 발송 버튼과 **같은 함수**를 써야 「선확인은 물어보는데 다음은 막는」 어긋남이 생기지 않는다.
    ///
    /// 확인 실패(네트워크·서버 오류)는 **사용자에게 알리지 않는다.** 사용자가 고칠 수 있는 게 아니고,
    /// 알려서 「다음」을 막으면 이득보다 해가 크다 — 닉네임 쪽 `NicknameCheckState.unknown` 과 같은
    /// 판단이다. 최종 판정은 어차피 발송의 409 다.
    func onPhoneDigitsChanged(phoneDigits: String) {
        precheckJob?.cancel()
        lastPhoneDigits = phoneDigits
        updateState { $0.onPhoneDigitsChanged(phoneDigits: phoneDigits) }
        if !isCompletePhoneDigits(digits: phoneDigits) { return }
        let phone = AuthPolicy.normalizePhoneNumber(value: phoneDigits)
        let repository = self.repository
        let sleep = self.sleep
        precheckJob = scope.launch { [weak self] in
            let registered: Bool
            do {
                try await sleep(.milliseconds(PHONE_PRECHECK_DEBOUNCE_MS))
                registered = try await repository.isPhoneRegistered(phoneNumber: phone)
            } catch {
                // 상태를 건드리지 않고 조용히 끝낸다 — 취소(다음 타자)로 들어온 경우에도 안전하다.
                return
            }
            // 코루틴은 취소되면 응답을 받아도 이 아래로 오지 않는다.
            if Task.isCancelled { return }
            // **false 는 아무것도 보장하지 않는다.** 서버가 탈퇴 기록을 보지 않으므로 재가입 제한
            // 기간인 번호도 false 로 온다(실측 2026-11-01, 로컬 :8080) — 열어 주면 「쓸 수 있는
            // 번호」라고 안심시킨 뒤 발송에서 409 USER109 를 듣게 된다. 막는 데만 쓴다.
            if !registered { return }
            guard let self else { return }
            // 취소를 놓친 응답이 남의 번호에 문구를 띄우지 않게 한다.
            if self.lastPhoneDigits != phoneDigits { return }
            self.updateState { $0.onPhonePrecheckTaken(message: authErrorMessage(error: .phoneNumberDuplicated)) }
        }
    }

    /// 인증 완료 후 「번호 변경」 — 사용자가 스스로 무효화를 택한 경로라 안내 문구를 남기지 않는다.
    func onPhoneEditRequested() {
        updateState { $0.invalidated() }
    }

    /// 가입이 `AuthError.phoneNotVerified` 로 떨어져 되돌아온 경우 — 들고 있던 토큰은 서버에서
    /// 이미 쓸 수 없는 값(만료·소진·번호 불일치)이다. 버리고 1단계로 돌아가며, 왜 되돌아왔는지를
    /// 번호 입력란 아래에 남긴다.
    ///
    /// - Parameter requestId: 되돌림 신호의 일련번호(12 → 10 으로 보낸 횟수). **이미 처리한 번호는 무시한다.**
    ///   이 방어가 없으면 10 이 다시 나타날 때마다 같은 신호가 또 적용된다 —
    ///   사용자가 12 에서 **뒤로** 눌러 돌아온 정상 경로에서도 멀쩡한 인증이 날아간다.
    ///   뷰모델은 그 사이에도 살아 있어 기억할 수 있다.
    func onSignupRejectedPhone(requestId: Int) {
        if requestId <= handledReverifyRequest { return }
        handledReverifyRequest = requestId
        updateState { $0.invalidated(message: authErrorMessage(error: .phoneNotVerified)) }
    }

    /// 인증번호 발송. 누를 수 없는 상태면 아무 일도 하지 않는다(화면도 버튼을 비활성으로 그린다).
    func requestCode(phoneDigits: String) {
        let now = currentTimeMillis()
        if !state.canRequestCode(phoneDigits: phoneDigits, nowMillis: now) { return }
        let phone = AuthPolicy.normalizePhoneNumber(value: phoneDigits)
        updateState { $0.onRequestStart(phone: phone) }
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                try await repository.sendPhoneVerificationCode(phoneNumber: phone)
                guard let self else { return }
                // 요청이 날아간 사이 사용자가 번호를 고쳤으면 이 응답은 남의 것이다 — 버린다.
                if self.state.boundPhone != phone { return }
                let sentAt = self.currentTimeMillis()
                self.updateState { $0.onCodeSent(nowMillis: sentAt) }
            } catch {
                // 뷰모델이 해제돼 태스크가 취소된 경우만 조용히 끝낸다. 그 밖에는 보내는 중으로 남기지 않는다.
                guard let failure = authFailureOnLiveTask(error: error) else { return }
                guard let self else { return }
                if self.state.boundPhone != phone { return }
                let failedAt = self.currentTimeMillis()
                self.updateState {
                    $0.onRequestFailure(
                        error: failure.authErrorOrUnknown(),
                        message: failure.authUserMessage(),
                        nowMillis: failedAt
                    )
                }
            }
            self?.startTicker()
        }
    }

    /// 인증번호 입력. 6자리가 채워지면 **버튼을 누르지 않아도** 확인으로 넘어간다.
    func onCodeChanged(raw: String) {
        updateState { $0.onCodeChanged(raw: raw) }
        if AuthPolicy.isValidVerificationCode(value: state.code) { verify() }
    }

    /// 인증번호 확인. 자동 제출과 「확인」 버튼이 같은 경로를 쓴다.
    func verify() {
        let current = state
        if !current.canSubmitCode(nowMillis: currentTimeMillis()) { return }
        let phone = current.boundPhone
        let code = current.code
        updateState { $0.onVerifyStart() }
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                let token = try await repository.verifyPhoneCode(phoneNumber: phone, code: code)
                guard let self else { return }
                if self.state.boundPhone != phone { return }
                self.updateState { $0.onVerified(verificationToken: token) }
            } catch {
                // 뷰모델이 해제돼 태스크가 취소된 경우만 조용히 끝낸다. 그 밖에는 확인 중으로 남기지 않는다.
                guard let failure = authFailureOnLiveTask(error: error) else { return }
                guard let self else { return }
                if self.state.boundPhone != phone { return }
                self.updateState {
                    $0.onVerifyFailure(error: failure.authErrorOrUnknown(), message: failure.authUserMessage())
                }
            }
        }
    }

    /// 카운트다운 루프. 하나만 돌고, 셀 것이 없어지면 스스로 멈춘다 —
    /// 화면이 떠 있는 동안 1초마다 빈 루프를 도는 것을 피한다.
    private func startTicker() {
        if ticker != nil { return }
        // 첫 틱은 태스크를 기다리지 않고 바로 돈다 — 원본 `Main.immediate` 처럼 발송 결과와 기준 시각이 같은
        // 그리기에 들어가야 새 기한과 옛 시각이 만나 「남은 시간 5:00」 같은 값이 보이지 않는다.
        if !tick() { return }
        let sleep = self.sleep
        ticker = scope.launch { [weak self] in
            // 대기 동안 뷰모델을 붙잡지 않는다 — 그래야 해제되고, 해제가 이 루프를 취소한다.
            repeat {
                do {
                    try await sleep(.milliseconds(TICK_INTERVAL_MS))
                } catch {
                    return
                }
            } while self?.tick() == true
        }
    }

    /// 틱 한 번. 계속 돌아야 하면 true.
    private func tick() -> Bool {
        let now = currentTimeMillis()
        nowMillis = now
        if state.codeRemainingSeconds(nowMillis: now) == 0 {
            // 만료는 전이로 처리한다 — 입력칸을 닫고 재발송으로 유도해야 하기 때문이다.
            updateState { $0.onCodeExpired(message: authErrorMessage(error: .smsCodeExpired)) }
        }
        if state.hasRunningCountdown(nowMillis: currentTimeMillis()) { return true }
        ticker = nil
        return false
    }
}

private extension Error {
    /// data 계층이 모든 실패를 `AuthException` 으로 올려 주지만, 그렇지 않은 예외도 unknown 으로 받는다.
    func authErrorOrUnknown() -> AuthError {
        (self as? AuthException)?.error ?? .unknown
    }
}

/// 휴대폰 번호 입력란 **바로 아래**에 붙는 인증 블록.
///
/// 번호 입력란 자체는 10 화면이 들고 있다(`ProfileSetupScreen`) — 인증 상태에 따라 잠기고
/// 실패 문구가 그 필드의 errorText 로 내려가야 해서, 필드를 블록 안으로 가져오면 10 의 입력 묶음
/// (이름·생년월일·성별·휴대폰)이 둘로 쪼개진다.
///
/// 인증번호 입력에 6칸 박스(07 인증 코드 화면의 모양)를 쓰지 않은 건 의도다: 이 화면은 이미
/// 입력 필드가 8개라서 64pt 박스 6개를 세우면 번호 입력과 다음 절(로그인 정보) 사이가 한 화면을
/// 넘어간다. 같은 디자인 시스템 안에서 더 조용한 `MoyeotaTextField` 로 맞췄다.
struct PhoneVerificationBlock: View {
    /// 인증 상태. 화면은 판단하지 않고 그리기만 한다 — 전이 규칙은 전부 순수 함수다.
    let state: PhoneVerifyState
    /// 카운트다운 기준 시각. `PhoneVerifyViewModel.nowMillis` 가 틱마다 올려 준다.
    let nowMillis: Int64
    let phoneDigits: String
    let onRequestCode: () -> Void
    let onCodeChange: (String) -> Void
    let onSubmitCode: () -> Void
    let onPhoneEditRequested: () -> Void
    let onGoToLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.stage == .verified {
                Spacer().frame(height: 10)
                HStack(alignment: .center, spacing: 0) {
                    Text("휴대폰 인증 완료")
                        .moyeotaText(BoldCaption, color: MoyeotaColor.Success500)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 번호를 고치려면 인증을 버려야 한다(서버가 토큰을 번호에 묶는다) — 실수로 고쳐지는 대신
                    // 명시적으로 누르게 하고, 누르면 1단계로 되돌아간다.
                    captionAction("번호 변경", action: onPhoneEditRequested)
                }
                .frame(maxWidth: .infinity)
            } else {
                if state.alreadyRegistered {
                    // 문구는 번호 입력란 아래(errorText)에 이미 떠 있다 — 여기서는 갈 길만 준다.
                    Spacer().frame(height: 10)
                    captionAction("로그인하러 가기", action: onGoToLogin)
                }

                let canRequest = state.canRequestCode(phoneDigits: phoneDigits, nowMillis: nowMillis)
                if state.stage != .codeSent {
                    Spacer().frame(height: 12)
                    SecondaryButton(
                        text: state.requestButtonLabel(nowMillis: nowMillis),
                        onClick: onRequestCode,
                        enabled: canRequest
                    )
                } else {
                    codeEntry(canRequest: canRequest)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func codeEntry(canRequest: Bool) -> some View {
        let codeRemaining = state.codeRemainingSeconds(nowMillis: nowMillis)
        Spacer().frame(height: 12)
        MoyeotaTextField(
            value: state.code,
            onValueChange: onCodeChange,
            label: "인증번호",
            placeholder: "문자로 받은 6자리",
            errorText: state.codeMessage,
            helperText: state.verifying ? "인증번호를 확인하고 있어요" : "6자리를 입력하면 자동으로 확인해요",
            keyboardOptions: KeyboardOptions(keyboardType: .numberPassword),
            // 만료된 인증번호를 다 입력하고 「확인」을 눌러 400 을 받는 길을 막는다
            enabled: codeRemaining > 0 && !state.verifying
        )

        // 「남은 시간 2:43」 + 「다시 받기」 — 07 인증 코드 화면이 쓰던 배치 그대로다.
        // 버튼 두 개를 나란히 두지 않은 이유: 반쪽 너비에 "인증번호 다시 받기"가 들어가지 않는다.
        Spacer().frame(height: 10)
        HStack(alignment: .center, spacing: 0) {
            // 만료되면 남은 시간 대신 입력칸 아래 오류 문구가 상황을 말한다
            Text(codeRemaining > 0 ? "남은 시간 \(formatRemainingSeconds(totalSeconds: codeRemaining))" : "")
                .moyeotaText(BoldCaption, color: MoyeotaColor.Waiting600)
            Spacer(minLength: 0)
            if canRequest {
                captionAction(state.requestButtonLabel(nowMillis: nowMillis), action: onRequestCode)
            } else {
                Text(state.requestButtonLabel(nowMillis: nowMillis))
                    .moyeotaText(BoldCaption, color: MoyeotaColor.TextAsh)
            }
        }
        .frame(maxWidth: .infinity)

        // 6자리를 채우면 자동으로 확인하므로, 이 버튼은 **네트워크 실패처럼 같은 입력으로 다시
        // 눌러야 하는** 경우를 위해 남겨 둔다.
        Spacer().frame(height: 12)
        SecondaryButton(
            text: state.verifying ? "확인 중…" : "확인",
            onClick: onSubmitCode,
            enabled: state.canSubmitCode(nowMillis: nowMillis)
        )
    }

    private func captionAction(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .moyeotaText(BoldCaption, color: MoyeotaColor.Primary500)
        }
        .buttonStyle(NoIndicationButtonStyle())
    }
}

private let BoldCaption = MoyeotaType.CaptionMd.copy(fontWeight: .bold)
