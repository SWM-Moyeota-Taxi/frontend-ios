import MoyeotaDomain
import Testing
@testable import MoyeotaData

@Suite struct SessionManagerTest {

    // `join` 이 원본 `Dispatchers.Unconfined` 의 자리다: 복원이 끝난 뒤에 돌려줘 테스트가 결정적이 된다.
    private func manager(_ storage: any TokenStorage) async -> (session: SessionManager, scope: CoroutineScope) {
        let scope = CoroutineScope()
        let session = SessionManager(storage: storage, scope: scope)
        await scope.join()
        return (session, scope)
    }

    @Test("앱 재시작 시 저장된 세션을 복원해 로그인 상태를 유지한다")
    func restoresStoredSession() async {
        let stored = StoredSession(userUuid: "uuid-1", accessToken: "saved.access", refreshToken: "saved.refresh")

        let (session, _) = await manager(FakeTokenStorage(stored))

        #expect(session.authState.value == .authenticated(userUuid: "uuid-1"))
        #expect(session.currentUserUuid == "uuid-1")
        #expect(session.isLoggedIn)
        #expect(await session.currentAccessToken() == "saved.access")
        #expect(await session.currentRefreshToken() == "saved.refresh")
    }

    @Test("저장된 세션이 없으면 미로그인으로 확정되고 토큰을 주지 않는다")
    func noStoredSession() async {
        let (session, _) = await manager(FakeTokenStorage(nil))

        #expect(session.authState.value == .unauthenticated)
        #expect(session.currentUserUuid == nil)
        #expect(!session.isLoggedIn)
        #expect(await session.currentAccessToken() == nil)
    }

    /// 세션이 아는 식별자는 UUID 하나뿐이다. 예전에는 채팅 헤더용 고정 memberId(1L)가 여기 있었지만
    /// 채팅도 `@CurrentUser` 로 넘어가면서 서버로 나가는 내부 PK 가 앱에서 완전히 사라졌다 —
    /// 되살리면 "누가 로그인해도 1번 사용자로 보이는" 버그가 그대로 돌아온다.
    @Test("세션은 내부 사용자 PK 를 들지 않고 UUID 만 복원한다")
    func onlyUuid() async {
        let (session, _) = await manager(
            FakeTokenStorage(StoredSession(userUuid: "uuid-1", accessToken: "a", refreshToken: "r"))
        )

        #expect(session.currentUserUuid == "uuid-1")
    }

    @Test("로그인하면 저장소에 기록하고 인증 상태로 바뀐다")
    func loginPersists() async throws {
        let storage = FakeTokenStorage(nil)
        let (session, _) = await manager(storage)
        let next = StoredSession(userUuid: "uuid-2", accessToken: "new.access", refreshToken: "new.refresh")

        try await session.onLoggedIn(newSession: next)

        #expect(session.authState.value == .authenticated(userUuid: "uuid-2"))
        #expect(storage.saved == next)
        #expect(await session.currentAccessToken() == "new.access")
    }

    @Test("재발급 결과는 메모리에 즉시 반영되고 저장소에도 기록된다")
    func refreshPersists() async {
        let storage = FakeTokenStorage(StoredSession(userUuid: "uuid-1", accessToken: "old.access", refreshToken: "old.refresh"))
        let (session, scope) = await manager(storage)

        session.onTokensRefreshed(accessToken: "new.access", refreshToken: "new.refresh")

        // 저장을 기다리기 전에 읽는다 — 메모리는 즉시 최신이어야 한다.
        #expect(await session.currentAccessToken() == "new.access")
        #expect(await session.currentRefreshToken() == "new.refresh")
        await scope.join()
        #expect(storage.saved == StoredSession(userUuid: "uuid-1", accessToken: "new.access", refreshToken: "new.refresh"))
        // 재발급은 로그인 상태를 바꾸지 않는다.
        #expect(session.authState.value == .authenticated(userUuid: "uuid-1"))
    }

    @Test("세션 만료는 상태와 저장소를 모두 비운다")
    func expiryClears() async {
        let storage = FakeTokenStorage(StoredSession(userUuid: "uuid-1", accessToken: "old.access", refreshToken: "old.refresh"))
        let (session, scope) = await manager(storage)

        session.onSessionExpired()
        await scope.join()

        #expect(session.authState.value == .unauthenticated)
        #expect(await session.currentAccessToken() == nil)
        #expect(storage.cleared)
    }

    @Test("로그아웃은 서버 무효화용 리프레시를 돌려주고 로컬을 먼저 비운다")
    func logoutReturnsRefresh() async {
        let storage = FakeTokenStorage(StoredSession(userUuid: "uuid-1", accessToken: "old.access", refreshToken: "old.refresh"))
        let (session, scope) = await manager(storage)

        let refreshToken = session.onLoggedOut()
        await scope.join()

        #expect(refreshToken == "old.refresh")
        #expect(session.authState.value == .unauthenticated)
        #expect(storage.cleared)
    }

