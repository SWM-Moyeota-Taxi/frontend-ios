import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 가입 제출 — 12 매너 서약의 「동의하고 가입 완료」 뒤에 있는 유일한 서버 호출 지점.
///
/// 가입은 로그인시키지 않는다(서버가 토큰 대신 uuid 만 준다). 그래서 **가입 성공 직후
/// 같은 자격증명으로 로그인을 이어서 호출**해야 13 완료 화면 다음에 홈이 열린다.
@MainActor
@Observable
final class SignupViewModel {
    struct UiState: Equatable, Sendable {
        var submitting: Bool
        var errorMessage: String?
        var done: Bool
        /// 409 USER108 — 닉네임이 그 사이 선점됐다.
        /// 이 화면에서는 고칠 수 없는 값이라 12 는 배너에 "닉네임 바꾸기" 를 함께 띄우고 10 으로 되돌린다.
        var nicknameDuplicated: Bool
        /// 400 `USER207` — 가입에 실은 `verificationToken` 이 거절됐다(만료·소진·번호 불일치).
        ///
        /// **가입 실패 중 유일하게 문자 인증을 다시 받아야 하는 경우**다
        /// (`signupErrorNeedsReverify`). 아이디·닉네임 중복(409)은 토큰을 태우지 않으므로
        /// 여기서 재시도하거나 10 으로 돌아가 입력만 고치면 된다 — 그 경우에까지 재인증을 시키면
        /// 고칠 곳이 닉네임 한 글자인데 문자부터 다시 받게 하는 셈이다.
        var phoneNotVerified: Bool

        init(
            submitting: Bool = false,
            errorMessage: String? = nil,
            done: Bool = false,
            nicknameDuplicated: Bool = false,
            phoneNotVerified: Bool = false
        ) {
            self.submitting = submitting
            self.errorMessage = errorMessage
            self.done = done
            self.nicknameDuplicated = nicknameDuplicated
            self.phoneNotVerified = phoneNotVerified
        }
    }

    private(set) var uiState = UiState()

    @ObservationIgnored private let repository: any AuthRepository
    @ObservationIgnored private let scope = ViewModelScope()

    /// 가입은 성공했는데 이어지는 로그인만 실패한 경우를 기억한다.
    ///
    /// 이 플래그가 없으면 재시도 때 가입부터 다시 시도해 **409 아이디 중복**을 맞고,
    /// 사용자는 "방금 만든 계정이 이미 있다"는 막다른 길에 갇힌다.
    @ObservationIgnored private var registered = false

    init(repository: any AuthRepository) {
        self.repository = repository
    }

    func submit(draft: SignupDraft) {
        if uiState.submitting { return } // 중복 제출 차단 (공통 규칙)
        guard let newUser = draft.toNewUser() else {
            uiState.errorMessage = "가입 정보가 부족해요. 이전 단계를 다시 확인해 주세요"
            return
        }
        // 태스크 시작을 기다리지 않고 바로 켠다 — 원본 `Main.immediate` 처럼 다음 입력 전에 제출 중이어야 차단이 된다.
        uiState.submitting = true
        uiState.errorMessage = nil
        uiState.nicknameDuplicated = false
        uiState.phoneNotVerified = false
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                if self?.registered == false {
                    _ = try await repository.register(newUser: newUser)
                    self?.registered = true
                }
                // 자동 로그인 — 여기서 토큰이 저장되고 authState 가 authenticated 로 바뀐다
                _ = try await repository.login(loginId: newUser.loginId, password: newUser.password)
                self?.uiState.submitting = false
                self?.uiState.done = true
                // 핵심 퍼널 1단계. 성별·연령대는 서버가 다시 돌려주지 않으므로 가입 폼의 값에서 여기서만 나온다.
                Analytics.track(.signupCompleted(
                    gender: newUser.gender,
                    ageBand: ageBand(birthDate: newUser.birthDate, today: LocalDate.now())
                ))
            } catch {
                guard let self else { return }
                self.uiState.submitting = false
                // 태스크가 정말 취소됐을 때만 배너 없이 끝낸다. 살아 있는 태스크의 `URLError(.cancelled)` 는 네트워크 실패다.
                guard let failure = authFailureOnLiveTask(error: error) else { return }
                let authError = (failure as? AuthException)?.error
                self.uiState.errorMessage = failure.authUserMessage()
                // 닉네임 중복만 따로 표시한다 — 이 화면에 없는 필드라 되돌아갈 경로를 함께 줘야 한다
                self.uiState.nicknameDuplicated = authError == .nicknameDuplicated
                // 토큰이 거절된 경우도 이 화면에서 고칠 수 없다 — 10 의 인증 블록으로 되돌려야 한다
                self.uiState.phoneNotVerified = signupErrorNeedsReverify(error: authError)
            }
        }
    }
}

// 12 매너 서약 — 동의 + 가입 제출 + 자동 로그인 진입점. 성공하면 13 가입 완료로 넘긴다.
public struct MannerPledgeRoute: View {
    private let draft: SignupDraft
    private let onBack: () -> Void
    private let onCompleted: () -> Void
    private let onEditNickname: () -> Void
    private let onReverifyPhone: () -> Void

    @HostedViewModel private var viewModel: SignupViewModel

    public init(
        repository: any AuthRepository,
        draft: SignupDraft,
        onBack: @escaping () -> Void = {},
        onCompleted: @escaping () -> Void = {},
        onEditNickname: @escaping () -> Void = {},
        onReverifyPhone: @escaping () -> Void = {}
    ) {
        self.draft = draft
        self.onBack = onBack
        self.onCompleted = onCompleted
        self.onEditNickname = onEditNickname
        self.onReverifyPhone = onReverifyPhone
        _viewModel = HostedViewModel(wrappedValue: SignupViewModel(repository: repository))
    }

    public var body: some View {
        let state = viewModel.uiState
        MannerPledgeScreen(
            onBack: onBack,
            onComplete: { viewModel.submit(draft: draft) },
            submitting: state.submitting,
            errorMessage: state.errorMessage,
            // 닉네임 중복일 때만 10 으로 돌아가는 길을 준다 — 다른 실패는 여기서 재시도하면 된다
            onEditNickname: state.nicknameDuplicated ? onEditNickname : nil,
            // 토큰이 거절된 경우에만 인증을 다시 하러 보낸다(10 이 인증 블록을 초기화한다)
            onReverifyPhone: state.phoneNotVerified ? onReverifyPhone : nil
        )
        .task(id: state.done) {
            if state.done { onCompleted() }
        }
    }
}
