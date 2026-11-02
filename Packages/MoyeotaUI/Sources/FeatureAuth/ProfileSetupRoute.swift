import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 입력이 멈췄다고 보는 시간. 한 글자마다 서버를 두드리지 않기 위한 유일한 장치다.
private let NICKNAME_DEBOUNCE_MS = 500

/// 닉네임 중복 확인 실패 → 화면 상태.
///
/// 형식 오류가 두 코드로 온다: 서버 VO 가 먼저 걸리면 USER107,
/// Bean Validation 이 먼저 걸리면 INVALID_REQUEST(message = "nickname: …") — 같은 사실이다.
func nicknameCheckFailureState(error: any Error) -> NicknameCheckState {
    guard let authException = error as? AuthException else { return .unknown }
    let invalidFormat = authException.error == .invalidNickname ||
        (authException.error == .invalidRequest && authException.serverMessage?.hasPrefix("nickname") == true)
    return invalidFormat ? .invalidFormat : .unknown
}

/// 닉네임 중복 확인만 담당하는 뷰모델.
///
/// 가입 제출(12 매너 서약)은 `SignupViewModel` 이 따로 한다 — 이쪽은 입력 중 조회 하나뿐이라
/// 초안(`SignupDraft`)을 들고 있지 않다.
@MainActor
@Observable
final class NicknameCheckViewModel {
    private(set) var state: NicknameCheckState = .idle

    @ObservationIgnored private let repository: any AuthRepository
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()

    // 진행 중인 조회. 다음 타자가 들어오면 취소한다 — 늦게 도착한 옛 응답이 최신 입력을
    // 덮어쓰는 사고(디바운스 없이 흔한 결함)를 구조적으로 막는다.
    @ObservationIgnored private var job: Task<Void, Never>?

    init(
        repository: any AuthRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.sleep = sleep
    }

    func onNicknameChanged(raw: String) {
        job?.cancel()
        let value = raw.trim()
        // 태스크 시작을 기다리지 않고 바로 지운다 — 원본 `Main.immediate` 처럼 다음 그리기에 옛 결과가 남지 않는다.
        state = .idle
        // 형식이 안 맞으면 물어볼 것도 없다 — 화면이 이미 형식 오류를 띄우고 있다
        if !NicknamePolicy.isValid(raw: value) { return }
        let repository = self.repository
        let sleep = self.sleep
        job = scope.launch { [weak self] in
            do {
                try await sleep(.milliseconds(NICKNAME_DEBOUNCE_MS))
            } catch {
                return
            }
            if Task.isCancelled { return }
            self?.state = .checking
            let result: NicknameCheckState
            do {
                result = try await repository.isNicknameTaken(nickname: value) ? .taken : .available
            } catch {
                result = nicknameCheckFailureState(error: error)
            }
            // 다음 타자가 취소한 옛 요청은 응답이든 오류든 쓰지 않는다 — 상태는 그 호출이 이미 내려 뒀다
            // (`docs/IOS-DIFFERENCES.md`). 태스크가 살아 있는 `URLError(.cancelled)` 는 여기를 지나
            // `unknown` 이 된다. 내려 줄 호출이 없어 막으면 `checking` 이 남는다.
            if Task.isCancelled { return }
            self?.state = result
        }
    }
}

/// 10 프로필 만들기의 서버 호출 진입점 — 입력값 자체는 여전히 화면이 들고 있다.
///
/// 뷰모델이 둘인 이유는 두 호출의 성격이 다르기 때문이다:
/// - `NicknameCheckViewModel` — 입력 중 디바운스 조회 하나. 결과를 버려도 가입은 된다.
/// - `PhoneVerifyViewModel` — **가입 통과 조건**인 토큰을 들고 있고, 쿨다운·만료 타이머를 돌린다.
///   둘을 한 뷰모델로 합치면 닉네임 한 글자마다 인증 상태까지 같이 흔들리게 된다.
///
/// 두 뷰모델 모두 이 내비게이션 항목에 묶여 **12 매너 서약에 올라가 있는 동안 살아 있다** —
/// 닉네임 중복(409)으로 되돌아왔을 때 인증 토큰을 그대로 써야 하기 때문이다(재인증은 금지).
public struct ProfileSetupRoute: View {
    private let onBack: () -> Void
    private let onNext: (SignupDraft) -> Void
    private let onGoToLogin: () -> Void
    private let reverifyPhoneRequest: Int

    @HostedViewModel private var viewModel: NicknameCheckViewModel
    @HostedViewModel private var phoneViewModel: PhoneVerifyViewModel

    /// - Parameter reverifyPhoneRequest: 12 에서 가입이 `phoneNotVerified` 로 떨어져 되돌려 보낸 횟수.
    ///   값이 **바뀔 때마다** 인증 블록을 초기화한다. Bool 이 아니라 카운터인 이유는 같은 일이
    ///   두 번 이상 일어날 수 있고(토큰이 또 만료될 수 있다), Bool 이면 두 번째 신호를 놓치기 때문이다.
    ///   0 은 "아직 그런 일이 없었다"는 초기값이라 아무 동작도 하지 않는다.
    /// - Parameter onGoToLogin: 이미 가입된 번호(409)로 발송이 끊겼을 때 안내하는 길 — 04a 로그인으로 보낸다.
    public init(
        repository: any AuthRepository,
        onBack: @escaping () -> Void = {},
        onNext: @escaping (SignupDraft) -> Void = { _ in },
        onGoToLogin: @escaping () -> Void = {},
        reverifyPhoneRequest: Int = 0
    ) {
        self.onBack = onBack
        self.onNext = onNext
        self.onGoToLogin = onGoToLogin
        self.reverifyPhoneRequest = reverifyPhoneRequest
        _viewModel = HostedViewModel(wrappedValue: NicknameCheckViewModel(repository: repository))
        _phoneViewModel = HostedViewModel(wrappedValue: PhoneVerifyViewModel(repository: repository))
    }

    public var body: some View {
        ProfileSetupScreen(
            onBack: onBack,
            onNext: onNext,
            nicknameCheck: viewModel.state,
            onNicknameChange: { viewModel.onNicknameChanged(raw: $0) },
            phoneVerify: phoneViewModel.state,
            nowMillis: phoneViewModel.nowMillis,
            onPhoneDigitsChange: { phoneViewModel.onPhoneDigitsChanged(phoneDigits: $0) },
            onRequestVerificationCode: { phoneViewModel.requestCode(phoneDigits: $0) },
            onVerificationCodeChange: { phoneViewModel.onCodeChanged(raw: $0) },
            onSubmitVerificationCode: { phoneViewModel.verify() },
            onPhoneEditRequested: { phoneViewModel.onPhoneEditRequested() },
            onGoToLogin: onGoToLogin
        )
        // 신호를 뷰모델에 넘기고, 중복 적용 방어는 그쪽이 한다(이 작업은 12 에서 돌아와 다시 나타날 때도
        // 돌므로, 여기서 키만으로 판단하면 12 에서 뒤로 돌아올 때도 다시 적용된다).
        .task(id: reverifyPhoneRequest) {
            if reverifyPhoneRequest > 0 {
                phoneViewModel.onSignupRejectedPhone(requestId: reverifyPhoneRequest)
            }
        }
    }
}
