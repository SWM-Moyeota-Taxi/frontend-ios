import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureMyPage

// 원본 테스트에 없는 것들. 원본 `delete` 의 세 갈래 신호와, `NonCancellable` 을 Swift 로 옮기면서
// 저절로는 지켜지지 않는 성질(호출 자리의 동기 실행, 뷰모델이 먼저 사라져도 신호가 끝까지 간다)을 고정한다.

private struct NetworkDown: Error {}

/// 테스트가 풀어 줄 때까지 응답을 붙잡아 두는 문.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// 탈퇴만 받는 페이크. 나머지는 이 화면에서 불리면 테스트가 터져야 한다.
private final class AccountDeleteFakeAuthRepository: AuthRepository, @unchecked Sendable {
    private struct Unrelated: Error {}

    let authState: StateFlow<AuthState> = MutableStateFlow(.authenticated(userUuid: "user-uuid"))

    private let lock = NSLock()
    private let failure: (any Error)?
    private let gate: Gate?
    private var _passwords: [String] = []

    init(failure: (any Error)? = nil, gate: Gate? = nil) {
        self.failure = failure
        self.gate = gate
    }

    var passwords: [String] { lock.withLock { _passwords } }

    func deleteAccount(password: String) async throws {
        lock.withLock { _passwords.append(password) }
        if let gate { await gate.wait() }
        if let failure { throw failure }
    }

    func updateProfile(nickname: String?, imageKey: String?) async throws { throw unrelated() }
    func resetProfileImage() async throws { throw unrelated() }
    func getProfileImages() async throws -> [ProfileImage] { throw unrelated() }
    func isNicknameTaken(nickname: String) async throws -> Bool { throw unrelated() }
    func isPhoneRegistered(phoneNumber: String) async throws -> Bool { throw unrelated() }
    func sendPhoneVerificationCode(phoneNumber: String) async throws { throw unrelated() }
    func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String { throw unrelated() }
    func register(newUser: NewUser) async throws -> String { throw unrelated() }
    func login(loginId: String, password: String) async throws -> String { throw unrelated() }
    func logout() async throws { throw unrelated() }
    func getMyProfile() async throws -> UserProfileInfo { throw unrelated() }

    private func unrelated() -> any Error {
        Issue.record("37 회원 탈퇴와 무관한 호출이다")
        return Unrelated()
    }
}

/// 세 신호가 불린 순서.
@MainActor
private final class SignalLog {
    var events: [String] = []
}

@MainActor
@Suite struct AccountDeleteBehaviorTest {

    private func delete(_ viewModel: AccountDeleteViewModel, log: SignalLog) {
        viewModel.delete(
            onSubmitting: { log.events.append("submitting") },
            onDeleted: { log.events.append("deleted") },
            onKept: { log.events.append("kept") }
        )
    }

    @Test("성공하면 비밀번호를 비우고 submitting 은 켜 둔 채 끝낸다")
    func successKeepsSubmitting() async {
        let repository = AccountDeleteFakeAuthRepository()
        let viewModel = AccountDeleteViewModel(repository: repository)
        let log = SignalLog()
        viewModel.onPasswordChange(raw: " Passw0rd! ")

        delete(viewModel, log: log)
        await viewModel.deleteJob?.value

        // 입력을 다듬지 않고 그대로 보낸다
        #expect(repository.passwords == [" Passw0rd! "])
        #expect(log.events == ["submitting", "deleted"])
        #expect(viewModel.uiState.password.isEmpty)
        #expect(viewModel.uiState.submitting)
    }

    @Test("요청을 보내기 전에 호출 자리에서 submitting 을 켜 연타를 막는다")
    func doubleTapSendsOnce() async {
        let gate = Gate()
        let repository = AccountDeleteFakeAuthRepository(gate: gate)
        let viewModel = AccountDeleteViewModel(repository: repository)
        let log = SignalLog()
        viewModel.onPasswordChange(raw: "Passw0rd!")

        delete(viewModel, log: log)
        #expect(viewModel.uiState.submitting)
        #expect(log.events == ["submitting"])
        let job = viewModel.deleteJob

        delete(viewModel, log: log)
        await gate.open()
        await job?.value

        #expect(repository.passwords == ["Passw0rd!"])
        #expect(log.events == ["submitting", "deleted"])
    }

    @Test("빈 비밀번호로는 아무 신호도 보내지 않는다")
    func blankSendsNothing() {
        let repository = AccountDeleteFakeAuthRepository()
        let viewModel = AccountDeleteViewModel(repository: repository)
        let log = SignalLog()
        viewModel.onPasswordChange(raw: "   ")

        delete(viewModel, log: log)

        #expect(viewModel.deleteJob == nil)
        #expect(log.events.isEmpty)
        #expect(!viewModel.uiState.submitting)
    }

    @Test("비밀번호 불일치는 입력란으로 가고 입력을 비운다")
    func mismatchGoesToField() async {
        let repository = AccountDeleteFakeAuthRepository(failure: AuthException(error: .passwordMismatch))
        let viewModel = AccountDeleteViewModel(repository: repository)
        let log = SignalLog()
        viewModel.onPasswordChange(raw: "wrong")

        delete(viewModel, log: log)
        await viewModel.deleteJob?.value

        #expect(log.events == ["submitting", "kept"])
        #expect(viewModel.uiState.password.isEmpty)
        #expect(viewModel.uiState.passwordError == authErrorMessage(error: .passwordMismatch))
        #expect(viewModel.uiState.bannerError == nil)
        #expect(!viewModel.uiState.submitting)
    }

