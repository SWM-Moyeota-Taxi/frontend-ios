import Foundation
import MoyeotaDomain
import Testing
@testable import PresentationCore

// 원본 presentation 테스트에는 코루틴 테스트 라이브러리가 없어 뷰모델 흐름을 못 돌렸다.
// iOS 는 대기 함수를 주입할 수 있어 원본 주석이 「QA 의 logcat 계수가 그 몫」이라던 부분까지 여기서 본다.

private struct Failure: Error {}

@MainActor
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// ─── failureOnLiveTask ───

@Suite struct FailureOnLiveTaskTest {
    private struct Mapped: Error {}

    @Test("살아 있는 태스크의 URLError(.cancelled) 만 전달한 값으로 옮긴다")
    func mapsTransportCancelOnly() {
        #expect(failureOnLiveTask(error: URLError(.cancelled)) { _ in Mapped() } is Mapped)
        #expect(failureOnLiveTask(error: URLError(.timedOut)) { _ in Mapped() } is URLError)
        #expect(failureOnLiveTask(error: Failure()) { _ in Mapped() } is Failure)
    }

    @Test("옮길 값을 주지 않으면 URLError(.cancelled) 도 그대로 실패로 돌려준다")
    func defaultKeepsError() {
        #expect(failureOnLiveTask(error: URLError(.cancelled)) is URLError)
    }

    /// 삼키면 그 자리가 다시 잠금이 남는 길이 된다.
    @Test("살아 있는 태스크에 온 CancellationError 는 그대로 실패다")
    func liveCancellationErrorIsFailure() {
        #expect(failureOnLiveTask(error: CancellationError()) is CancellationError)
    }

    @Test("태스크가 정말 취소되면 무슨 오류로 끝나든 nil 이다")
    func cancelledTaskIsSilent() async {
        let silent = Task<Bool, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return failureOnLiveTask(error: URLError(.cancelled)) == nil
                && failureOnLiveTask(error: CancellationError()) == nil
                && failureOnLiveTask(error: Failure()) == nil
                && authFailureOnLiveTask(error: Failure()) == nil
        }
        #expect(await silent.value)
    }

    @Test("인증 판은 URLError(.cancelled) 를 NETWORK 로 옮긴다")
    func authMapsToNetwork() {
        #expect((authFailureOnLiveTask(error: URLError(.cancelled)) as? AuthException)?.error == .network)
    }
}

// ─── AppConfigViewModel ───

private actor FakeConfigRepository: AppConfigRepository {
    private var responses: [Result<AppConfig, Failure>]
    private(set) var calls = 0

    init(_ responses: [Result<AppConfig, Failure>]) {
        self.responses = responses
    }

    func getConfig() async throws -> AppConfig {
        calls += 1
        if responses.isEmpty { throw Failure() }
        return try responses.removeFirst().get()
    }
}

