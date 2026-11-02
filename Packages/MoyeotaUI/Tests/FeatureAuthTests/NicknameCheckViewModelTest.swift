import Foundation
import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureAuth

// 원본에 없는 테스트. 10 프로필 만들기의 닉네임 조회 규칙을 뷰 없이 확인한다.

private final class FakeNicknameRepository: UnsupportedAuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let result: @Sendable (String) throws -> Bool
    let gate = Gate()

    init(result: @escaping @Sendable (String) throws -> Bool) {
        self.result = result
        super.init()
    }

    var asked: [String] {
        lock.withLock { recorded }
    }

    override func isNicknameTaken(nickname: String) async throws -> Bool {
        lock.withLock { recorded.append(nickname) }
        await gate.wait()
        return try result(nickname)
    }
}

@MainActor
@Suite struct NicknameCheckViewModelTest {
    private let clock = VirtualClock()

    private func makeViewModel(_ repository: FakeNicknameRepository) -> NicknameCheckViewModel {
        let clock = self.clock
        return NicknameCheckViewModel(repository: repository, sleep: { try await clock.sleep($0) })
    }

    @Test("입력이 500ms 멈춘 뒤에만 묻는다")
    func debounces() async {
        let repository = FakeNicknameRepository { _ in false }
        repository.gate.open()
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(499))
        #expect(repository.asked.isEmpty)
        #expect(viewModel.state == .idle)

        await clock.advance(by: .milliseconds(1))
        #expect(repository.asked == ["모여"])
        #expect(viewModel.state == .available)
    }

    @Test("다음 타자가 들어오면 앞 조회는 나가지 않는다")
    func typingCancelsPrevious() async {
        let repository = FakeNicknameRepository { _ in true }
        repository.gate.open()
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(300))
        viewModel.onNicknameChanged(raw: "모여요")
        await clock.advance(by: .milliseconds(500))

        #expect(repository.asked == ["모여요"])
        #expect(viewModel.state == .taken)
    }

    @Test("형식이 안 맞으면 묻지 않고 idle 로 돌아간다")
    func invalidFormatStaysIdle() async {
        let repository = FakeNicknameRepository { _ in false }
        repository.gate.open()
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(500))
        #expect(viewModel.state == .available)

        viewModel.onNicknameChanged(raw: "모")
        await clock.advanceUntilIdle()
        #expect(viewModel.state == .idle)
        #expect(repository.asked == ["모여"])
    }

    @Test("조회 중에는 checking 이고, 그 사이 입력이 바뀌면 옛 응답을 버린다")
    func staleResponseDropped() async {
        let repository = FakeNicknameRepository { _ in false }
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(500))
        #expect(viewModel.state == .checking)

        viewModel.onNicknameChanged(raw: "모")
        repository.gate.open()
        await clock.advanceUntilIdle()
        #expect(viewModel.state == .idle)
    }

    @Test("실패 코드가 상태로 갈린다", arguments: [
        (AuthException(error: .invalidNickname), NicknameCheckState.invalidFormat),
        (AuthException(error: .invalidRequest, serverMessage: "nickname: 형식"), NicknameCheckState.invalidFormat),
        (AuthException(error: .invalidRequest, serverMessage: "phoneNumber: 형식"), NicknameCheckState.unknown),
        (AuthException(error: .invalidRequest), NicknameCheckState.unknown),
        (AuthException(error: .network), NicknameCheckState.unknown),
    ])
    func failureMapping(failure: AuthException, expected: NicknameCheckState) async {
        let repository = FakeNicknameRepository { _ in throw failure }
        repository.gate.open()
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(500))

        #expect(viewModel.state == expected)
    }

    // 코어의 `HttpClient` 는 태스크가 취소됐을 때의 `URLError(.cancelled)` 를 `CancellationError` 로 바꾼다.
    // 그러니 이 둘이 태스크가 살아 있는 채 올라오면 아무도 `checking` 을 내려 주지 않는다.
    @Test("태스크가 살아 있는데 취소 오류로 끝나면 checking 에 남지 않고 unknown 으로 내려간다", arguments: [
        URLError(.cancelled) as any Error,
        CancellationError() as any Error,
    ])
    func liveCancellationFallsToUnknown(failure: any Error) async {
        let repository = FakeNicknameRepository { _ in throw failure }
        repository.gate.open()
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(500))

        #expect(viewModel.state == .unknown)
    }

    @Test("다음 타자가 취소한 옛 요청은 오류로 끝나도 상태를 쓰지 않는다", arguments: [
        URLError(.cancelled) as any Error,
        CancellationError() as any Error,
        AuthException(error: .network) as any Error,
    ])
    func cancelledRequestWritesNothing(failure: any Error) async {
        let repository = FakeNicknameRepository { _ in throw failure }
        let viewModel = makeViewModel(repository)

        viewModel.onNicknameChanged(raw: "모여")
        await clock.advance(by: .milliseconds(500))
        #expect(viewModel.state == .checking)

        viewModel.onNicknameChanged(raw: "모")
        repository.gate.open()
        await clock.advanceUntilIdle()

        #expect(viewModel.state == .idle)
    }

    @Test("AuthException 이 아닌 실패는 unknown 이다")
    func otherFailureIsUnknown() {
        #expect(nicknameCheckFailureState(error: UnexpectedCall(reason: "그 밖")) == .unknown)
    }
}
