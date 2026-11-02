import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 이 클래스의 계약은 "언제 서버를 부르고 언제 참는가" 하나다 — 잘못 부르면 401 이,
/// 참아야 할 때 안 참으면 도착 알림이 통째로 사라진다. 그래서 검증 대상은 전부 호출 여부/순서다.
@Suite struct FcmTokenRegistrarTest {

    @Test("로그인 상태면 받은 토큰을 곧바로 등록한다")
    func registersImmediatelyWhenAuthenticated() async throws {
        let api = FakeUserApi()

        try await registrar(api, authenticated()).onTokenAvailable(token: "device-token")

        #expect(api.registered.value == [FcmTokenRequest(token: "device-token")])
    }

    /// 미로그인 시 PUT 을 보내면 Bearer 가 없어 401 만 받는다. 조용히 보류해 두는 게 정답이고,
    /// 그 보류분은 다음 로그인에서 살아나야 한다 — 아래 테스트가 이어서 확인한다.
    @Test("미로그인 상태면 등록하지 않고 보류한다")
    func holdsWhenUnauthenticated() async throws {
        let api = FakeUserApi()

        try await registrar(api, unauthenticated()).onTokenAvailable(token: "device-token")

        #expect(api.registered.value.isEmpty)
    }

    @Test("보류된 토큰은 로그인 직후 등록된다")
    func pendingTokenRegisteredAfterLogin() async throws {
        let api = FakeUserApi()
        let session = FakeUserSession(.unauthenticated)
        let registrar = registrar(api, session)

        try await registrar.onTokenAvailable(token: "device-token")
        #expect(api.registered.value.isEmpty, "아직 로그인 전인데 보냈다")

        // 실제로는 RemoteAuthRepository.login 이 세션을 연 뒤 이 호출을 잇는다.
        session.state.value = .authenticated(userUuid: "uuid-1")
        try await registrar.registerPendingToken()

        #expect(api.registered.value == [FcmTokenRequest(token: "device-token")])
    }

    /// 서버는 토큰을 **사용자별로** 들고 있다. 같은 기기에 다른 계정이 로그인하면 그 계정 앞으로
    /// 다시 달아 줘야 하므로, 이미 한 번 보낸 토큰이라도 로그인 때마다 재전송하는 게 맞다.
    @Test("로그인할 때마다 같은 토큰을 다시 등록한다")
    func reRegistersOnEveryLogin() async throws {
        let api = FakeUserApi()
        let registrar = registrar(api, authenticated())

        try await registrar.onTokenAvailable(token: "device-token")
        try await registrar.registerPendingToken()

        #expect(api.registered.value.count == 2)
    }

    /// 보류분이 없으면 부를 게 없다 — 토큰 조회가 실패한 기기에서 헛된 400 을 만들지 않는다.
    @Test("보류된 토큰이 없으면 로그인해도 서버를 부르지 않는다")
    func noPendingTokenNoCall() async throws {
        let api = FakeUserApi()

        try await registrar(api, authenticated()).registerPendingToken()

        #expect(api.registered.value.isEmpty)
    }

    /// 서버 `@NotBlank` 에 걸려 400 만 받을 요청이다. 보낼 이유가 없다.
    @Test("빈 토큰은 보류도 전송도 하지 않는다")
    func blankTokenIgnored() async throws {
        let api = FakeUserApi()
        let registrar = registrar(api, authenticated())

        try await registrar.onTokenAvailable(token: "")
        try await registrar.registerPendingToken()

        #expect(api.registered.value.isEmpty)
    }

    @Test("해제는 서버 DELETE 를 호출한다")
    func unregisterCallsDelete() async throws {
        let api = FakeUserApi()

        try await registrar(api, authenticated()).unregister()

        #expect(api.deleteCount.value == 1)
    }

    /// 로그아웃 뒤에도 기기 토큰 자체는 유효하다. 지워 버리면 재로그인 시 등록할 값이 사라져,
    /// 앱을 껐다 켜기 전까지 도착 알림을 못 받는다.
    @Test("해제해도 보류 토큰은 남아 다음 로그인에 다시 등록된다")
    func pendingSurvivesUnregister() async throws {
        let api = FakeUserApi()
        let registrar = registrar(api, authenticated())

        try await registrar.onTokenAvailable(token: "device-token")
        try await registrar.unregister()
        api.registered.value = []

        try await registrar.registerPendingToken()

        #expect(api.registered.value == [FcmTokenRequest(token: "device-token")])
    }

    /// 등록 실패를 위로 던지면 이 호출을 품고 있는 로그인/로그아웃이 실패한 것처럼 보인다.
    /// 잃는 건 도착 알림 하나뿐이므로 여기서 끊는 게 맞다.
    @Test("등록이 실패해도 예외를 올리지 않는다")
    func registerFailureSwallowed() async throws {
        let networkDown = FakeUserApi(failure: IOException("offline"))
        let unauthorized = FakeUserApi(failure: HttpException(Response<Void>.error(401, "")))

        // 던지면 이 테스트가 그대로 실패한다.
        try await registrar(networkDown, authenticated()).onTokenAvailable(token: "device-token")
        try await registrar(unauthorized, authenticated()).onTokenAvailable(token: "device-token")
    }

