import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

/// 10 프로필 만들기의 **누르기 전 가입 여부 선확인**(POST /api/v1/auth/phone/check)이
/// `PhoneVerifyViewModel` 안에서 언제·몇 번 불리는가.
///
/// 순수 전이는 `PhoneVerifyStateTest` 가 본다. 여기서만 볼 수 있는 건 셋이다:
/// - **몇 번 묻는가** — 선확인 경로는 무인증·무쿨다운·무레이트리밋이라(실측 2026-11-01, 로컬 :8080)
///   앱이 스스로 묶지 않으면 타자마다 서버 왕복이 쌓인다. 디바운스·직전 요청 취소·11자리 조건이
///   함께 걸려 있는지는 상태 함수로 못 박을 수 없다.
/// - **`exists=false` 에 아무 일도 안 하는가** — 이게 이 작업의 가장 중요한 계약이다(아래 테스트 주석).
/// - **실패를 사용자에게 알리지 않는가**.
///
/// 화면은 그리지 않는다. 대기 함수만 가상 시계로 바꾼다.
@MainActor
@Suite struct PhonePrecheckTest {
    /// 가입된 번호(실측: 로컬 DB 에 실제로 있는 번호와 같은 모양). 값 자체에 의미는 없다.
    private let PHONE = "01012345678"
    private let clock = VirtualClock()

    private func make(_ repository: FakePhonePrecheckRepository) -> PhoneVerifyViewModel {
        let clock = self.clock
        return PhoneVerifyViewModel(repository: repository, sleep: { try await clock.sleep($0) })
    }

    private var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 11자리가 채워지기 전에는 묻지 않고, 채워진 뒤에도 **입력이 멈출 때까지** 기다린다.
    ///
    /// 타자마다 부르면 번호 하나에 왕복이 열한 번 쌓이고, 무레이트리밋 경로라 서버가 막아 주지도 않는다.
    @Test("11자리가 되기 전에는 가입 여부를 묻지 않는다")
    func notAskedBeforeComplete() async {
        let repository = FakePhonePrecheckRepository()
        let viewModel = make(repository)

        let typed = "0101234567"
        for length in 1...typed.count {
            viewModel.onPhoneDigitsChanged(phoneDigits: String(typed.prefix(length)))
        }
        await clock.advanceUntilIdle()

        #expect(repository.asked == [])
    }

    @Test("입력이 멈춘 뒤에 묻는다")
    func askedAfterDebounce() async {
        let repository = FakePhonePrecheckRepository()
        let viewModel = make(repository)

        viewModel.onPhoneDigitsChanged(phoneDigits: PHONE)
        // 디바운스(500ms)가 끝나기 전 — 아직 아무것도 묻지 않았다.
        await clock.advance(by: .milliseconds(400))
        #expect(repository.asked == [])

        await clock.advanceUntilIdle()
        #expect(repository.asked == [PHONE])
    }

    /// 다음 타자가 들어오면 직전 조회를 취소한다 — 번호를 고치는 동안 왕복이 쌓이지 않고,
    /// 늦게 도착한 옛 응답이 최신 입력에 문구를 띄우지도 않는다.
    @Test("번호를 고치면 직전 조회를 취소하고 마지막 번호만 묻는다")
    func typingCancelsPrevious() async {
        let repository = FakePhonePrecheckRepository(registered: true)
        let viewModel = make(repository)

        viewModel.onPhoneDigitsChanged(phoneDigits: PHONE)
        await clock.advance(by: .milliseconds(300))
        viewModel.onPhoneDigitsChanged(phoneDigits: "0101234567") // 한 자 지웠다 — 11자리가 아니라 묻지 않는다
        viewModel.onPhoneDigitsChanged(phoneDigits: "01012345679")
        await clock.advanceUntilIdle()

        #expect(repository.asked == ["01012345679"])
    }

    /// 가입된 번호면 **버튼을 누르기 전에** 기존 안내가 뜬다 — 문구도, 잠금도, 「로그인하러 가기」도
    /// 이미 있는 `alreadyRegistered` 경로를 그대로 쓴다(새 상태·새 문구를 만들지 않는다).
    @Test("가입된 번호면 누르기 전에 안내가 뜨고 버튼이 잠긴다")
    func registeredBlocksBeforePress() async {
        let repository = FakePhonePrecheckRepository(registered: true)
        let viewModel = make(repository)

        viewModel.onPhoneDigitsChanged(phoneDigits: PHONE)
        await clock.advanceUntilIdle()

        let state = viewModel.state
        #expect(state.alreadyRegistered)
        #expect(state.phoneMessage == authErrorMessage(error: .phoneNumberDuplicated))
        #expect(state.stage == .idle)
        #expect(!state.canRequestCode(phoneDigits: PHONE, nowMillis: nowMillis))
    }

