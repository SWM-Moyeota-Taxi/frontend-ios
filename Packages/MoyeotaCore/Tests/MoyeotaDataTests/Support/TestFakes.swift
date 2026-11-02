import Foundation
import MoyeotaDomain
import os
@testable import MoyeotaData

final class FakeTokenHolder: TokenHolder {
    private struct State {
        var accessToken: String?
        var refreshToken: String?
        var sessionExpiredCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(accessToken: String?, refreshToken: String?) {
        state = OSAllocatedUnfairLock(uncheckedState: State(accessToken: accessToken, refreshToken: refreshToken))
    }

    var accessToken: String? { state.withLockUnchecked { $0.accessToken } }
    var refreshToken: String? { state.withLockUnchecked { $0.refreshToken } }
    var sessionExpiredCount: Int { state.withLockUnchecked { $0.sessionExpiredCount } }

    func currentAccessToken() async -> String? { accessToken }

    func currentRefreshToken() async -> String? { refreshToken }

    func onTokensRefreshed(accessToken: String, refreshToken: String) {
        state.withLockUnchecked {
            $0.accessToken = accessToken
            $0.refreshToken = refreshToken
        }
    }

    func onSessionExpired() {
        state.withLockUnchecked {
            $0.accessToken = nil
            $0.refreshToken = nil
            $0.sessionExpiredCount += 1
        }
    }
}

/// `result` 를 `RefreshResult` 로 받는 것이 중요하다. 예전 Fake 는 `TokenPair?` 하나로
/// 401·타임아웃·503 을 전부 null 로 뭉개서, 「재발급이 실패하면 세션 만료를 알린다」 테스트가
/// 오히려 결함(네트워크 실패를 인증 거절로 오인)을 통과 조건으로 고정하고 있었다.
final class FakeRefresher: TokenRefresher {
    private let result: RefreshResult
    private let delay: Duration
    private let used = OSAllocatedUnfairLock<[String]>(initialState: [])

    init(_ result: RefreshResult, delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    var usedRefreshTokens: [String] { used.withLock { $0 } }
    var callCount: Int { usedRefreshTokens.count }

    func refresh(refreshToken: String) async -> RefreshResult {
        used.withLock { $0.append(refreshToken) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result
    }
}

final class FakeTokenStorage: TokenStorage {
    private struct State {
        var saved: StoredSession?
        var cleared = false
    }

    private let initial: StoredSession?
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(_ initial: StoredSession?) {
        self.initial = initial
    }

    var saved: StoredSession? { state.withLockUnchecked { $0.saved } }
    var cleared: Bool { state.withLockUnchecked { $0.cleared } }

    func load() async throws -> StoredSession? { initial }

    func save(session: StoredSession) async throws {
        state.withLockUnchecked {
            $0.saved = session
            $0.cleared = false
        }
    }

    func clear() async throws {
        state.withLockUnchecked {
            $0.saved = nil
            $0.cleared = true
        }
    }
}

/// 지정한 경로에서 예외를 던지는 `TokenStorage`. Keychain 실패가 실제로 올라오는 자리를
/// 흉내 낸다 — 세 경로가 서로 독립이라 각각 켤 수 있게 두었다.
struct ThrowingTokenStorage: TokenStorage {
    var initial: StoredSession?
    var failOnLoad = false
    var failOnSave = false
    var failOnClear = false

    func load() async throws -> StoredSession? {
        if failOnLoad { throw IOException("세션 항목이 손상됐다") }
        return initial
    }

    func save(session: StoredSession) async throws {
        if failOnSave { throw IOException("디스크가 꽉 찼다") }
    }

    func clear() async throws {
        if failOnClear { throw IOException("디스크 실패") }
    }
}