    @Test("진행 중 합승은 배너로 가고 입력을 남긴다")
    func ongoingPartyGoesToBanner() async {
        let repository = AccountDeleteFakeAuthRepository(failure: AuthException(error: .ongoingPartyExists))
        let viewModel = AccountDeleteViewModel(repository: repository)
        let log = SignalLog()
        viewModel.onPasswordChange(raw: "Passw0rd!")

        delete(viewModel, log: log)
        await viewModel.deleteJob?.value

        #expect(log.events == ["submitting", "kept"])
        #expect(viewModel.uiState.password == "Passw0rd!")
        #expect(viewModel.uiState.bannerError == authErrorMessage(error: .ongoingPartyExists))
        #expect(viewModel.uiState.passwordError == nil)
        #expect(!viewModel.uiState.submitting)
    }

    @Test("AuthException 이 아닌 실패는 배너의 일반 문구다")
    func otherFailureGoesToBanner() async {
        let repository = AccountDeleteFakeAuthRepository(failure: NetworkDown())
        let viewModel = AccountDeleteViewModel(repository: repository)
        viewModel.onPasswordChange(raw: "Passw0rd!")

        delete(viewModel, log: SignalLog())
        await viewModel.deleteJob?.value

        #expect(viewModel.uiState.bannerError == "잠시 후 다시 시도해 주세요")
    }

    /// 원본은 OkHttp `IOException("Canceled")` 이 NETWORK 가 된다. iOS 데이터 계층은 이 값을 그대로 통과시킨다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 네트워크 문구다")
    func liveUrlCancelIsNetwork() async {
        let repository = AccountDeleteFakeAuthRepository(failure: URLError(.cancelled))
        let viewModel = AccountDeleteViewModel(repository: repository)
        viewModel.onPasswordChange(raw: "Passw0rd!")

        delete(viewModel, log: SignalLog())
        await viewModel.deleteJob?.value

        #expect(viewModel.uiState.bannerError == authErrorMessage(error: .network))
        #expect(!viewModel.uiState.submitting)
    }

    @Test("고치는 순간 직전 오류를 지운다")
    func typingClearsErrors() async {
        let repository = AccountDeleteFakeAuthRepository(failure: AuthException(error: .passwordMismatch))
        let viewModel = AccountDeleteViewModel(repository: repository)
        viewModel.onPasswordChange(raw: "wrong")
        delete(viewModel, log: SignalLog())
        await viewModel.deleteJob?.value
        #expect(viewModel.uiState.passwordError != nil)

        viewModel.onPasswordChange(raw: "a")

        #expect(viewModel.uiState.passwordError == nil)
        #expect(viewModel.uiState.bannerError == nil)
    }

    /// 성공하면 세션이 사라져 화면이 걷히고 뷰모델이 해제된다. 응답을 받아 놓고 `onDeleted` 가 안 불리면
    /// 「탈퇴가 처리됐어요」의 근거가 사라진다 — 원본이 `NonCancellable` 로 막은 그 사고다.
    @Test("뷰모델이 먼저 사라져도 onDeleted 가 불린다")
    func deletedSignalSurvivesViewModel() async {
        let gate = Gate()
        let log = SignalLog()
        var viewModel: AccountDeleteViewModel? = AccountDeleteViewModel(
            repository: AccountDeleteFakeAuthRepository(gate: gate)
        )
        weak let released = viewModel
        viewModel?.onPasswordChange(raw: "Passw0rd!")
        delete(viewModel!, log: log)
        let job = viewModel?.deleteJob

        viewModel = nil
        #expect(released == nil)
        await gate.open()
        await job?.value

        #expect(log.events == ["submitting", "deleted"])
    }

    @Test("뷰모델이 먼저 사라져도 실패면 onKept 가 불린다")
    func keptSignalSurvivesViewModel() async {
        let gate = Gate()
        let log = SignalLog()
        var viewModel: AccountDeleteViewModel? = AccountDeleteViewModel(
            repository: AccountDeleteFakeAuthRepository(failure: NetworkDown(), gate: gate)
        )
        viewModel?.onPasswordChange(raw: "Passw0rd!")
        delete(viewModel!, log: log)
        let job = viewModel?.deleteJob

        viewModel = nil
        await gate.open()
        await job?.value

        #expect(log.events == ["submitting", "kept"])
    }

    @Test("경고 네 줄은 원본과 글자까지 같다")
    func warningsExact() {
        #expect(AccountDeletionWarnings == [
            "지금 아이디와 비밀번호로는 다시 로그인할 수 없어요",
            "참여 중인 채팅방에서 모두 나가고, 함께 탄 사람들에게는 「탈퇴한 사용자」로 보여요",
            "저장해 둔 자주 가는 곳이 지워져요",
            "같은 휴대폰 번호로는 30일 동안 다시 가입할 수 없어요",
        ])
    }
}
