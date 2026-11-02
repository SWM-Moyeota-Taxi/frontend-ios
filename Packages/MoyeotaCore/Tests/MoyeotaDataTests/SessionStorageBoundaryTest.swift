import Foundation
import MoyeotaDomain
import os
import Testing
@testable import MoyeotaData

/// 원본에 대응 테스트가 없는 iOS 쪽 경계. 코루틴·DataStore 가 해 주던 동작을 직접 구현한 자리들이다.
@Suite struct SessionStorageBoundaryTest {

    // MARK: - SessionManager

    private final class SlowLoadStorage: TokenStorage {
        let stored: StoredSession?
        let delay: Duration

        init(stored: StoredSession?, delay: Duration) {
            self.stored = stored
            self.delay = delay
        }

        func load() async throws -> StoredSession? {
            try await Task.sleep(for: delay)
            return stored
        }

        func save(session: StoredSession) async throws {}
        func clear() async throws {}
    }

    /// 앱 시작 직후의 요청이 토큰 없이 나가 401 을 맞으면 억울하게 로그아웃된다.
    @Test("복원 전에 부른 토큰 조회는 복원이 끝나기를 기다린다")
    func tokenWaitsForRestore() async {
        let stored = StoredSession(userUuid: "u", accessToken: "saved.access", refreshToken: "r")
        let session = SessionManager(
            storage: SlowLoadStorage(stored: stored, delay: .milliseconds(100)),
            scope: CoroutineScope()
        )

        #expect(session.authState.value == .unknown)
        #expect(await session.currentAccessToken() == "saved.access")
    }

    @Test("복원이 멈추면 타임아웃 뒤 토큰 없이 진행한다")
    func restoreTimeout() async {
        let session = SessionManager(
            storage: SlowLoadStorage(stored: nil, delay: .seconds(30)),
            scope: CoroutineScope(),
            restoreTimeout: .milliseconds(50)
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        #expect(await session.currentAccessToken() == nil)
        #expect(startedAt.duration(to: clock.now) < .seconds(5))
    }

    @Test("복원을 기다리던 태스크가 취소되면 대기가 풀린다")
    func cancelledWaiterIsReleased() async {
        let session = SessionManager(
            storage: SlowLoadStorage(stored: nil, delay: .seconds(30)),
            scope: CoroutineScope(),
            restoreTimeout: .seconds(30)
        )

        let waiter = Task { await session.currentAccessToken() }
        try? await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let startedAt = clock.now
        waiter.cancel()

        #expect(await waiter.value == nil)
        #expect(startedAt.duration(to: clock.now) < .seconds(5))
    }

    /// 스코프 취소는 실패가 아니다(앱 종료 등). 상태를 건드리지 않되 토큰 대기는 풀어 준다.
    @Test("복원 중 스코프가 취소되면 상태를 건드리지 않고 대기를 푼다")
    func scopeCancelDuringRestore() async {
        let scope = CoroutineScope()
        let session = SessionManager(
            storage: SlowLoadStorage(stored: nil, delay: .seconds(30)),
            scope: scope,
            restoreTimeout: .seconds(30)
        )

        scope.cancel()
        await scope.join()

        #expect(session.authState.value == .unknown)
        #expect(await session.currentAccessToken() == nil)
    }

    private final class SlowSaveStorage: TokenStorage {
        private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        var events: [String] { log.withLock { $0 } }

        func load() async throws -> StoredSession? {
            StoredSession(userUuid: "u", accessToken: "a", refreshToken: "r")
        }

        func save(session: StoredSession) async throws {
            try? await Task.sleep(for: .milliseconds(100))
            log.withLock { $0.append("save") }
        }

        func clear() async throws {
            log.withLock { $0.append("clear") }
        }
    }

    /// 뒤집히면 로그아웃한 토큰이 Keychain 에 남는다.
    @Test("저장소 쓰기는 시킨 순서대로 끝난다")
    func writesKeepOrder() async {
        let storage = SlowSaveStorage()
        let scope = CoroutineScope()
        let session = SessionManager(storage: storage, scope: scope)
        await scope.join()

        session.onTokensRefreshed(accessToken: "new.a", refreshToken: "new.r")
        session.onSessionExpired()
        await scope.join()

        #expect(storage.events == ["save", "clear"])
    }

    // MARK: - KeychainTokenStorage

    private final class InMemoryKeychain: KeychainItemStore {
        private struct State {
            var item: Data?
            var deleteCount = 0
            var failDelete = false
        }

        private let state: OSAllocatedUnfairLock<State>

        init(item: Data? = nil, failDelete: Bool = false) {
            state = OSAllocatedUnfairLock(uncheckedState: State(item: item, failDelete: failDelete))
        }

        var item: Data? { state.withLockUnchecked { $0.item } }
        var deleteCount: Int { state.withLockUnchecked { $0.deleteCount } }

        func stopFailing() {
            state.withLockUnchecked { $0.failDelete = false }
        }

        func read() throws -> Data? { item }

        func write(_ data: Data) throws {
            state.withLockUnchecked { $0.item = data }
        }

        func deleteAll() throws {
            try state.withLockUnchecked {
                if $0.failDelete { throw KeychainException(status: errSecInteractionNotAllowed) }
                $0.deleteCount += 1
                $0.item = nil
            }
        }
    }

    /// 테스트마다 빈 `UserDefaults`. 재설치는 「표시 없는 defaults」로 재현한다.
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let name = "moyeota-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    private let session = StoredSession(userUuid: "uuid-1", accessToken: "a.access", refreshToken: "a.refresh")

    @Test("저장한 세션을 그대로 읽고 비우면 없다")
    func keychainRoundTrip() async throws {
        try await withDefaults { defaults async throws in
            let storage = KeychainTokenStorage(keychain: InMemoryKeychain(), installMarker: InstallMarker(defaults: defaults))

            try await storage.save(session: session)
            #expect(try await storage.load() == session)

            try await storage.clear()
            #expect(try await storage.load() == nil)
        }
    }

    /// 재설치한 앱이 지운 앱의 세션으로 로그인된 채 켜지면 안 된다.
    @Test("재설치 후 첫 실행은 남은 Keychain 항목을 지우고 미로그인이다")
    func reinstallClearsStaleItem() async throws {
        try await withDefaults { defaults async throws in
            let keychain = InMemoryKeychain(
                item: Data(#"{"user_uuid":"old","access_token":"old.a","refresh_token":"old.r"}"#.utf8)
            )
            let storage = KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults))

            #expect(try await storage.load() == nil)
            #expect(keychain.item == nil)
        }
    }

