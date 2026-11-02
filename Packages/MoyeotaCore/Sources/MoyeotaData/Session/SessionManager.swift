import Foundation
import MoyeotaDomain
import os

/// 앱의 세션 단일 출처. 세 얼굴을 한 객체가 맡는다.
/// - `UserSession`: 화면이 보는 로그인 상태
/// - `TokenHolder`: HTTP 계층이 보는 토큰 창구
/// - `RemoteAuthRepository` 가 로그인/로그아웃 결과를 반영하는 대상
///
/// 나눠 두면 "메모리의 토큰"과 "디스크의 토큰"이 어긋나는 지점이 생겨 401 루프의 원인이 된다.
///
/// 메모리 캐시(`session`)가 항상 즉시 최신이고 디스크 반영은 뒤따른다(비동기). 요청에 실릴 토큰은
/// 메모리에서 읽으므로 저장이 늦어도 동작은 정확하고, 프로세스가 죽어 저장이 유실되면
/// 최악의 경우 재로그인 한 번이다.
public final class SessionManager: UserSession, TokenHolder {
    private let storage: any TokenStorage
    private let scope: CoroutineScope

    private let _authState = MutableStateFlow<AuthState>(.unknown)
    public var authState: StateFlow<AuthState> { _authState.asStateFlow() }

    private let session = OSAllocatedUnfairLock<StoredSession?>(initialState: nil)

    // 디스크 복원 완료 신호. 복원 전에 나간 요청이 토큰 없이 401 을 맞고 억울하게 로그아웃되는 걸 막는다.
    private let restored = RestoreLatch()

    /// 디스크 쓰기를 시킨 순서대로 돌린다. 앞뒤가 뒤집혀 `save` 가 `clear` 뒤에 끝나면 로그아웃한 토큰이 디스크에 남는다.
    private let lastWrite = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private let restoreTimeout: Duration

    private static let RESTORE_TIMEOUT: Duration = .seconds(5)

    /// **복원 실패는 「미로그인 확정」으로 떨어뜨린다.** 예외를 그냥 삼켜 `_authState` 가 `.unknown` 에
    /// 머물면 `MainNavGraph` 가 스플래시만 그린다(= **무한 스피너**). 복구 수단이 재설치뿐이다.
    ///
    /// 틀린 쪽으로 떨어지는 비용은 재로그인 한 번이므로, 모르면 미로그인으로 본다.
    public convenience init(storage: any TokenStorage, scope: CoroutineScope) {
        self.init(storage: storage, scope: scope, restoreTimeout: Self.RESTORE_TIMEOUT)
    }

    init(storage: any TokenStorage, scope: CoroutineScope, restoreTimeout: Duration) {
        self.storage = storage
        self.scope = scope
        self.restoreTimeout = restoreTimeout
        scope.launch { [self] in
            // 복원이 실패해도 반드시 풀어준다 — 안 그러면 모든 네트워크 요청이 타임아웃까지 멈춘다.
            defer { restored.countDown() }
            do {
                let loaded = try await storage.load()
                session.withLock { $0 = loaded }
                _authState.value = loaded.map { .authenticated(userUuid: $0.userUuid) } ?? .unauthenticated
            } catch where isCancellation(throwable: error) {
                // 스코프 취소는 실패가 아니다(앱 종료 등). 상태를 건드리지 않는다.
            } catch {
                session.withLock { $0 = nil }
                _authState.value = .unauthenticated
            }
        }
    }

    public func currentAccessToken() async -> String? {
        await restored.wait(timeout: restoreTimeout)
        return session.withLock { $0?.accessToken }
    }

    public func currentRefreshToken() async -> String? {
        await restored.wait(timeout: restoreTimeout)
        return session.withLock { $0?.refreshToken }
    }

    public func onTokensRefreshed(accessToken: String, refreshToken: String) {
        let updated = session.withLock { current -> StoredSession? in
            guard var next = current else { return nil }
            next.accessToken = accessToken
            next.refreshToken = refreshToken
            current = next
            return next
        }
        guard let updated else { return }
        launchWrite { [self] in try? await saveSwallowing(updated) }
    }