    @Test("이미 로그아웃 상태에서 다시 로그아웃해도 안전하다")
    func logoutTwice() async {
        let (session, _) = await manager(FakeTokenStorage(nil))

        #expect(session.onLoggedOut() == nil)
        #expect(session.authState.value == .unauthenticated)
    }

    // ─────────────────────────── 저장소가 터지는 경로 ───────────────────────────
    // `FakeTokenStorage` 는 절대 예외를 던지지 않아 이 경로가 통째로 미검증이었다.
    // 실제로는 Keychain 이 잠김·항목 오류로 던질 수 있고, 그 예외를 삼켜 authState 가 unknown 에
    // 영구히 머물면 스플래시가 무한 스피너가 된다.

    /// 복원 실패를 `.unknown` 으로 남기면 `MainNavGraph` 가 스플래시만 그려 **무한 스피너**가
    /// 된다. 틀린 쪽으로 떨어지는 비용은 재로그인 한 번이므로, 모르면 미로그인으로 확정한다.
    @Test("복원이 실패하면 미로그인으로 확정된다")
    func restoreFailureIsUnauthenticated() async {
        let (session, _) = await manager(ThrowingTokenStorage(failOnLoad: true))

        #expect(session.authState.value == .unauthenticated)
        #expect(!session.isLoggedIn)
        #expect(session.currentUserUuid == nil)
    }

    /// 복원 대기가 풀리지 않으면 **모든 네트워크 요청이 복원 타임아웃(5초)까지 멈춘다.**
    /// 예외 경로에서도 반드시 풀려야 한다 — 즉시 답이 오는지를 경과 시간으로 확인한다.
    @Test("복원이 실패해도 토큰 대기가 즉시 풀린다")
    func restoreFailureReleasesWaiters() async {
        let (session, _) = await manager(ThrowingTokenStorage(failOnLoad: true))

        let clock = ContinuousClock()
        let startedAt = clock.now
        let accessToken = await session.currentAccessToken()
        let elapsed = startedAt.duration(to: clock.now)

        #expect(accessToken == nil)
        #expect(elapsed < .seconds(1), "복원 대기가 풀리지 않아 \(elapsed) 를 기다렸다")
    }

    /// 디스크가 꽉 찬 사용자를 로그인 자체에서 막으면 앱을 전혀 쓸 수 없다. 잃는 건 "다음 실행에서의
    /// 자동 로그인"뿐이고, 지금 이 세션은 메모리에 있어 그대로 동작해야 한다.
    @Test("로그인 저장이 실패해도 터지지 않고 인증 상태가 된다")
    func loginSaveFailure() async throws {
        let (session, _) = await manager(ThrowingTokenStorage(failOnSave: true))

        try await session.onLoggedIn(
            newSession: StoredSession(userUuid: "uuid-2", accessToken: "new.access", refreshToken: "new.refresh")
        )

        #expect(session.authState.value == .authenticated(userUuid: "uuid-2"))
        #expect(await session.currentAccessToken() == "new.access")
    }

    /// 재발급 결과 저장은 메모리를 뒤따르는 캐시 갱신이다 — 실패해도 메모리의 새 토큰은 유효하다.
    @Test("재발급 결과 저장이 실패해도 메모리 토큰은 갱신된다")
    func refreshSaveFailure() async {
        let (session, scope) = await manager(
            ThrowingTokenStorage(
                initial: StoredSession(userUuid: "uuid-1", accessToken: "old.access", refreshToken: "old.refresh"),
                failOnSave: true
            )
        )

        session.onTokensRefreshed(accessToken: "new.access", refreshToken: "new.refresh")
        await scope.join()

        #expect(await session.currentAccessToken() == "new.access")
        #expect(session.authState.value == .authenticated(userUuid: "uuid-1"))
    }

    /// 디스크 비우기 실패로 "로그아웃이 안 된 것처럼" 보이게 하지 않는다 — 화면은 이미 미로그인이다.
    @Test("세션 비우기가 실패해도 미로그인으로 전이한다")
    func clearFailure() async {
        let (session, scope) = await manager(
            ThrowingTokenStorage(
                initial: StoredSession(userUuid: "uuid-1", accessToken: "old.access", refreshToken: "old.refresh"),
                failOnClear: true
            )
        )

        session.onSessionExpired()
        await scope.join()

        #expect(session.authState.value == .unauthenticated)
        #expect(await session.currentAccessToken() == nil)
    }
}