    @Test("해제가 실패해도 예외를 올리지 않는다")
    func unregisterFailureSwallowed() async throws {
        try await registrar(FakeUserApi(failure: IOException("offline")), authenticated()).unregister()
    }

    /// 취소까지 삼키면 구조적 동시성이 깨져, 스코프가 죽어도 이 호출만 살아남는다.
    @Test("취소는 삼키지 않고 그대로 전파한다")
    func cancellationPropagates() async {
        let api = FakeUserApi(failure: CancellationError())

        await #expect(throws: CancellationError.self, "취소가 삼켜졌다") {
            try await registrar(api, authenticated()).onTokenAvailable(token: "device-token")
        }
    }

    /// 앱 시작 직후 세션은 항상 `AuthState.unknown` 이다(디스크 복원이 비동기).
    /// 이걸 미로그인으로 단정하면 **이미 로그인한 사용자의 앱 시작 등록이 매번 보류로 새어 나가**,
    /// 재로그인 전까지 도착 알림을 못 받는다. 복원이 끝날 때까지 기다렸다 판단해야 한다.
    @Test("복원 전 Unknown 상태에서는 확정될 때까지 기다렸다 등록한다")
    func waitsWhileUnknown() async throws {
        let api = FakeUserApi()
        let session = FakeUserSession(.unknown)
        let registrar = registrar(api, session)

        let registering = Task { try await registrar.onTokenAvailable(token: "device-token") }
        // runCurrent 의 자리 — 가상 시간이 없어 대기에 들어갈 틈을 실제로 준다.
        try await Task.sleep(for: .milliseconds(50))
        #expect(api.registered.value.isEmpty, "Unknown 인데 벌써 보냈다")

        session.state.value = .authenticated(userUuid: "uuid-1")
        try await registering.value

        #expect(api.registered.value == [FcmTokenRequest(token: "device-token")])
    }

    /// iOS 추가분. 원본 `Flow.first` 는 취소되면 예외를 던지지만 `AsyncStream` 은 값 없이 끝난다.
    /// 그 끝남을 「미로그인」으로 접으면 취소가 조용히 사라지므로 구현이 취소로 되돌린다.
    @Test("Unknown 대기 중 취소되면 등록하지 않고 취소를 전파한다")
    func cancelledWhileWaitingForRestore() async throws {
        let api = FakeUserApi()
        let session = FakeUserSession(.unknown)
        let registrar = registrar(api, session)

        let registering = Task { try await registrar.onTokenAvailable(token: "device-token") }
        try await Task.sleep(for: .milliseconds(50))
        registering.cancel()

        await #expect(throws: CancellationError.self) { try await registering.value }
        #expect(api.registered.value.isEmpty)
    }

    private func registrar(_ api: any UserApi, _ session: any UserSession) -> FcmTokenRegistrar {
        FcmTokenRegistrar(userApi: api, session: session)
    }

    private func authenticated() -> FakeUserSession { FakeUserSession(.authenticated(userUuid: "uuid-1")) }

    private func unauthenticated() -> FakeUserSession { FakeUserSession(.unauthenticated) }
}

private final class FakeUserSession: UserSession {
    let state: MutableStateFlow<AuthState>
    var authState: StateFlow<AuthState> { state.asStateFlow() }

    init(_ initial: AuthState) {
        state = MutableStateFlow(initial)
    }
}

private final class FakeUserApi: UserApi {
    private let failure: (any Error)?
    let registered = Locked<[FcmTokenRequest]>([])
    let deleteCount = Locked(0)

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func getMyProfile() async throws -> UserProfileResponse {
        throw IllegalStateException("푸시 토큰 등록과 무관하다")
    }

    func updateProfile(request: UpdateProfileRequest) async throws {
        throw IllegalStateException("푸시 토큰 등록과 무관하다")
    }

    func getProfileImages() async throws -> [ProfileImageResponse] {
        throw IllegalStateException("푸시 토큰 등록과 무관하다")
    }

    func resetProfileImage() async throws {
        throw IllegalStateException("푸시 토큰 등록과 무관하다")
    }

    func registerFcmToken(request: FcmTokenRequest) async throws {
        if let failure { throw failure }
        registered.append(request)
    }

    func deleteFcmToken() async throws {
        if let failure { throw failure }
        deleteCount.update { $0 += 1 }
    }

    func deleteAccount(request: AccountDeletionRequest) async throws {
        throw IllegalStateException("푸시 토큰 등록과 무관하다")
    }

    // UserApi 에 탑승 기록 조회(GET /users/me/parties)가 들어와 생긴 구현. 이 테스트와 무관하다.
    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse {
        throw IllegalStateException("푸시 토큰 등록과 무관하다")
    }
}
