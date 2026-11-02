import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

// 원본에 없는 테스트. 원본 `PhonePrecheckTest` 는 선확인만 돌리지만, iOS 는 Task 경계가 원본과 달라
// 발송·확인·틱 흐름의 순서를 직접 확인한다.

private final class FakeRepository: UnsupportedAuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var verifyCalls: [String] = []
    let sendGate = Gate()
    var sendFailure: (any Error)?
    var verifyResult: Result<String, any Error> = .success("tok-1")
    var opensGate = true

    init(sendFailure: (any Error)? = nil) {
        self.sendFailure = sendFailure
        super.init()
    }

    var verified: [String] {
        lock.withLock { verifyCalls }
    }

    override func sendPhoneVerificationCode(phoneNumber: String) async throws {
        if !opensGate { await sendGate.wait() }
        if let sendFailure { throw sendFailure }
    }

    override func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String {
        lock.withLock { verifyCalls.append(code) }
        return try verifyResult.get()
    }

    override func isPhoneRegistered(phoneNumber: String) async throws -> Bool { false }
}

@MainActor
@Suite struct PhoneVerifyViewModelTest {
    private let PHONE = "01012345678"
    private let clock = VirtualClock()

    private func make(_ repository: FakeRepository) -> PhoneVerifyViewModel {
        let clock = self.clock
        return PhoneVerifyViewModel(
            repository: repository,
            sleep: { try await clock.sleep($0) },
            currentTimeMillis: { clock.currentMillis }
        )
    }

    @Test("발송에 성공하면 틱이 돌다가 3분 뒤 입력칸을 닫고 스스로 멈춘다")
    func tickerExpiresAndStops() async {
        let viewModel = make(FakeRepository())

        viewModel.requestCode(phoneDigits: PHONE)
        #expect(viewModel.state.requesting, "태스크 시작을 기다리지 않고 켜져야 두 번 눌리지 않는다")
        await clock.settle()
        #expect(viewModel.state.stage == .codeSent)
        #expect(clock.pendingCount == 1)

        await clock.advance(by: .seconds(60))
        #expect(viewModel.state.requestButtonLabel(nowMillis: viewModel.nowMillis) == "인증번호 다시 받기")
        #expect(viewModel.state.codeRemainingSeconds(nowMillis: viewModel.nowMillis) == 120)

        await clock.advanceUntilIdle()
        #expect(viewModel.state.codeMessage == authErrorMessage(error: .smsCodeExpired))
        #expect(viewModel.state.codeRemainingSeconds(nowMillis: viewModel.nowMillis) == 0)
        #expect(clock.pendingCount == 0, "셀 것이 없으면 틱이 멈춘다")
    }

    @Test("요청이 날아간 사이 번호를 고치면 늦게 온 응답을 버린다")
    func staleSendDropped() async {
        let repository = FakeRepository()
        repository.opensGate = false
        let viewModel = make(repository)

        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()
        viewModel.onPhoneDigitsChanged(phoneDigits: "0109999888")
        repository.sendGate.open()
        await clock.settle()

        #expect(viewModel.state == PhoneVerifyState())
        #expect(clock.pendingCount == 0, "버린 응답으로 틱을 시작하지 않는다")
    }

    @Test("발송 실패는 에러별 상태로 가고 문구는 표에서 온다")
    func sendFailureMapped() async {
        let viewModel = make(FakeRepository(sendFailure: AuthException(error: .phoneNumberDuplicated)))

        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        #expect(viewModel.state.alreadyRegistered)
        #expect(viewModel.state.phoneMessage == authErrorMessage(error: .phoneNumberDuplicated))
    }

    @Test("AuthException 이 아닌 발송 실패는 unknown 으로 받는다")
    func sendUnknownFailure() async {
        let viewModel = make(FakeRepository(sendFailure: IllegalStateException("boom")))

        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        #expect(!viewModel.state.requesting)
        #expect(viewModel.state.phoneMessage == "잠시 후 다시 시도해 주세요")
    }

    // 코어의 `HttpClient` 는 태스크가 취소됐을 때의 `URLError(.cancelled)` 를 `CancellationError` 로 바꾼다.
    // 그러니 `URLError(.cancelled)` 가 그대로 올라오면 태스크는 살아 있고, 아무도 진행 표시를 풀어 주지 않는다.
    @Test("태스크가 살아 있는데 발송이 URLError(.cancelled) 로 끝나면 네트워크 실패로 받고 다시 누를 수 있다")
    func sendLiveUrlCancellation() async {
        let repository = FakeRepository(sendFailure: URLError(.cancelled))
        let viewModel = make(repository)

        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        #expect(!viewModel.state.requesting)
        #expect(viewModel.state.stage == .idle)
        #expect(viewModel.state.phoneMessage == "네트워크 연결을 확인해 주세요")
        #expect(viewModel.state.canRequestCode(phoneDigits: PHONE, nowMillis: clock.currentMillis))

        repository.sendFailure = nil
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()
        #expect(viewModel.state.stage == .codeSent)
    }