/// 정해 둔 오류를 차례로 던진다 — `URLError(.cancelled)` 처럼 `Failure` 가 아닌 값을 볼 때 쓴다.
private actor ThrowingConfigRepository: AppConfigRepository {
    private var errors: [any Error]
    private let then: AppConfig
    private(set) var calls = 0

    init(errors: [any Error], then: AppConfig) {
        self.errors = errors
        self.then = then
    }

    func getConfig() async throws -> AppConfig {
        calls += 1
        if !errors.isEmpty { throw errors.removeFirst() }
        return then
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    func append(_ value: Duration) { lock.withLock { values.append(value) } }
    var recorded: [Duration] { lock.withLock { values } }
}

@MainActor
@Suite struct AppConfigViewModelTest {
    @Test("서버 값을 받으면 그 값을 따른다")
    func loadsServerConfig() async {
        let repository = FakeConfigRepository([.success(AppConfig(taxiEnabled: true, minVersionCode: 7))])
        let sut = AppConfigViewModel(repository: repository)

        await sut.loading?.value

        #expect(sut.resolved)
        #expect(sut.serverConfig.taxiEnabled)
        #expect(sut.config.minVersionCode == 7)
    }

    @Test("실패하면 2·5·15초 간격으로 다시 시도하고 그래도 안 되면 기본값으로 간다")
    func retriesThenDefault() async {
        let repository = FakeConfigRepository([])
        let recorder = Recorder()
        let sut = AppConfigViewModel(repository: repository, sleep: { recorder.append($0) })

        await sut.loading?.value

        #expect(recorder.recorded == [.seconds(2), .seconds(5), .seconds(15)])
        #expect(await repository.calls == 4)
        #expect(!sut.resolved)
        #expect(sut.config == AppConfig.Default)
    }

    @Test("재시도 중에 성공하면 거기서 멈춘다")
    func stopsOnSuccess() async {
        let repository = FakeConfigRepository([.failure(Failure()), .success(AppConfig(taxiEnabled: true))])
        let recorder = Recorder()
        let sut = AppConfigViewModel(repository: repository, sleep: { recorder.append($0) })

        await sut.loading?.value

        #expect(recorder.recorded == [.seconds(2)])
        #expect(sut.resolved)
    }

    @Test("이미 읽는 중이면 겹쳐 띄우지 않는다")
    func noOverlap() async {
        let repository = FakeConfigRepository([.success(AppConfig(taxiEnabled: false))])
        let sut = AppConfigViewModel(repository: repository)
        sut.load()
        sut.load()

        await sut.loading?.value

        #expect(await repository.calls == 1)
    }

    @Test("복귀 재조회는 못 받았을 때만 한다")
    func loadIfUnresolved() async {
        let repository = FakeConfigRepository([.success(AppConfig(taxiEnabled: false))])
        let sut = AppConfigViewModel(repository: repository)
        await sut.loading?.value

        sut.loadIfUnresolved()
        await sut.loading?.value
        #expect(await repository.calls == 1)

        let failing = FakeConfigRepository([.failure(Failure()), .failure(Failure()), .failure(Failure()), .failure(Failure()), .success(AppConfig(taxiEnabled: true))])
        let retried = AppConfigViewModel(repository: failing, sleep: { _ in })
        await retried.loading?.value
        #expect(!retried.resolved)

        retried.loadIfUnresolved()
        await retried.loading?.value
        #expect(retried.resolved)
    }

    /// 원본 `runCatching` 은 OkHttp `IOException("Canceled")` 도 실패로 받아 다시 시도한다.
    /// 조용히 끝내면 재시도 없이 기본값(동승 모드)에 머문다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 실패라 다시 시도한다")
    func liveUrlCancelRetries() async {
        let repository = ThrowingConfigRepository(errors: [URLError(.cancelled)], then: AppConfig(taxiEnabled: true))
        let recorder = Recorder()
        let sut = AppConfigViewModel(repository: repository, sleep: { recorder.append($0) })

        await sut.loading?.value

        #expect(recorder.recorded == [.seconds(2)])
        #expect(await repository.calls == 2)
        #expect(sut.resolved)
    }

    @Test("태스크가 정말 취소되면 무슨 오류로 끝나든 다시 시도하지 않는다")
    func cancelledTaskDoesNotRetry() async {
        let repository = ThrowingConfigRepository(errors: [URLError(.cancelled)], then: AppConfig(taxiEnabled: true))
        let recorder = Recorder()
        let sut = AppConfigViewModel(repository: repository, sleep: { recorder.append($0) })

        sut.loading?.cancel()
        await sut.loading?.value

        #expect(recorder.recorded.isEmpty)
        #expect(!sut.resolved)
    }

    /// `AppConfig(taxiEnabled:)` 로 새로 만들면 게이트 값이 사라져 업데이트 게이트가 영영 안 걸린다.
    @Test("디버그 강제값은 택시 모드 하나만 뒤집는다")
    func overrideKeepsVersionGate() async {
        let server = AppConfig(taxiEnabled: false, minVersionCode: 9, recommendedVersionCode: 11)
        let sut = AppConfigViewModel(repository: FakeConfigRepository([.success(server)]))
        await sut.loading?.value

        sut.setDebugOverride(taxiEnabled: true)

        #expect(sut.config.taxiEnabled)
        #expect(sut.config.minVersionCode == 9)
        #expect(sut.config.recommendedVersionCode == 11)
        #expect(sut.serverConfig == server, "서버 값 표시는 강제값을 타지 않는다")
        #expect(sut.debugOverride == true)

        sut.setDebugOverride(taxiEnabled: nil)
        #expect(!sut.config.taxiEnabled)
    }
}

// ─── UserProfileViewModel ───

private actor ProfileScript {
    var responses: [Result<UserProfileInfo, Failure>] = []
    var calls = 0
    var hold: CheckedContinuation<Void, Never>?
    var holdNext = false
    var thrown: (any Error)?

    func setThrown(_ error: (any Error)?) { thrown = error }

    func next() async throws -> UserProfileInfo {
        calls += 1
        if let thrown { throw thrown }
        if holdNext {
            holdNext = false
            await withCheckedContinuation { hold = $0 }
            try Task.checkCancellation()
        }
        if responses.isEmpty { throw Failure() }
        return try responses.removeFirst().get()
    }

    func set(_ responses: [Result<UserProfileInfo, Failure>], holdNext: Bool = false) {
        self.responses = responses
        self.holdNext = holdNext
    }

    func release() {
        hold?.resume()
        hold = nil
    }
}

private final class FakeAuthRepository: AuthRepository, @unchecked Sendable {
    let state = MutableStateFlow<AuthState>(.unknown)
    let script = ProfileScript()

    var authState: StateFlow<AuthState> { state }

    func getMyProfile() async throws -> UserProfileInfo { try await script.next() }

    func sendPhoneVerificationCode(phoneNumber: String) async throws { throw Failure() }
    func verifyPhoneCode(phoneNumber: String, code: String) async throws -> String { throw Failure() }
    func register(newUser: NewUser) async throws -> String { throw Failure() }
    func isNicknameTaken(nickname: String) async throws -> Bool { throw Failure() }
    func isPhoneRegistered(phoneNumber: String) async throws -> Bool { throw Failure() }
    func updateProfile(nickname: String?, imageKey: String?) async throws { throw Failure() }
    func getProfileImages() async throws -> [ProfileImage] { throw Failure() }
    func resetProfileImage() async throws { throw Failure() }
    func login(loginId: String, password: String) async throws -> String { throw Failure() }
    func logout() async throws { throw Failure() }
    func deleteAccount(password: String) async throws { throw Failure() }
}

@MainActor
@Suite struct UserProfileViewModelTest {
    private func info(_ name: String?, image: String? = "https://x/1.png") -> UserProfileInfo {
        UserProfileInfo(uuid: "u", name: name, imageUrl: image)
    }

    @Test("로그인하면 이름과 사진을 받아 온다")
    func loadsOnLogin() async {
        let repository = FakeAuthRepository()
        await repository.script.set([.success(info("성윤"))])
        let sut = UserProfileViewModel(repository: repository)
        #expect(sut.userName == .loading)

        repository.state.value = .authenticated(userUuid: "a")

        #expect(await eventually { sut.userName == .resolved(name: "성윤", imageUrl: "https://x/1.png") })
    }

    @Test("조회에 실패해도 조용히 넘어가 폴백 상태가 된다")
    func failureResolvesEmpty() async {
        let repository = FakeAuthRepository()
        let sut = UserProfileViewModel(repository: repository)

        repository.state.value = .authenticated(userUuid: "a")

        #expect(await eventually { sut.userName == .resolved(name: nil, imageUrl: nil) })
    }

    @Test("같은 사용자면 다시 받지 않고 로그아웃하면 비운다")
    func logoutClears() async {
        let repository = FakeAuthRepository()
        await repository.script.set([.success(info("성윤"))])
        let sut = UserProfileViewModel(repository: repository)
        repository.state.value = .authenticated(userUuid: "a")
        #expect(await eventually { sut.userName != .loading })

        repository.state.value = .unauthenticated
        #expect(await eventually { sut.userName == .loading })
        repository.state.value = .unknown
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await repository.script.calls == 1)
    }

    @Test("재조회가 실패해도 띄워 둔 이름을 지우지 않는다")
    func refreshFailureKeepsName() async {
        let repository = FakeAuthRepository()
        await repository.script.set([.success(info("성윤"))])
        let sut = UserProfileViewModel(repository: repository)
        repository.state.value = .authenticated(userUuid: "a")
        #expect(await eventually { sut.userName != .loading })

        sut.refresh()

        #expect(await eventually { await repository.script.calls == 2 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(sut.userName == .resolved(name: "성윤", imageUrl: "https://x/1.png"))
    }

    /// 조건이 `name != nil` 이면 이름 없는 사용자가 재조회 때마다 아바타를 잃는다.
    @Test("재조회가 성공했는데 이름만 없으면 사진은 갱신한다")
    func refreshNamelessUpdatesImage() async {
        let repository = FakeAuthRepository()
        await repository.script.set([.success(info(nil, image: "https://x/1.png")), .success(info(nil, image: "https://x/2.png"))])
        let sut = UserProfileViewModel(repository: repository)
        repository.state.value = .authenticated(userUuid: "a")
        #expect(await eventually { sut.userName == .resolved(name: nil, imageUrl: "https://x/1.png") })

        sut.refresh()

        #expect(await eventually { sut.userName == .resolved(name: nil, imageUrl: "https://x/2.png") })
    }

    @Test("미로그인이면 재조회하지 않는다")
    func refreshNeedsLogin() async {
        let repository = FakeAuthRepository()
        let sut = UserProfileViewModel(repository: repository)

        sut.refresh()

        try? await Task.sleep(for: .milliseconds(30))
        #expect(await repository.script.calls == 0)
    }

    /// 원본 `runCatching` 은 OkHttp `IOException("Canceled")` 도 null 로 받아 폴백 상태로 간다.
    /// 조용히 끝내면 인사말 자리가 `loading` 에서 내려오지 않는다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 로딩에 남지 않고 폴백 상태가 된다")
    func liveUrlCancelResolvesEmpty() async {
        let repository = FakeAuthRepository()
        await repository.script.setThrown(URLError(.cancelled))
        let sut = UserProfileViewModel(repository: repository)

        repository.state.value = .authenticated(userUuid: "a")

        #expect(await eventually { sut.userName == .resolved(name: nil, imageUrl: nil) })
    }

    /// 취소된 요청의 결과가 로그아웃 뒤의 빈 자리를 덮으면 이전 사용자의 이름이 남거나 폴백 문구가 스친다.
    @Test("로그아웃으로 취소된 조회는 아무것도 쓰지 않는다")
    func cancelledLoadWritesNothing() async {
        let repository = FakeAuthRepository()
        await repository.script.set([.success(info("성윤"))], holdNext: true)
        let sut = UserProfileViewModel(repository: repository)
        repository.state.value = .authenticated(userUuid: "a")
        #expect(await eventually { await repository.script.calls == 1 })
        #expect(await eventually { await repository.script.hold != nil })

        repository.state.value = .unauthenticated
        #expect(await eventually { sut.userName == .loading })
        await repository.script.release()

        try? await Task.sleep(for: .milliseconds(30))
        #expect(sut.userName == .loading)
    }
}

