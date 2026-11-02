import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

@MainActor
@Observable
public final class LoginViewModel {
    public struct UiState: Equatable, Sendable {
        public var submitting: Bool
        public var errorMessage: String?
        public var loggedIn: Bool

        public init(submitting: Bool = false, errorMessage: String? = nil, loggedIn: Bool = false) {
            self.submitting = submitting
            self.errorMessage = errorMessage
            self.loggedIn = loggedIn
        }
    }

    public private(set) var uiState = UiState()

    @ObservationIgnored private let repository: any AuthRepository
    @ObservationIgnored private let scope = ViewModelScope()

    public init(repository: any AuthRepository) {
        self.repository = repository
    }

    /// 성공 시 토큰 저장·`AuthRepository.authState` 전환까지 Repository 안에서 끝난다
    /// — 여기서 세션을 따로 보관하지 않는다 (21 보고서 §2).
    public func login(loginId: String, password: String) {
        if uiState.submitting { return } // 중복 제출 차단 (공통 규칙)
        // 태스크 시작을 기다리지 않고 바로 켠다 — 원본 `Main.immediate` 처럼 다음 입력 전에 제출 중이어야 차단이 된다.
        uiState.submitting = true
        uiState.errorMessage = nil
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                _ = try await repository.login(loginId: loginId, password: password)
                guard let self else { return }
                self.uiState.submitting = false
                self.uiState.loggedIn = true
            } catch {
                // 뷰모델이 해제돼 태스크가 취소된 경우만 조용히 끝낸다. 그 밖에는 제출 중으로 남기지 않는다.
                guard let failure = authFailureOnLiveTask(error: error) else { return }
                guard let self else { return }
                self.uiState.submitting = false
                self.uiState.errorMessage = failure.authUserMessage()
            }
        }
    }
}

// 04a 아이디 로그인 — 로그인 API 진입점. 성공하면 onLoggedIn 으로 14 홈에 넘긴다.
public struct LoginFormRoute: View {
    private let onBack: () -> Void
    private let onLoggedIn: () -> Void
    private let onSignUp: () -> Void
    private let noticeMessage: String?

    @HostedViewModel private var viewModel: LoginViewModel

    public init(
        repository: any AuthRepository,
        onBack: @escaping () -> Void = {},
        onLoggedIn: @escaping () -> Void = {},
        onSignUp: @escaping () -> Void = {},
        noticeMessage: String? = nil
    ) {
        self.onBack = onBack
        self.onLoggedIn = onLoggedIn
        self.onSignUp = onSignUp
        self.noticeMessage = noticeMessage
        _viewModel = HostedViewModel(wrappedValue: LoginViewModel(repository: repository))
    }

    public var body: some View {
        let state = viewModel.uiState
        LoginFormScreen(
            onBack: onBack,
            onSubmit: { loginId, password in viewModel.login(loginId: loginId, password: password) },
            onSignUp: onSignUp,
            submitting: state.submitting,
            errorMessage: state.errorMessage,
            // 로그인 실패 문구가 떴다면 "왜 이 화면인지"보다 그쪽이 급하다 — 안내는 접는다
            noticeMessage: state.errorMessage == nil ? noticeMessage : nil
        )
        .task(id: state.loggedIn) {
            if state.loggedIn { onLoggedIn() }
        }
    }
}
