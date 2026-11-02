import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

// 원본에 없는 테스트. 04a 의 제출 흐름과 입력 규칙을 뷰 없이 확인한다.

private final class FakeLoginRepository: UnsupportedAuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let gate = Gate()
    let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
        super.init()
    }

    var logins: [String] {
        lock.withLock { calls }
    }

    override func login(loginId: String, password: String) async throws -> String {
        lock.withLock { calls.append("\(loginId)/\(password)") }
        await gate.wait()
        if let failure { throw failure }
        return "uuid"
    }
}

@MainActor
@Suite struct LoginViewModelTest {
    private let clock = VirtualClock()

    @Test("성공하면 loggedIn 이 켜진다")
    func success() async {
        let repository = FakeLoginRepository()
        repository.gate.open()
        let viewModel = LoginViewModel(repository: repository)

        viewModel.login(loginId: "moyeota", password: "pw")
        await clock.settle()

        #expect(viewModel.uiState == LoginViewModel.UiState(loggedIn: true))
        #expect(repository.logins == ["moyeota/pw"])
    }

    @Test("실패 문구는 표에서 오고 다시 제출하면 지워진다")
    func failure() async {
        let repository = FakeLoginRepository(failure: AuthException(error: .loginFailed))
        repository.gate.open()
        let viewModel = LoginViewModel(repository: repository)

        viewModel.login(loginId: "moyeota", password: "pw")
        await clock.settle()
        #expect(viewModel.uiState.errorMessage == "아이디 또는 비밀번호가 올바르지 않아요")
        #expect(!viewModel.uiState.submitting)

        viewModel.login(loginId: "moyeota", password: "pw")
        #expect(viewModel.uiState.errorMessage == nil)
        #expect(viewModel.uiState.submitting)
        await clock.settle()
    }

    @Test("제출 중에는 두 번 보내지 않는다")
    func doubleSubmit() async {
        let repository = FakeLoginRepository()
        let viewModel = LoginViewModel(repository: repository)

        viewModel.login(loginId: "moyeota", password: "pw")
        viewModel.login(loginId: "moyeota", password: "pw")
        await clock.settle()
        #expect(repository.logins.count == 1)
        #expect(viewModel.uiState.submitting)

        repository.gate.open()
        await clock.settle()
        #expect(viewModel.uiState.loggedIn)
    }

    // 코어의 `HttpClient` 는 태스크가 취소됐을 때의 `URLError(.cancelled)` 를 `CancellationError` 로 바꾼다.
    // 그러니 `URLError(.cancelled)` 가 그대로 올라오면 태스크는 살아 있고, 아무도 잠금을 풀어 주지 않는다.
    @Test("태스크가 살아 있는데 URLError(.cancelled) 로 끝나면 네트워크 실패로 받고 다시 누를 수 있다")
    func liveUrlCancellation() async {
        let repository = FakeLoginRepository(failure: URLError(.cancelled))
        repository.gate.open()
        let viewModel = LoginViewModel(repository: repository)

        viewModel.login(loginId: "moyeota", password: "pw")
        await clock.settle()

        #expect(!viewModel.uiState.submitting)
        #expect(viewModel.uiState.errorMessage == "네트워크 연결을 확인해 주세요")

        viewModel.login(loginId: "moyeota", password: "pw")
        await clock.settle()
        #expect(repository.logins.count == 2)
    }

    @Test("태스크가 살아 있는데 CancellationError 로 끝나도 제출 중으로 남지 않는다")
    func liveCancellationError() async {
        let repository = FakeLoginRepository(failure: CancellationError())
        repository.gate.open()
        let viewModel = LoginViewModel(repository: repository)

        viewModel.login(loginId: "moyeota", password: "pw")
        await clock.settle()

        #expect(!viewModel.uiState.submitting)
        #expect(viewModel.uiState.errorMessage == "잠시 후 다시 시도해 주세요")
    }

    @Test("아이디 입력은 공백을 빼고 소문자로 받는다")
    func loginIdRule() {
        #expect(loginIdInput(raw: " MoYeo Ta\t") == "moyeota")
        #expect(loginIdInput(raw: "a\u{3000}B") == "ab")
    }
}