// ─── ActivePartyViewModel ───

private actor FakeActivePartyRepository: ActivePartyRepository {
    var resolved: Ride?
    var resolveError: (any Error)?
    private(set) var resolveCalls = 0
    private(set) var remembered: [String] = []
    private(set) var clearCalls = 0

    init(_ resolved: Ride?) {
        self.resolved = resolved
    }

    func setResolved(_ ride: Ride?) { resolved = ride }
    func setResolveError(_ error: (any Error)?) { resolveError = error }

    func remember(partyId: String) async throws { remembered.append(partyId) }

    func clear() async throws { clearCalls += 1 }

    func resolve() async throws -> Ride? {
        resolveCalls += 1
        if let resolveError { throw resolveError }
        return resolved
    }
}

private actor FakeChatRepository: ChatRepository {
    var rooms: [MyChatRoom] = []
    var details: [Int64: ChatRoom] = [:]
    private(set) var listCalls = 0
    private(set) var detailCalls = 0

    func setRooms(_ rooms: [MyChatRoom], details: [Int64: ChatRoom] = [:]) {
        self.rooms = rooms
        self.details = details
    }

    func getMyChatRooms() async throws -> [MyChatRoom] {
        listCalls += 1
        return rooms
    }

    func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom {
        detailCalls += 1
        guard let room = details[chatRoomId] else { throw Failure() }
        return room
    }

    func joinChatRoom(chatRoomId: Int64) async throws { throw Failure() }
    func leaveChatRoom(chatRoomId: Int64) async throws { throw Failure() }
    func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] { throw Failure() }
    func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws { throw Failure() }
    func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws { throw Failure() }
    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage { throw Failure() }
    nonisolated func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> { AsyncStream<ChatRealtimeEvent> { continuation in continuation.finish() } }
    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage { throw Failure() }
    func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage { throw Failure() }
    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws { throw Failure() }
    func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage { throw Failure() }
    func reportMessage(chatRoomId: Int64, chatMessageId: Int64, reason: ChatReportReason, description: String?) async throws { throw Failure() }
}