    @Test("태스크가 살아 있는데 확인이 URLError(.cancelled) 로 끝나면 입력값을 남기고 「확인」으로 재시도한다")
    func verifyLiveUrlCancellation() async {
        let repository = FakeRepository()
        repository.verifyResult = .failure(URLError(.cancelled))
        let viewModel = make(repository)
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        viewModel.onCodeChanged(raw: "123456")
        await clock.settle()

        #expect(!viewModel.state.verifying)
        #expect(viewModel.state.code == "123456")
        #expect(viewModel.state.codeMessage == "네트워크 연결을 확인해 주세요")
        #expect(viewModel.state.canSubmitCode(nowMillis: clock.currentMillis))

        repository.verifyResult = .success("tok-2")
        viewModel.verify()
        await clock.settle()
        #expect(viewModel.state.stage == .verified)
        #expect(viewModel.state.token == "tok-2")
    }

    // 원본은 `Main.immediate` 라 `onCodeSent` 와 첫 틱이 같은 실행 안에서 끝난다. 틱이 다음 차례로 밀리면
    // 그 사이의 그리기가 새 기한과 옛 기준 시각을 함께 읽어 「남은 시간 5:00」 같은 값이 보인다.
    @Test("발송에 성공한 그 순간 카운트다운 기준 시각도 함께 바뀐다")
    func nowMillisMovesWithCodeSent() async {
        let repository = FakeRepository()
        repository.opensGate = false
        let viewModel = make(repository)
        await clock.advance(by: .seconds(120)) // 폼을 채우는 데 걸린 2분
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        repository.sendGate.open()
        // 양보만 하며 기다린다 — 다른 메인 액터 일이 끼어들 틈 없이 전이 직후를 읽는다.
        for _ in 0..<1_000_000 where viewModel.state.stage != .codeSent {
            await Task.yield()
        }

        #expect(viewModel.state.stage == .codeSent)
        #expect(viewModel.nowMillis == clock.currentMillis)
        #expect(viewModel.state.codeRemainingSeconds(nowMillis: viewModel.nowMillis) == 180)
        #expect(viewModel.state.requestButtonLabel(nowMillis: viewModel.nowMillis) == "60초 후 다시 받기")
        await clock.settle()
    }

    @Test("6자리가 차면 버튼 없이 한 번만 확인하고 토큰을 든다")
    func autoSubmitOnce() async {
        let repository = FakeRepository()
        let viewModel = make(repository)
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        viewModel.onCodeChanged(raw: "12345")
        #expect(!viewModel.state.verifying)
        viewModel.onCodeChanged(raw: "123456")
        #expect(viewModel.state.verifying)
        viewModel.verify() // 확인 중에는 두 번 보내지 않는다
        await clock.settle()

        #expect(repository.verified == ["123456"])
        #expect(viewModel.state.stage == .verified)
        #expect(viewModel.state.token == "tok-1")
    }

    @Test("인증번호 불일치는 입력칸을 비우고 표의 문구를 띄운다")
    func verifyMismatch() async {
        let repository = FakeRepository()
        repository.verifyResult = .failure(AuthException(error: .smsCodeMismatch))
        let viewModel = make(repository)
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()

        viewModel.onCodeChanged(raw: "111111")
        await clock.settle()

        #expect(viewModel.state.code == "")
        #expect(viewModel.state.codeMessage == authErrorMessage(error: .smsCodeMismatch))
    }

    /// 사용자가 12 에서 뒤로 돌아올 때마다 같은 신호가 다시 들어온다 — 멀쩡한 인증이 날아가면 안 된다.
    @Test("가입 거절 신호는 번호마다 한 번만 적용된다")
    func rejectedSignalOnce() async {
        let viewModel = make(FakeRepository())
        viewModel.onSignupRejectedPhone(requestId: 0)
        #expect(viewModel.state == PhoneVerifyState(), "0 은 신호가 아니다")

        viewModel.onSignupRejectedPhone(requestId: 1)
        #expect(viewModel.state.phoneMessage == authErrorMessage(error: .phoneNotVerified))

        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()
        #expect(viewModel.state.stage == .codeSent)
        viewModel.onSignupRejectedPhone(requestId: 1)
        #expect(viewModel.state.stage == .codeSent, "이미 처리한 번호는 무시한다")
    }

    @Test("번호 변경은 안내 문구 없이 처음으로 돌아간다")
    func editRequested() async {
        let viewModel = make(FakeRepository())
        viewModel.requestCode(phoneDigits: PHONE)
        await clock.settle()
        viewModel.onCodeChanged(raw: "123456")
        await clock.settle()
        #expect(viewModel.state.stage == .verified)

        viewModel.onPhoneEditRequested()

        #expect(viewModel.state == PhoneVerifyState())
    }
}
