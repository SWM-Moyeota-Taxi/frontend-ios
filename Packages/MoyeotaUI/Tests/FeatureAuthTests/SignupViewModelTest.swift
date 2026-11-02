import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

// 원본에 없는 테스트. 12 매너 서약의 제출 규칙을 뷰 없이 확인한다.

private final class FakeSignupRepository: UnsupportedAuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var registerFailures: [any Error]
    private var loginFailures: [any Error]
    let registerGate = Gate()

    init(registerFailures: [any Error] = [], loginFailures: [any Error] = []) {
        self.registerFailures = registerFailures
        self.loginFailures = loginFailures
        super.init()
        registerGate.open()
    }

    var calls: [String] {
        lock.withLock { recorded }
    }

    override func register(newUser: NewUser) async throws -> String {
        await registerGate.wait()
        let failure: (any Error)? = lock.withLock {
            recorded.append("register")
            return registerFailures.isEmpty ? nil : registerFailures.removeFirst()
        }
        if let failure { throw failure }
        return "uuid"
    }

    override func login(loginId: String, password: String) async throws -> String {
        let failure: (any Error)? = lock.withLock {
            recorded.append("login:\(loginId)/\(password)")
            return loginFailures.isEmpty ? nil : loginFailures.removeFirst()
        }
        if let failure { throw failure }
        return "uuid"
    }
}

@MainActor
@Suite struct SignupViewModelTest {
    private let clock = VirtualClock()
    private let draft = SignupDraft(
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

    @Test("가입 뒤 같은 자격증명으로 자동 로그인하고 done 이 켜진다")
    func registersThenLogsIn() async {
        let repository = FakeSignupRepository()
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: draft)
        #expect(viewModel.uiState.submitting)
        await clock.settle()

        #expect(repository.calls == ["register", "login:moyeota/abcd1234!"])
        #expect(viewModel.uiState == SignupViewModel.UiState(done: true))
    }

    @Test("초안에 빠진 값이 있으면 서버에 묻지 않고 문구를 띄운다")
    func incompleteDraft() async {
        let repository = FakeSignupRepository()
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: SignupDraft())
        await clock.settle()

        #expect(repository.calls.isEmpty)
        #expect(viewModel.uiState.errorMessage == "가입 정보가 부족해요. 이전 단계를 다시 확인해 주세요")
        #expect(!viewModel.uiState.submitting)
    }

    @Test("로그인만 실패하면 재시도 때 가입을 다시 보내지 않는다")
    func retryAfterLoginFailureSkipsRegister() async {
        let repository = FakeSignupRepository(loginFailures: [AuthException(error: .network)])
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: draft)
        await clock.settle()
        #expect(viewModel.uiState.errorMessage == "네트워크 연결을 확인해 주세요")
        #expect(!viewModel.uiState.done)

        viewModel.submit(draft: draft)
        await clock.settle()

        #expect(repository.calls == ["register", "login:moyeota/abcd1234!", "login:moyeota/abcd1234!"])
        #expect(viewModel.uiState.done)
    }

    @Test("닉네임 중복이면 되돌아갈 표시가 켜지고 다시 제출하면 꺼진다")
    func nicknameDuplicated() async {
        let repository = FakeSignupRepository(registerFailures: [AuthException(error: .nicknameDuplicated)])
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: draft)
        await clock.settle()
        #expect(viewModel.uiState.nicknameDuplicated)
        #expect(!viewModel.uiState.phoneNotVerified)
        #expect(viewModel.uiState.errorMessage == "이미 사용 중인 닉네임이에요")

        viewModel.submit(draft: draft)
        #expect(!viewModel.uiState.nicknameDuplicated)
        #expect(viewModel.uiState.errorMessage == nil)
        await clock.settle()
        #expect(viewModel.uiState.done)
    }

    @Test("토큰이 거절되면 재인증 표시가 켜진다")
    func phoneNotVerified() async {
        let repository = FakeSignupRepository(registerFailures: [AuthException(error: .phoneNotVerified)])
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: draft)
        await clock.settle()

        #expect(viewModel.uiState.phoneNotVerified)
        #expect(!viewModel.uiState.nicknameDuplicated)
    }

    // 원본은 OkHttp `IOException("Canceled")` 이 `toAuthException` 에서 NETWORK 가 되어 그 문구를 띄운다.
    @Test("가입이 살아 있는 태스크의 URLError(.cancelled) 로 끝나면 네트워크 문구를 띄우고 재시도는 가입부터 보낸다")
    func registerCancelledReopensButton() async {
        let repository = FakeSignupRepository(registerFailures: [URLError(.cancelled)])
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: draft)
        await clock.settle()

        #expect(!viewModel.uiState.submitting)
        #expect(viewModel.uiState.errorMessage == authErrorMessage(error: .network))

        viewModel.submit(draft: draft)
        await clock.settle()
        #expect(repository.calls == ["register", "register", "login:moyeota/abcd1234!"])
        #expect(viewModel.uiState.done)
    }

    @Test("이어지는 로그인이 살아 있는 태스크의 URLError(.cancelled) 로 끝나도 네트워크 문구를 띄우고 재시도는 로그인만 보낸다")
    func loginCancelledReopensButton() async {
        let repository = FakeSignupRepository(loginFailures: [URLError(.cancelled)])
        let viewModel = SignupViewModel(repository: repository)

        viewModel.submit(draft: draft)
        await clock.settle()

        #expect(!viewModel.uiState.submitting)
        #expect(viewModel.uiState.errorMessage == authErrorMessage(error: .network))

        viewModel.submit(draft: draft)
        await clock.settle()
        #expect(repository.calls == ["register", "login:moyeota/abcd1234!", "login:moyeota/abcd1234!"])
        #expect(viewModel.uiState.done)
    }

    @Test("제출 중에는 두 번 보내지 않는다")
    func doubleSubmit() async {
        let gated = FakeSignupRepositoryGated()
        let viewModel = SignupViewModel(repository: gated)

        viewModel.submit(draft: draft)
        viewModel.submit(draft: draft)
        await clock.settle()
        #expect(gated.registerCount == 1)
        #expect(viewModel.uiState.submitting)

        gated.gate.open()
        await clock.settle()
        #expect(viewModel.uiState.done)
    }
}

private final class FakeSignupRepositoryGated: UnsupportedAuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let gate = Gate()

    var registerCount: Int {
        lock.withLock { count }
    }

    override func register(newUser: NewUser) async throws -> String {
        lock.withLock { count += 1 }
        await gate.wait()
        return "uuid"
    }

    override func login(loginId: String, password: String) async throws -> String { "uuid" }
}