private func ride(id: String = "7", status: RideStatus = .recruiting, driverId: Int64? = nil) -> Ride {
    Ride(
        id: id, origin: "성결대", destination: "안양역", departureLabel: "지금 출발",
        capacity: 4, members: [], farePerPerson: 2_000, totalFare: 8_000, status: status, driverId: driverId
    )
}

private func chatRoom(id: Int64, partyId: Int64, status: ChatRoomStatus = .active) -> MyChatRoom {
    MyChatRoom(
        room: ChatRoom(id: id, partyId: partyId, departure: "a", destination: "b", createdAt: "", status: status),
        membership: ChatRoomMembership(chatRoomId: id, lastReadMessageId: nil, notificationMuted: false, joinedAt: "")
    )
}

@MainActor
@Suite struct ActivePartyViewModelTest {
    private func make(
        party: FakeActivePartyRepository,
        chat: FakeChatRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(60)) },
        windowMs: Int64 = 500
    ) -> ActivePartyViewModel {
        ActivePartyViewModel(
            activePartyRepository: party,
            chatRepository: chat,
            sleep: sleep,
            resolveGate: ResolveGate(windowMs: windowMs)
        )
    }

    @Test("시작 조회가 방과 채팅방을 함께 찾는다")
    func initResolves() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        await chat.setRooms([chatRoom(id: 3, partyId: 7)])
        let sut = make(party: party, chat: chat)

        #expect(await eventually { sut.chatRoomId == 3 })
        #expect(sut.ride?.id == "7")
        #expect(sut.resolvedOnce)
    }

    @Test("방이 없어도 첫 조회가 끝났다는 사실은 남긴다")
    func resolvedOnceWithoutRide() async {
        let sut = make(party: FakeActivePartyRepository(nil), chat: FakeChatRepository())

        #expect(await eventually { sut.resolvedOnce })
        #expect(sut.ride == nil)
    }

    /// 원본 저장소는 `IOException("Canceled")` 을 「판단 보류」로 받아 null 을 돌려주고 첫 조회가 끝난다.
    /// iOS 저장소는 `URLError(.cancelled)` 를 그대로 던지므로 여기서 같은 결과를 만들어야 한다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 도 첫 조회가 끝난 것으로 치고 방을 비운다")
    func liveUrlCancelFinishesFirstResolve() async {
        let party = FakeActivePartyRepository(ride())
        await party.setResolveError(URLError(.cancelled))
        let sut = make(party: party, chat: FakeChatRepository())

        #expect(await eventually { sut.resolvedOnce })
        #expect(sut.ride == nil)
    }

    /// 목록 응답에는 partyId 가 없어 0 으로 온다 — 닫히지 않은 방만 상세를 읽어 확인한다.
    @Test("목록에 partyId 가 없으면 닫히지 않은 방의 상세를 읽어 찾는다")
    func lookupThroughDetail() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        await chat.setRooms(
            [chatRoom(id: 1, partyId: 0, status: .closed), chatRoom(id: 2, partyId: 0), chatRoom(id: 3, partyId: 0)],
            details: [
                1: chatRoom(id: 1, partyId: 7).room,
                2: chatRoom(id: 2, partyId: 99).room,
                3: chatRoom(id: 3, partyId: 7).room,
            ]
        )
        let sut = make(party: party, chat: chat)

        #expect(await eventually { sut.chatRoomId == 3 })
        #expect(await chat.detailCalls == 2, "닫힌 방의 상세를 읽었다")
    }

    @Test("끝난 방의 채팅방은 찾지 않는다")
    func finishedRideSkipsLookup() async {
        let chat = FakeChatRepository()
        let sut = make(party: FakeActivePartyRepository(ride(status: .completed)), chat: chat)

        #expect(await eventually { sut.resolvedOnce })
        #expect(await chat.listCalls == 0)
    }

    @Test("창 안의 재조회는 흡수된다")
    func refreshDeduplicated() async {
        let party = FakeActivePartyRepository(ride())
        let sut = make(party: party, chat: FakeChatRepository())
        #expect(await eventually { sut.resolvedOnce })

        sut.refresh()
        sut.refresh()

        try? await Task.sleep(for: .milliseconds(30))
        #expect(await party.resolveCalls == 1)
    }

    @Test("합류 직후의 조회는 창을 무시하고 방을 읽는다")
    func rememberReadsImmediately() async {
        let party = FakeActivePartyRepository(nil)
        let sut = make(party: party, chat: FakeChatRepository())
        #expect(await eventually { sut.resolvedOnce })

        await party.setResolved(ride(id: "8"))
        sut.rememberParty(partyId: "8")

        #expect(await eventually { sut.ride?.id == "8" })
        #expect(await party.remembered == ["8"])
        #expect(await party.resolveCalls == 2)
    }

    @Test("이미 든 방이면 상세 없이 채팅방만 찾는다")
    func rememberHeldRoom() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        let sut = make(party: party, chat: chat)
        #expect(await eventually { sut.resolvedOnce })
        #expect(await eventually { await chat.listCalls == 1 })

        await chat.setRooms([chatRoom(id: 3, partyId: 7)])
        sut.rememberParty(partyId: "7")

        #expect(await eventually { sut.chatRoomId == 3 })
        #expect(await party.resolveCalls == 1)
    }

    @Test("숫자가 아니거나 0 이하인 id 는 심지도 읽지도 않는다")
    func rememberRejectsInvalidId() async {
        let party = FakeActivePartyRepository(nil)
        let sut = make(party: party, chat: FakeChatRepository())
        #expect(await eventually { sut.resolvedOnce })

        sut.rememberParty(partyId: "0")
        sut.rememberParty(partyId: "-1")
        sut.rememberParty(partyId: "ride-7")

        try? await Task.sleep(for: .milliseconds(30))
        #expect(await party.remembered.isEmpty)
        #expect(await party.resolveCalls == 1)
    }

    @Test("나가기는 로컬 기억까지 지운다")
    func clearParty() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        await chat.setRooms([chatRoom(id: 3, partyId: 7)])
        let sut = make(party: party, chat: chat)
        #expect(await eventually { sut.chatRoomId == 3 })

        sut.clearParty()

        #expect(await eventually { sut.ride == nil })
        #expect(sut.chatRoomId == nil)
        #expect(await party.clearCalls == 1)
    }

    @Test("로그아웃 초기화는 로컬 기억을 건드리지 않는다")
    func forgetKeepsMemory() async {
        let party = FakeActivePartyRepository(ride())
        let sut = make(party: party, chat: FakeChatRepository())
        #expect(await eventually { sut.resolvedOnce })

        sut.forget()

        #expect(sut.ride == nil)
        #expect(!sut.resolvedOnce)
        #expect(await party.clearCalls == 0)
    }

    // ─── pollChatRoom ───

    /// 원본이 단위 테스트로 못 본다고 적어 둔 부분이다 — 조건이 깨지면 조회가 실제로 멈추는가.
    @Test("가려지면 폴링이 멈추고 돌아오면 다시 돈다")
    func pollStopsWhenHidden() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        let sut = make(party: party, chat: chat, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        #expect(await eventually { sut.resolvedOnce })
        let polling = Task { await sut.pollChatRoom() }
        defer { polling.cancel() }

        #expect(await eventually { await chat.listCalls >= 3 })

        sut.onHostStop()
        try? await Task.sleep(for: .milliseconds(30))
        let whileHidden = await chat.listCalls
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await chat.listCalls == whileHidden, "가려진 동안 서버를 불렀다")

        sut.onHostStart()
        #expect(await eventually { await chat.listCalls > whileHidden })
    }

    @Test("채팅방을 찾으면 멈추고 캐시를 버리면 다시 찾는다")
    func pollStopsWhenFound() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        let sut = make(party: party, chat: chat, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        #expect(await eventually { sut.resolvedOnce })
        let polling = Task { await sut.pollChatRoom() }
        defer { polling.cancel() }

        await chat.setRooms([chatRoom(id: 3, partyId: 7)])
        #expect(await eventually { sut.chatRoomId == 3 })
        try? await Task.sleep(for: .milliseconds(30))
        let afterFound = await chat.listCalls
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await chat.listCalls == afterFound, "찾은 뒤에도 서버를 불렀다")

        sut.forgetChatRoom()
        #expect(await eventually { await chat.listCalls > afterFound })
        #expect(await eventually { sut.chatRoomId == 3 })
    }

    @Test("호출자가 취소되면 폴링이 끝난다")
    func pollEndsOnCancel() async {
        let party = FakeActivePartyRepository(ride())
        let chat = FakeChatRepository()
        let sut = make(party: party, chat: chat, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        #expect(await eventually { sut.resolvedOnce })
        let polling = Task { await sut.pollChatRoom() }
        #expect(await eventually { await chat.listCalls >= 2 })

        polling.cancel()
        await polling.value

        try? await Task.sleep(for: .milliseconds(30))
        let afterCancel = await chat.listCalls
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await chat.listCalls == afterCancel, "취소한 뒤에도 서버를 불렀다")
    }

    /// 방 id 만 흘리는 이유 — status 가 바뀔 때마다 패스가 다시 시작되면 10초 타이머가 초기화된다.
    @Test("방 상태만 바뀌면 10초 타이머를 다시 시작하지 않는다")
    func statusChangeKeepsTimer() async {
        let party = FakeActivePartyRepository(ride())
        let recorder = Recorder()
        let sut = make(
            party: party,
            chat: FakeChatRepository(),
            sleep: { duration in
                recorder.append(duration)
                try await Task.sleep(for: .seconds(60))
            },
            windowMs: 0
        )
        #expect(await eventually { sut.resolvedOnce })
        let polling = Task { await sut.pollChatRoom() }
        defer { polling.cancel() }
        #expect(await eventually { recorder.recorded.count == 1 })
        #expect(recorder.recorded == [.seconds(10)])

        await party.setResolved(ride(status: .matched))
        sut.refresh()
        #expect(await eventually { sut.ride?.status == .matched })

        try? await Task.sleep(for: .milliseconds(30))
        #expect(recorder.recorded.count == 1)
    }

    @Test("단계와 문구는 status 와 기사 유무로 갈린다")
    func stageLabels() {
        #expect(ride(status: .recruiting).activeStage == .waiting)
        #expect(ride(status: .recruiting).activeStageLabel == "같이 탈 사람 찾는 중")
        #expect(ride(status: .matched).activeStage == .waiting)
        #expect(ride(status: .matched).activeStageLabel == "같이 탈 사람이 모였어요")
        #expect(ride(status: .dispatching).activeStage == .driverSearch)
        #expect(ride(status: .dispatching).activeStageLabel == "기사님 찾는 중")
        #expect(ride(status: .dispatching, driverId: 1).activeStage == .driverComing)
        #expect(ride(status: .dispatching, driverId: 1).activeStageLabel == "택시 오는 중")
        #expect(ride(status: .ongoing).activeStage == .ongoing)
        #expect(ride(status: .ongoing).activeStageLabel == "운행 중")
        #expect(ride(status: .completed).activeStage == ActiveStage.none)
        #expect(ride(status: .canceled).activeStageLabel == "진행 중 탑승")
    }
}