    @Test("설치 표시가 있으면 다음 실행은 세션을 유지한다")
    func nextLaunchKeepsSession() async throws {
        try await withDefaults { defaults async throws in
            let keychain = InMemoryKeychain()
            try await KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults)).save(session: session)

            let relaunched = KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults))

            #expect(try await relaunched.load() == session)
            #expect(keychain.deleteCount == 1, "첫 실행의 정리 말고 또 지웠다")
        }
    }

    /// 첫 잠금 해제 전에는 지우기가 실패한다. 표시를 남기면 남은 토큰이 영영 살아남는다.
    @Test("남은 항목을 못 지우면 읽지 않고 던지며 다음 실행에 다시 지운다")
    func staleClearFailureRetries() async throws {
        try await withDefaults { defaults async throws in
            let keychain = InMemoryKeychain(
                item: Data(#"{"user_uuid":"old","access_token":"old.a","refresh_token":"old.r"}"#.utf8),
                failDelete: true
            )

            await #expect(throws: KeychainException.self) {
                try await KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults)).load()
            }

            keychain.stopFailing()
            #expect(try await KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults)).load() == nil)
            #expect(keychain.item == nil)
        }
    }

    /// 부분 저장은 세션이 아니다 — 반쪽 세션은 401 루프의 원인이 된다.
    @Test("셋 중 하나라도 비었으면 세션이 아니다")
    func partialItemIsNull() async throws {
        let partials = [
            #"{"user_uuid":"u","access_token":"a"}"#,
            #"{"user_uuid":"u","access_token":"  ","refresh_token":"r"}"#,
            #"{"access_token":"a","refresh_token":"r"}"#,
        ]
        for partial in partials {
            try await withDefaults { defaults async throws in
                let keychain = InMemoryKeychain()
                let storage = KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults))
                try await storage.clear()
                try keychain.write(Data(partial.utf8))

                #expect(try await storage.load() == nil, "\(partial)")
            }
        }
    }

    /// 읽을 때마다 던지면 복원이 매번 실패해 복구 수단이 재설치뿐이다.
    @Test("손상된 항목은 비우고 없는 것으로 친다")
    func corruptItemIsDiscarded() async throws {
        try await withDefaults { defaults async throws in
            let keychain = InMemoryKeychain()
            let storage = KeychainTokenStorage(keychain: keychain, installMarker: InstallMarker(defaults: defaults))
            try await storage.clear()
            try keychain.write(Data("not json".utf8))

            #expect(try await storage.load() == nil)
            #expect(keychain.item == nil)
        }
    }

    // MARK: - UserDefaultsActivePartyStorage

    @Test("진행 중인 방 기억을 저장하고 읽고 지운다")
    func activePartyRoundTrip() async throws {
        try await withDefaults { defaults async throws in
            let storage = UserDefaultsActivePartyStorage(defaults: defaults)
            let party = RememberedParty(partyId: "7", ownerUuid: "uuid-1")

            #expect(storage.load() == nil)
            storage.save(party: party)
            #expect(storage.load() == party)

            storage.clear()
            #expect(storage.load() == nil)
        }
    }

    /// 주인을 모르는 기억은 계정 가드를 걸 수 없으니 없는 것으로 친다.
    @Test("둘 중 하나가 비었거나 값이 깨졌으면 방 기억이 없다")
    func activePartyPartial() async throws {
        try await withDefaults { defaults async throws in
            let storage = UserDefaultsActivePartyStorage(defaults: defaults)

            storage.save(party: RememberedParty(partyId: "7", ownerUuid: " "))
            #expect(storage.load() == nil)

            storage.save(party: RememberedParty(partyId: "", ownerUuid: "uuid-1"))
            #expect(storage.load() == nil)

            defaults.set(42, forKey: "moyeota_active_party")
            #expect(storage.load() == nil)
        }
    }

    /// 로그아웃이 세션을 지워도 방 기억은 남아야 한다 — 저장소를 나눈 이유다.
    @Test("방 기억은 세션 저장소와 키를 공유하지 않는다")
    func activePartySeparateFromSession() async throws {
        try await withDefaults { defaults async throws in
            let party = UserDefaultsActivePartyStorage(defaults: defaults)
            party.save(party: RememberedParty(partyId: "7", ownerUuid: "uuid-1"))

            let tokens = KeychainTokenStorage(keychain: InMemoryKeychain(), installMarker: InstallMarker(defaults: defaults))
            try await tokens.save(session: session)
            try await tokens.clear()

            #expect(party.load() == RememberedParty(partyId: "7", ownerUuid: "uuid-1"))
        }
    }
}
