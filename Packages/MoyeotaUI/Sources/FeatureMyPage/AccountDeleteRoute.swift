import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 37 이 보여 주는 「무엇이 지워지는가」 목록. **서버가 실제로 하는 일만 적는다.**
///
/// 각 줄의 근거(`UserDeletionService.delete` + 두 리스너):
/// | 문구 | 서버 동작 |
/// |---|---|
/// | 다시 로그인 불가 | `localUsers.deleteByUserId` — 아이디·비밀번호가 삭제된다 |
/// | 채팅방 나감 + 「탈퇴한 사용자」 | `ChatRoomUserDeletionListener` + `User.DELETED_DISPLAY_NAME` |
/// | 자주 가는 곳 삭제 | `FavoritePlaceUserDeletionListener` |
/// | 같은 번호 N일 재가입 불가 | `userDeletions.record` + `SmsVerificationService.send` 의 `USER109` |
///
/// **적지 않은 것이 더 중요하다.** 서버는 지난 합승 기록을 지우지 않는다 — 끝난 방의 멤버로는 남고
/// 이름만 가려진다. "모든 기록이 사라져요" 같은 말을 쓰면 지킬 수 없는 약속이 된다.
/// 진행 중인 합승 제약은 경고가 아니라 **실패 사유**라 여기 넣지 않는다
/// (서버에 물어봐야 아는 값이고, 눌렀을 때 `AuthError.ongoingPartyExists` 로 온다).
let AccountDeletionWarnings: [String] = [
    "지금 아이디와 비밀번호로는 다시 로그인할 수 없어요",
    "참여 중인 채팅방에서 모두 나가고, 함께 탄 사람들에게는 「탈퇴한 사용자」로 보여요",
    "저장해 둔 자주 가는 곳이 지워져요",
    "같은 휴대폰 번호로는 \(AuthPolicy.REJOIN_RESTRICTED_DAYS)일 동안 다시 가입할 수 없어요",
]

/// 「탈퇴하기」를 누를 수 있는가 — **비밀번호를 한 글자라도 썼고, 보내는 중이 아니다.**
///
/// 길이·형식을 보지 않는 건 의도다. 서버는 `@NotBlank` 만 보고 해시를 비교하므로
/// (`UserDeletionRequest`), 앱이 `AuthPolicy.isValidPassword` 로 좁히면 **규칙이 바뀌기 전에 가입한
/// 계정이 자기 비밀번호를 넣고도 버튼을 못 누르는** 상황이 생긴다. 틀림은 서버가 판정한다
/// (400 `USER111` → `AuthError.passwordMismatch`).
///
/// 공백만 입력한 경우는 막는다 — 서버 `@NotBlank` 가 어차피 400 `INVALID_REQUEST` 를 주는데,
/// 그 문구("입력한 정보를 다시 확인해 주세요")로는 사용자가 무엇을 고칠지 알 수 없다.
func canSubmitAccountDeletion(password: String, submitting: Bool = false) -> Bool {
    if submitting { return false }
    return !password.isBlank
}

/// 탈퇴 실패 문구를 어디에 그릴지.
enum AccountDeleteErrorSlot: Equatable, Sendable {
    /// 비밀번호 입력란 아래. 고칠 곳이 입력란에 있을 때만.
    case passwordField

    /// 버튼 위 배너. 입력으로 해결되지 않는 실패.
    case banner
}

/// 실패를 입력란과 배너 중 어디로 보낼지 가른다.
///
/// 기준은 하나다 — **사용자가 이 화면에서 고칠 수 있는가.** 비밀번호 오타만 그렇고
/// (다시 입력하면 된다), 나머지는 전부 이 화면 밖의 일이다: 진행 중인 합승은 합승 화면에서 나와야
/// 풀리고, 네트워크는 기다려야 하고, 세션 만료는 로그인으로 가야 한다.
///
/// 둘을 섞으면 입력란이 빨간데 고칠 게 없는 상태가 생기고, 사용자는 비밀번호를 계속 다시 친다.
func accountDeleteErrorSlot(error: AuthError) -> AccountDeleteErrorSlot {
    switch error {
    case .passwordMismatch: .passwordField
    default: .banner
    }
}

/// 37 회원 탈퇴의 상태·제출.
///
/// 비밀번호를 뷰모델에 두는 이유: 화면 복원 저장소(`@SceneStorage`)에 올리면 비밀번호가
/// **디스크에 남는다.** 여기 두면 프로세스 수명 안에만 남는다.
///
/// 원본 `viewModelScope` 는 `Main.immediate` 라 `launch` 의 첫 줄이 호출 자리에서 바로 돈다. `Task` 는 다음 차례에야
/// 돌므로, 첫 중단점 앞의 일(`submitting = true`, `onSubmitting`)은 태스크 **앞에** 둔다. 안 그러면 「탈퇴하기」를
/// 연달아 눌렀을 때 두 번 모두 게이트를 통과한다.
@MainActor
@Observable
public final class AccountDeleteViewModel {

