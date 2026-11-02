import Foundation
import MoyeotaDomain
@testable import FeatureAuth

/// `runTest` 의 가상 시간 자리. 뷰모델에 주입한 `sleep` 을 붙잡아 두고, 테스트가 시간을 옮겨 깨운다.
///
/// 뷰모델 태스크는 메인 액터에서 돌고 저장소 호출은 메인 밖으로 다녀오므로, 깨운 뒤에는 잠깐 양보해 그쪽 일이 끝나게 한다.
final class VirtualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var elapsed = Duration.zero
    private var sleepers: [Sleeper] = []

    /// 임의의 시작 시각(epoch millis).
    private let startMillis: Int64 = 1_800_000_000_000

    var currentMillis: Int64 {
        let (seconds, attoseconds) = lock.withLock { elapsed.components }
        return startMillis + seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    var pendingCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers.append(Sleeper(id: id, deadline: elapsed + duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// `advanceTimeBy`. 기한이 된 대기를 시각 순서대로 깨운다.
    @MainActor
    func advance(by duration: Duration) async {
        await settle()
        let target = lock.withLock { elapsed + duration }
        await run(until: target)
        lock.withLock { elapsed = max(elapsed, target) }
        await settle()
    }

    /// `advanceUntilIdle`. 깨울 대기가 없을 때까지 시간을 옮긴다.
    @MainActor
    func advanceUntilIdle() async {
        await settle()
        await run(until: nil)
    }

    @MainActor
    private func run(until target: Duration?) async {
        while true {
            while let next = popNext(until: target) {
                next.continuation.resume()
                for _ in 0..<5 { await Task.yield() }
            }
            await settle()
            let hasMore = lock.withLock {
                sleepers.contains { sleeper in target.map { sleeper.deadline <= $0 } ?? true }
            }
            if !hasMore { return }
        }
    }

    private func popNext(until target: Duration?) -> Sleeper? {
        lock.withLock {
            let due = sleepers.enumerated()
                .filter { entry in target.map { entry.element.deadline <= $0 } ?? true }
                .min { $0.element.deadline < $1.element.deadline }
            guard let due else { return nil }
            elapsed = max(elapsed, due.element.deadline)
            return sleepers.remove(at: due.offset)
        }
    }

    @MainActor
    func settle() async {
        for _ in 0..<3 {
            for _ in 0..<10 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(3))
        }
    }
}

struct UnexpectedCall: Error {
    let reason: String
}

/// 나머지 메서드는 불리면 **테스트가 터져야 한다** — 조용히 기본값을 돌려주면
/// 「엉뚱한 API 를 부른다」는 사고가 통과한다. 페이크는 필요한 것만 재정의한다.
class UnsupportedAuthRepository: AuthRepository, @unchecked Sendable {
    let authState: StateFlow<AuthState> = MutableStateFlow(AuthState.unauthenticated)

    func sendPhoneVerificationCode(phoneNumber: String) async throws { throw UnexpectedCall(reason: "발송") }
    func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String { throw UnexpectedCall(reason: "확인") }
    func register(newUser: NewUser) async throws -> String { throw UnexpectedCall(reason: "가입 제출은 12 매너 서약의 몫이다") }
    func isNicknameTaken(nickname: String) async throws -> Bool { throw UnexpectedCall(reason: "닉네임은 NicknameCheckViewModel 이 묻는다") }
    func isPhoneRegistered(phoneNumber: String) async throws -> Bool { throw UnexpectedCall(reason: "선확인") }
    func updateProfile(nickname: String?, imageKey: String?) async throws { throw UnexpectedCall(reason: "프로필 수정") }
    func getProfileImages() async throws -> [ProfileImage] { throw UnexpectedCall(reason: "이미지 목록") }
    func resetProfileImage() async throws { throw UnexpectedCall(reason: "이미지 되돌리기") }
    func login(loginId: String, password: String) async throws -> String { throw UnexpectedCall(reason: "로그인") }
    func logout() async throws { throw UnexpectedCall(reason: "로그아웃") }
    func deleteAccount(password: String) async throws { throw UnexpectedCall(reason: "탈퇴") }
    func getMyProfile() async throws -> UserProfileInfo { throw UnexpectedCall(reason: "내 정보") }
}

/// 테스트가 열어 줄 때까지 호출을 붙잡아 둔다 — "요청이 날아간 상태"를 재현한다.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            let current = waiters
            waiters = []
            return current
        }
        pending.forEach { $0.resume() }
    }
}

func date(_ year: Int, _ month: Int, _ day: Int) -> LocalDate {
    LocalDate(year: year, month: month, dayOfMonth: day)!
}