    public func onSessionExpired() {
        clearSession()
    }

    /// 로그인 성공 반영. 저장까지 기다리고 돌아온다 — 로그인 직후 앱이 죽어도 세션이 남게.
    ///
    /// **저장이 실패해도 로그인은 성공이다.** 디스크가 꽉 찼거나 키체인이 잠긴 사용자를 로그인 자체에서
    /// 막으면 앱을 전혀 쓸 수 없다. 잃는 건 "다음 실행에서의 자동 로그인"뿐이고, 지금 이 세션은
    /// 메모리에 있어 그대로 동작한다(클래스 주석의 "메모리가 항상 즉시 최신" 원칙).
    ///
    /// 취소만 던진다.
    public func onLoggedIn(newSession: StoredSession) async throws {
        session.withLock { $0 = newSession }
        let write = launchWrite { [self] () -> (any Error)? in
            do {
                try await saveSwallowing(newSession)
                return nil
            } catch {
                return error
            }
        }
        if let cancellation = await write.value { throw cancellation }
        try Task.checkCancellation()
        _authState.value = .authenticated(userUuid: newSession.userUuid)
        restored.countDown()
    }

    /// 로그아웃 반영. 서버 무효화 호출보다 **먼저** 부른다 — 서버가 실패해도 사용자는 나갈 수 있어야 한다.
    /// - Returns: 서버에 무효화 요청을 보낼 리프레시 토큰(없으면 null)
    public func onLoggedOut() -> String? {
        let refreshToken = session.withLock { $0?.refreshToken }
        clearSession()
        return refreshToken
    }

    private func clearSession() {
        session.withLock { $0 = nil }
        _authState.value = .unauthenticated
        launchWrite { [storage] in
            // 디스크 비우기 실패로 "로그아웃이 안 된 것처럼" 보이게 하지 않는다 — 메모리와 화면은
            // 이미 미로그인이다. 남은 항목은 다음 실행에서 복원되지만 그 토큰은 서버에서 이미
            // 무효화됐으므로 첫 요청의 401 → 재발급 거절 → 다시 미로그인으로 수렴한다.
            try? await storage.clear()
        }
        restored.countDown()
    }

    /// 디스크 저장 실패를 삼킨다. 세션 저장은 **메모리를 뒤따르는 캐시 갱신**이라 실패가 치명적이지 않다.
    /// 다음 저장 기회(재발급·재로그인)에 같은 값으로 다시 시도된다. 취소만 던진다.
    private func saveSwallowing(_ newSession: StoredSession) async throws {
        do {
            try await storage.save(session: newSession)
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            // 삼킨다.
        }
    }

    @discardableResult
    private func launchWrite<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        lastWrite.withLock { last in
            let previous = last
            let task = scope.launch { () -> T in
                _ = await previous?.value
                return await operation()
            }
            last = Task { _ = await task.value }
            return task
        }
    }
}

/// `CountDownLatch(1)` 의 자리 — 스레드를 막지 않고 기다린다.
private final class RestoreLatch: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func countDown() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    /// 로컬 디스크 1회 읽기라 사실상 즉시 끝난다. 타임아웃은 어떤 이유로든 복원이 멈췄을 때
    /// 앱 전체가 굳지 않게 하는 안전장치일 뿐이며, 지나면 미로그인으로 간주하고 진행한다.
    /// 기다리는 태스크가 취소돼도 풀려난다 — 값이 아니라 대기만 끝나므로 뒤따르는 요청이 취소로 끝난다.
    func wait(timeout: Duration) async {
        if state.withLock({ $0.isOpen }) { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isOpen = state.withLock { state -> Bool in
                    if state.isOpen { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if isOpen {
                    continuation.resume()
                    return
                }
                if Task<Never, Never>.isCancelled {
                    release(id)
                    return
                }
                Task { [self] in
                    try? await Task.sleep(for: timeout)
                    release(id)
                }
            }
        } onCancel: {
            release(id)
        }
    }

    private func release(_ id: UUID) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
    }
}