    public struct UiState: Equatable, Sendable {
        public var password: String
        public var submitting: Bool
        /// 비밀번호 입력란 아래 오류. `AccountDeleteErrorSlot.passwordField` 로 분류된 실패만 온다.
        public var passwordError: String?
        /// 버튼 위 배너. 입력으로 해결되지 않는 실패.
        public var bannerError: String?

        public init(
            password: String = "",
            submitting: Bool = false,
            passwordError: String? = nil,
            bannerError: String? = nil
        ) {
            self.password = password
            self.submitting = submitting
            self.passwordError = passwordError
            self.bannerError = bannerError
        }
    }

    public private(set) var uiState = UiState()

    @ObservationIgnored private let repository: any AuthRepository

    /// 테스트가 제출이 끝나기를 기다리는 손잡이다(원본 테스트의 `advanceUntilIdle` 자리).
    @ObservationIgnored private(set) var deleteJob: Task<Void, Never>?

    public init(repository: any AuthRepository) {
        self.repository = repository
    }

    /// 고치는 순간 직전 오류를 지운다 — 빨간 입력란을 들고 타이핑하게 두지 않는다.
    ///
    /// **입력을 다듬지 않는다.** 닉네임·아이디와 달리 비밀번호는 공백도 유효한 문자일 수 있고
    /// (서버 패턴이 특수문자를 요구할 뿐 공백을 금지하지 않는다), trim 하면 사용자가 넣은 것과
    /// **다른 값**을 보내 "맞는 비밀번호인데 틀렸다"가 된다.
    public func onPasswordChange(raw: String) {
        uiState.password = raw
        uiState.passwordError = nil
        uiState.bannerError = nil
    }

    /// `DELETE /api/v1/users/me` 로 비밀번호를 보낸다.
    ///
    /// 성공하면 Repository 안에서 세션·로컬 기억이 비워지고 `authState` 가 전이한다 —
    /// **이 화면은 성공 뒤의 이동을 하지 않는다.** 내비게이션 층의 로그인 전이 감지가 스택을 통째로
    /// 비우며 04a 로 보내므로 이 화면도 그때 사라진다. 그래서 성공 경로에서는 `UiState.submitting` 을
    /// **켜 둔 채로 끝낸다** — 화면이 사라지기까지의 한두 프레임 동안 버튼이 로딩 상태로 남아,
    /// 눌릴 수 있는 버튼이 깜빡 보이는 일이 없다.
    ///
    /// 결과를 **세 갈래**로 알린다. 내비게이션 층은 세션이 사라진 이유를 이 신호들로만 구분할 수 있다:
    /// - `onSubmitting` — 요청을 보내기 직전. 아직 아무것도 모른다("보냈다"는 사실뿐이다).
    /// - `onDeleted` — 서버가 204 를 돌려줬다. **「탈퇴가 처리됐어요」를 말할 수 있는 유일한 지점.**
    /// - `onKept` — 실패해 세션이 그대로 남았다.
    ///
    /// 예전에는 `onSubmitting` 하나가 "탈퇴됐다"의 근거였다. 그러면 `DELETE /users/me` 가 401 →
    /// 재발급 실패로 끝나 세션이 사라졌을 때도 **계정이 살아 있는데** 로그인 화면에 「탈퇴가
    /// 처리됐어요」가 떴다(2026-10-28 결함).
    ///
    /// 요청·응답 처리를 `ViewModelScope` 밖의 태스크로 돌리는 이유(원본 `NonCancellable` 자리): 성공하면
    /// 세션이 사라져 내비게이션 층이 스택을 통째로 비우고 이 화면을 걷어낸다 → 뷰모델이 해제되며 스코프가
    /// **취소된다.** 그대로 두면 응답을 받아 놓고도 `onDeleted` 가 불리지 않아(또는 취소가 아래 catch 로
    /// 흘러들어 `onKept` 가 불려) 「탈퇴됐다」의 근거가 사라진다. 끊기지 않게 응답 처리까지 한 덩어리로 돌린다.
    /// 그래서 이 태스크는 아무도 취소하지 않고, 뷰모델이 먼저 사라져도 세 신호는 끝까지 간다.
    public func delete(
        onSubmitting: @escaping () -> Void = {},
        onDeleted: @escaping () -> Void = {},
        onKept: @escaping () -> Void = {}
    ) {
        let state = uiState
        guard canSubmitAccountDeletion(password: state.password, submitting: state.submitting) else { return }
        uiState.submitting = true
        uiState.passwordError = nil
        uiState.bannerError = nil
        onSubmitting()
        let repository = self.repository
        deleteJob = Task { [weak self] in
            do {
                try await repository.deleteAccount(password: state.password)
                // 204 를 받은 **이 자리**가 탈퇴를 말할 수 있는 지점이다
                onDeleted()
                // 세션이 곧 사라지며 리포터가 사용자 연결을 끊는다 — 그 전에 기록해야 탈퇴한 사람의 이벤트로 남는다.
                Analytics.track(.accountDeleted)
                // 비밀번호를 상태에 남기지 않는다 — 화면은 곧 사라지지만 뷰모델이 몇 프레임 더 산다.
                // submitting 은 끄지 않는다(위 주석): 이 화면은 성공 후 로딩 상태로 사라진다.
                self?.uiState.password = ""
            } catch {
                onKept()
                // 이 태스크는 아무도 취소하지 않는다. `URLError(.cancelled)` 가 왔다면 원본의 `IOException` 이라 네트워크 실패로 옮긴다.
                let failure = authFailureOnLiveTask(error: error) ?? error
                let authError = (failure as? AuthException)?.error ?? AuthError.unknown
                let message = failure.authUserMessage()
                guard let self else { return }
                var next = self.uiState
                next.submitting = false
                switch accountDeleteErrorSlot(error: authError) {
                case .passwordField:
                    // 틀린 비밀번호는 비워 준다 — 고쳐 치는 것보다 다시 치는 쪽이 빠르다.
                    next.password = ""
                    next.passwordError = message
                case .banner:
                    next.bannerError = message
                }
                self.uiState = next
            }
        }
    }
}

