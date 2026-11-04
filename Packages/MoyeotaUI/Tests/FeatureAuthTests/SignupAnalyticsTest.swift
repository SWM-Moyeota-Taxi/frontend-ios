import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

// 12 매너 서약이 핵심 퍼널 1단계(`complete_signup`)를 **가입 + 자동 로그인이 모두 끝난 뒤** 기록하고,
// 생년월일이 아니라 연령대를, 성별은 소문자 상수를 싣는지 본다.

private final class AnalyticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AnalyticsEvent] = []
    func add(_ event: AnalyticsEvent) { lock.withLock { entries.append(event) } }
    var seen: [AnalyticsEvent] { lock.withLock { entries } }
}

private enum AnalyticsCapture {
    @TaskLocal static var current: AnalyticsRecorder?
}

private final class FakeSignupRepository: UnsupportedAuthRepository, @unchecked Sendable {
    var loginFailure: (any Error)?

    override func register(newUser: NewUser) async throws -> String { "uuid" }

    override func login(loginId: String, password: String) async throws -> String {
        if let loginFailure { throw loginFailure }
        return "uuid"
    }
}

@MainActor
@Suite(.serialized)
final class SignupAnalyticsTest {
    private let recorder = AnalyticsRecorder()
    private let clock = VirtualClock()

    /// 1995-03-15 생 — 2026 년 기준 만 30~31세, 연령대 30s.
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

    init() {
        Analytics.install { event in AnalyticsCapture.current?.add(event) }
    }

    deinit {
        Analytics.reset()
    }

    @Test("가입 + 자동 로그인이 끝나면 complete_signup 에 성별과 연령대만 싣는다")
    func signupTracksGenderAndAgeBand() async {
        let viewModel = SignupViewModel(repository: FakeSignupRepository())

        await AnalyticsCapture.$current.withValue(recorder) {
            viewModel.submit(draft: draft)
            await clock.settle()
        }

        #expect(viewModel.uiState.done)
        let expectedBand = ageBand(birthDate: date(1995, 3, 15), today: LocalDate.now())
        #expect(recorder.seen == [.signupCompleted(gender: .female, ageBand: expectedBand)])
        // 실명·휴대폰·이메일·생년월일 원문은 어디에도 없다
        let values = recorder.seen.flatMap { $0.properties.values }.compactMap { if case .string(let s) = $0 { s } else { nil } }
        #expect(!values.contains { $0.contains("홍길동") || $0.contains("0101234") || $0.contains("1995") || $0.contains("@") })
    }

    @Test("가입은 됐지만 로그인이 실패하면 아직 완료가 아니다")
    func loginFailureIsNotCompletion() async {
        let repository = FakeSignupRepository()
        repository.loginFailure = AuthException(error: .network)
        let viewModel = SignupViewModel(repository: repository)

        await AnalyticsCapture.$current.withValue(recorder) {
            viewModel.submit(draft: draft)
            await clock.settle()
        }

        #expect(!viewModel.uiState.done)
        #expect(recorder.seen.isEmpty)
    }
}