    /// ★★ 이 작업의 핵심 계약 — **`exists=false` 에는 아무 말도 하지 않는다.**
    ///
    /// 실측(2026-11-01, 로컬 :8080): 탈퇴 후 재가입 제한 기간(30일)인 번호도 선확인에서는
    /// `{"exists":false}` 200 이다(서버가 활성 프로필 한 테이블만 보고 탈퇴 기록을 보지 않는다).
    /// 같은 번호의 `POST /auth/sms/send` 는 409 `USER109` 다.
    ///
    /// 그러므로 false 를 「가입 가능」으로 읽어 「사용할 수 있어요」 같은 문구를 띄우거나 무언가를
    /// 열어 주면, 사용자는 안심한 뒤 눌러서 「30일 동안 가입 불가」를 듣는다 —
    /// **선확인을 붙인 탓에 지금보다 나빠지는 유일한 경로다.**
    /// 상태가 초기값과 **글자 하나 다르지 않아야** 한다는 것으로 그걸 못 박는다.
    @Test("가입된 번호가 아니면 아무 말도 하지 않는다")
    func notRegisteredSaysNothing() async {
        let repository = FakePhonePrecheckRepository(registered: false)
        let viewModel = make(repository)

        viewModel.onPhoneDigitsChanged(phoneDigits: PHONE)
        await clock.advanceUntilIdle()

        #expect(repository.asked == [PHONE]) // 묻기는 했다
        #expect(viewModel.state == PhoneVerifyState()) // 그런데 아무것도 바뀌지 않았다
        #expect(viewModel.state.phoneMessage == nil)
        #expect(viewModel.state.canRequestCode(phoneDigits: PHONE, nowMillis: nowMillis))
    }

    /// 확인 실패는 사용자가 고칠 수 있는 게 아니다 — 알리지도, 「다음」을 막지도 않는다
    /// (닉네임 쪽 `NicknameCheckState.unknown` 과 같은 판단). 최종 판정은 발송의 409 다.
    @Test("선확인이 실패해도 사용자에게 알리지 않는다")
    func failureIsSilent() async {
        let repository = FakePhonePrecheckRepository(
            failure: AuthException(error: .network, serverMessage: "네트워크 오류")
        )
        let viewModel = make(repository)

        viewModel.onPhoneDigitsChanged(phoneDigits: PHONE)
        await clock.advanceUntilIdle()

        #expect(viewModel.state == PhoneVerifyState())
        #expect(viewModel.state.canRequestCode(phoneDigits: PHONE, nowMillis: nowMillis))
    }

    /// ★ 사용자가 디바운스가 끝나는 순간 「인증번호 받기」를 누르면 두 경로가 겹친다.
    ///
    /// 늦게 온 선확인이 그대로 적용되면 진행 중인 발송 위에 「이미 가입된 번호」가 뜨고
    /// 진행 표시가 되돌려진다 — 발송은 아직 응답도 오지 않았는데.
    @Test("발송을 누른 뒤 도착한 선확인은 진행 중인 발송을 덮지 않는다")
    func lateAnswerDoesNotOverwriteSend() async {
        // 발송은 끝나지 않는다 — "요청이 날아간 상태"를 그대로 붙잡아 둔다.
        let repository = FakePhonePrecheckRepository(registered: true, blockSend: true)
        let viewModel = make(repository)

        viewModel.onPhoneDigitsChanged(phoneDigits: PHONE)
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.advanceUntilIdle()

        let state = viewModel.state
        #expect(state.requesting, "발송 진행 표시가 되돌려졌다")
        #expect(!state.alreadyRegistered, "진행 중인 발송 위에 「이미 가입된 번호」가 떴다")
        #expect(state.phoneMessage == nil)
        #expect(repository.asked == [PHONE], "선확인이 실제로 돌아야 이 테스트가 뜻이 있다")
    }
}

/// 선확인 한 가지만 기록하는 페이크.
private final class FakePhonePrecheckRepository: UnsupportedAuthRepository, @unchecked Sendable {
    private let registered: Bool
    private let failure: (any Error)?
    private let blockSend: Bool
    private let lock = NSLock()
    private var askedNumbers: [String] = []

    /// - Parameter registered: 서버의 `exists` 값
    /// - Parameter failure: 던질 예외(네트워크·서버 오류 흉내)
    /// - Parameter blockSend: 문자 발송을 **끝내지 않는다** — 발송이 날아간 상태를 붙잡아 두기 위한 것이다.
    init(registered: Bool = false, failure: (any Error)? = nil, blockSend: Bool = false) {
        self.registered = registered
        self.failure = failure
        self.blockSend = blockSend
    }

    /// 선확인으로 **실제로 서버에 물은 번호**를 순서대로 담는다. 길이가 곧 왕복 횟수다.
    var asked: [String] {
        lock.withLock { askedNumbers }
    }

    override func isPhoneRegistered(phoneNumber: String) async throws -> Bool {
        lock.withLock { askedNumbers.append(phoneNumber) }
        if let failure { throw failure }
        return registered
    }

    override func sendPhoneVerificationCode(phoneNumber: String) async throws {
        // 뷰모델이 해제되면 scope 가 취소해 풀린다.
        if blockSend { try await Task.sleep(for: .seconds(3600)) }
    }
}