/// 37 회원 탈퇴 — `DELETE /api/v1/users/me` 진입점.
///
/// - Parameter onSessionEndExpected: 서버에 탈퇴를 보내기 **직전**. 내비게이션 층이 "지금 뜬 로그아웃 전이는
///   탈퇴 때문일 수 있다"고 표시해 두는 자리다 — 안 하면 성공 직후 로그인 화면에
///   「세션이 만료됐어요」가 뜬다(스스로 탈퇴한 사람에게 할 말이 아니다).
/// - Parameter onDeleted: 서버가 204 를 돌려줬다. **「탈퇴가 처리됐어요」의 유일한 근거**이고, 요청만
///   보낸 상태(`onSessionEndExpected`)와 반드시 구분돼야 한다 — 401 로 끝난 탈퇴에도 그 안내가
///   뜨면 계정이 살아 있는 사람에게 거짓을 말한다.
/// - Parameter onSessionKept: 탈퇴가 실패해 세션이 그대로 남았다. 위 표시를 되돌린다.
///
/// 성공 뒤의 **이동**은 여기서 하지 않는다 — 세션이 사라지면 내비게이션 층의 로그인 전이가 스택을
/// 비우며 04a 로 보내므로 이 화면이 할 이동이 없다. 여기서 또 이동하면 그 전이와 겹친다.
public struct AccountDeleteRoute: View {
    private let onBack: () -> Void
    private let onSessionEndExpected: () -> Void
    private let onDeleted: () -> Void
    private let onSessionKept: () -> Void

    @HostedViewModel private var viewModel: AccountDeleteViewModel

    public init(
        repository: any AuthRepository,
        onBack: @escaping () -> Void = {},
        onSessionEndExpected: @escaping () -> Void = {},
        onDeleted: @escaping () -> Void = {},
        onSessionKept: @escaping () -> Void = {}
    ) {
        self.onBack = onBack
        self.onSessionEndExpected = onSessionEndExpected
        self.onDeleted = onDeleted
        self.onSessionKept = onSessionKept
        _viewModel = HostedViewModel(wrappedValue: AccountDeleteViewModel(repository: repository))
    }

    public var body: some View {
        let state = viewModel.uiState
        AccountDeleteScreen(
            password: state.password,
            submitting: state.submitting,
            passwordError: state.passwordError,
            bannerError: state.bannerError,
            onPasswordChange: { viewModel.onPasswordChange(raw: $0) },
            onDelete: {
                viewModel.delete(
                    onSubmitting: onSessionEndExpected,
                    onDeleted: onDeleted,
                    onKept: onSessionKept
                )
            },
            onBack: onBack
        )
    }
}
