import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 이 저장소가 지켜야 하는 건 "찾았다/못 찾았다" 두 값이 아니라 **세 값**이다 —
/// 진행 중이다 / 확실히 아니다(기억 삭제) / 모르겠다(기억 보존).
/// 세 번째를 두 번째로 접는 순간 오프라인에서 앱을 켠 사용자의 복귀 경로가 영구히 사라지므로,
/// 아래 테스트의 절반은 "기억이 남아 있는가"를 본다.
@Suite struct RemoteActivePartyRepositoryTest {

    @Test("기억된 방이 진행 중이면 상세 1회로 돌려준다")
    func rememberedActive() async throws {
        let rides = FakeRideRepository(details: [10: ride(id: 10, status: .recruiting)])
        let chats = FakeChatRepository()
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))

        let resolved = try await repository(rides, chats, storage).resolve()

        #expect(resolved?.id == "10")
        #expect(rides.detailCalls.value == [10])
        #expect(chats.myRoomsCalls.value == 0, "기억이 맞았는데 채팅방 목록까지 불렀다")
    }

    /// 정원이 막 찬 방(서버 COMPLETED → 도메인 MATCHED)도 진행 중이다. 여기서 놓치면 매칭 순간을 잃는다.
    @Test("정원 충족 상태 MATCHED 도 진행 중으로 본다")
    func matchedIsActive() async throws {
        let rides = FakeRideRepository(details: [10: ride(id: 10, status: .matched)])
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))

        let resolved = try await repository(rides, FakeChatRepository(), storage).resolve()

        #expect(resolved != nil)
    }

    @Test("기억된 방이 끝났으면 기억을 지우고 null 을 돌려준다")
    func rememberedFinished() async throws {
        let rides = FakeRideRepository(details: [10: ride(id: 10, status: .completed)])
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))

        let resolved = try await repository(rides, FakeChatRepository(), storage).resolve()

        #expect(resolved == nil)
        #expect(try await storage.load() == nil, "끝난 방의 기억이 남았다")
    }

    @Test("방이 사라졌으면(404) 기억을 지운다")
    func rememberedGone() async throws {
        let rides = FakeRideRepository(errors: [10: Self.httpError(404)])
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))

        let resolved = try await repository(rides, FakeChatRepository(), storage).resolve()

        #expect(resolved == nil)
        #expect(try await storage.load() == nil)
    }

    @Test("내가 멤버가 아닌 방이면 기억을 지운다")
    func notAMember() async throws {
        let notMine = ride(id: 10, status: .ongoing, memberUuid: "someone-else")
        let rides = FakeRideRepository(details: [10: notMine])
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))

        let resolved = try await repository(rides, FakeChatRepository(), storage).resolve()

        #expect(resolved == nil)
        #expect(try await storage.load() == nil)
    }

    @Test("기억이 없으면 채팅방의 partyId 로 찾아 기억한다")
    func fallsBackToChatRooms() async throws {
        let rides = FakeRideRepository(
            details: [
                7: ride(id: 7, status: .completed),
                8: ride(id: 8, status: .ongoing),
            ]
        )
        let chats = FakeChatRepository(
            rooms: [myChatRoom(roomId: 1, partyId: 7), myChatRoom(roomId: 2, partyId: 8)]
        )
        let storage = FakeActivePartyStorage(nil)

        let resolved = try await repository(rides, chats, storage).resolve()

        #expect(resolved?.id == "8")
        #expect(try await storage.load() == RememberedParty(partyId: "8", ownerUuid: Self.MY_UUID))
    }

    /// 채팅방이 아무리 많아도 요청은 5개까지. 최신(= id 가 큰) 방부터 본다.
    @Test("채팅방 탐색은 최신순 5개까지만 상세를 부른다")
    func scanLimit() async throws {
        let rides = FakeRideRepository(details: [:])
        let chats = FakeChatRepository(
            rooms: (Int64(1)...8).map { myChatRoom(roomId: $0, partyId: $0 * 10) }
        )

        let resolved = try await repository(rides, chats, FakeActivePartyStorage(nil)).resolve()

        #expect(resolved == nil)
        #expect(rides.detailCalls.value == [80, 70, 60, 50, 40])
    }

    /// 로그아웃 → 다른 계정 로그인. 앞 사람의 방으로 끌고 가면 사고다.
    /// 기억은 버리되, 새 계정의 방은 채팅방 목록에서 정상적으로 찾아야 한다.
    @Test("계정이 바뀌면 이전 계정의 기억을 무시하고 지운다")
    func accountChanged() async throws {
        let rides = FakeRideRepository(details: [99: ride(id: 99, status: .ongoing)])
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "99", ownerUuid: "previous-user-uuid"))

        let resolved = try await repository(rides, FakeChatRepository(), storage).resolve()

        #expect(resolved == nil)
        #expect(try await storage.load() == nil, "남의 계정 기억이 남았다")
        #expect(rides.detailCalls.value.isEmpty, "남의 계정 방을 조회했다")
    }

    @Test("네트워크 실패는 예외를 던지지 않고 null 이며 기억을 남긴다")
    func networkFailureKeepsMemory() async throws {
        let rides = FakeRideRepository(errors: [10: IOException("timeout")])
        let chats = FakeChatRepository()
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))

        let resolved = try await repository(rides, chats, storage).resolve()

        #expect(resolved == nil)
        #expect(
            try await storage.load() == RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID),
            "신호가 없다고 복귀 경로를 지웠다"
        )
        #expect(chats.myRoomsCalls.value == 0, "판정 불가인데 채팅방까지 훑었다")
    }

    @Test("채팅방 목록 조회가 실패해도 null 로 접는다")
    func chatRoomListFailure() async throws {
        let chats = FakeChatRepository(failing: true)

        let resolved = try await repository(FakeRideRepository(), chats, FakeActivePartyStorage(nil)).resolve()

        #expect(resolved == nil)
    }

    /// QA 119 D-3. 「합승 완료」·방 종료 직후 `GET /api/v1/matching/rooms/0` 404 가 나던 자리다.
    /// 서버 partyId 는 1 부터 올라가는 PK 라 0·음수·비숫자는 **네트워크를 타기 전에** 아니라고 답해야 한다
    /// — 읽어 봐야 404 이고, 그 404 는 서버 에러 로그만 더럽힌다.
    @Test("유효하지 않은 기억은 조회하지 않고 지운다")
    func garbageMemory() async throws {
        for garbage in ["0", "-1", "", " ", "null"] {
            let rides = FakeRideRepository()
            let chats = FakeChatRepository()
            let storage = FakeActivePartyStorage(RememberedParty(partyId: garbage, ownerUuid: Self.MY_UUID))

            let resolved = try await repository(rides, chats, storage).resolve()

            #expect(resolved == nil)
            #expect(rides.detailCalls.value.isEmpty, "[\(garbage)] 없는 방 번호로 상세를 읽었다: \(rides.detailCalls.value)")
            #expect(try await storage.load() == nil, "[\(garbage)] 쓰레기 기억이 남았다")
        }
    }

    /// 채팅방 목록 응답(백엔드 `ChatRoomUserResult`)에는 partyId 가 없어 매퍼가 0 으로 채운다.
    /// 그 0 을 그대로 조회하면 방마다 404 한 번씩이다 — 후보에서 아예 빼야 한다.
    @Test("목록이 partyId 를 주면 채팅방 상세를 읽지 않는다")
    func listedPartyIdSkipsRoomDetail() async throws {
        let rides = FakeRideRepository(details: [8: ride(id: 8, status: .ongoing)])
        let chats = FakeChatRepository(rooms: [myChatRoom(roomId: 1, partyId: 8)])

        let resolved = try await repository(rides, chats, FakeActivePartyStorage(nil)).resolve()

        #expect(resolved?.id == "8")
        #expect(rides.detailCalls.value == [8])
        #expect(chats.roomDetailCalls.value.isEmpty, "필요 없는 채팅방 상세를 읽었다")
    }

    /// **이 테스트가 이 수정의 본체다.**
    ///
    /// 지금 서버의 목록 응답(`ChatRoomUserResult`)에는 partyId 가 없어 매퍼가 0 으로 채운다. 예전에는
    /// 그 0 을 후보에서 빼 버려 **폴백이 항상 빈손**이었다 — 앱을 지우고 다시 깔면 진행 중인 방으로
    /// 돌아갈 길이 없었다(30분 만료까지). 이제 채팅방 상세(`ChatRoomResult.partyId`)로 건져 온다.
    @Test("목록에 partyId 가 없으면 채팅방 상세로 건져 온다")
    func resolvesPartyIdFromRoomDetail() async throws {
        let rides = FakeRideRepository(details: [8: ride(id: 8, status: .ongoing)])
        let chats = FakeChatRepository(
            rooms: [myChatRoom(roomId: 2, partyId: 0)],
            partyIdsByRoom: [2: 8]
        )

        let resolved = try await repository(rides, chats, FakeActivePartyStorage(nil)).resolve()

        #expect(resolved?.id == "8")
        #expect(chats.roomDetailCalls.value == [2])
        #expect(rides.detailCalls.value == [8])
    }

    /// 상세까지 읽었는데도 0 이면 더 볼 것이 없다 — **절대 `GET /matching/rooms/0` 을 쏘지 않는다**(QA 119 D-3).
    @Test("상세에도 partyId 가 없으면 방 상세를 읽지 않는다")
    func noPartyIdAnywhere() async throws {
        let rides = FakeRideRepository()
        let chats = FakeChatRepository(
            rooms: (Int64(1)...3).map { myChatRoom(roomId: $0, partyId: 0) },
            partyIdsByRoom: [:]
        )

        let resolved = try await repository(rides, chats, FakeActivePartyStorage(nil)).resolve()

        #expect(resolved == nil)
        #expect(rides.detailCalls.value.isEmpty, "없는 방 번호로 상세를 읽었다: \(rides.detailCalls.value)")
    }

    /// 채팅방 상세가 실패해도 다음 후보로 넘어간다 — 한 방의 네트워크 실패가 복구 경로 전체를 막으면 안 된다.
    @Test("채팅방 상세가 실패해도 다른 후보를 계속 본다")
    func roomDetailFailureContinues() async throws {
        let rides = FakeRideRepository(details: [8: ride(id: 8, status: .ongoing)])
        let chats = FakeChatRepository(
            rooms: [myChatRoom(roomId: 2, partyId: 0), myChatRoom(roomId: 1, partyId: 0)],
            partyIdsByRoom: [1: 8],
            detailFailingRooms: [2]
        )

        let resolved = try await repository(rides, chats, FakeActivePartyStorage(nil)).resolve()

        #expect(resolved?.id == "8")
    }

    /// 추가 요청이 무한정 늘지 않는다 — 채팅방 상세도 스캔 한도 안에서만 나간다.
    @Test("채팅방 상세도 스캔 한도까지만 읽는다")
    func roomDetailScanLimit() async throws {
        let rides = FakeRideRepository()
        let chats = FakeChatRepository(rooms: (Int64(1)...8).map { myChatRoom(roomId: $0, partyId: 0) })

        _ = try await repository(rides, chats, FakeActivePartyStorage(nil)).resolve()

        #expect(chats.roomDetailCalls.value.count <= 5, "상세를 \(chats.roomDetailCalls.value.count) 번 읽었다")
    }

    /// 쓰레기 id 는 저장도 하지 않는다 — 심어 두면 다음 resolve 가 404 한 번 맞고 지우는 것이 전부다.
    @Test("유효하지 않은 id 는 기억에 심지 않는다")
    func garbageIdNotRemembered() async throws {
        let storage = FakeActivePartyStorage(nil)
        let repository = repository(FakeRideRepository(), FakeChatRepository(), storage)

        for garbage in ["0", "-3", "", "abc"] {
            try await repository.remember(partyId: garbage)
            #expect(try await storage.load() == nil, "[\(garbage)] 조회할 수 없는 id 를 심었다")
        }

        try await repository.remember(partyId: "42")
        #expect(try await storage.load() == RememberedParty(partyId: "42", ownerUuid: Self.MY_UUID))
    }

    @Test("미로그인 상태에서는 기억을 건드리지 않고 null")
    func loggedOutLeavesMemory() async throws {
        let storage = FakeActivePartyStorage(RememberedParty(partyId: "10", ownerUuid: Self.MY_UUID))
        let repository = RemoteActivePartyRepository(
            rideRepository: FakeRideRepository(),
            chatRepository: FakeChatRepository(),
            storage: storage,
            session: FakeSession(uuid: nil)
        )

        #expect(try await repository.resolve() == nil)
        #expect(try await storage.load() != nil, "미로그인은 판정 불가일 뿐인데 기억을 지웠다")

        // 미로그인 상태의 remember 는 주인을 적을 수 없어 저장 자체를 하지 않는다.
        try await repository.clear()
        try await repository.remember(partyId: "42")
        #expect(try await storage.load() == nil)
    }

    private func repository(
        _ rides: any RideRepository,
        _ chats: any ChatRepository,
        _ storage: any ActivePartyStorage
    ) -> RemoteActivePartyRepository {
        RemoteActivePartyRepository(
            rideRepository: rides,
            chatRepository: chats,
            storage: storage,
            session: FakeSession(uuid: Self.MY_UUID)
        )
    }

    private static let MY_UUID = "my-uuid"

    private func ride(id: Int64, status: RideStatus, memberUuid: String = Self.MY_UUID) -> Ride {
        Ride(
            id: String(id),
            origin: "성결대",
            destination: "안양역",
            departureLabel: "지금 출발",
            capacity: 4,
            members: [
                User(
                    id: memberUuid,
                    nickname: "나",
                    verifiedLabel: "",
                    rating: 0.0,
                    rideCount: 0,
                    isMe: memberUuid == Self.MY_UUID
                ),
            ],
            farePerPerson: 2000,
            totalFare: 8000,
            status: status
        )
    }

    private func myChatRoom(roomId: Int64, partyId: Int64) -> MyChatRoom {
        MyChatRoom(
            room: ChatRoom(
                id: roomId,
                partyId: partyId,
                departure: "성결대",
                destination: "안양역",
                createdAt: "2026-09-09T00:00:00Z",
                status: .active
            ),
            membership: ChatRoomMembership(
                chatRoomId: roomId,
                lastReadMessageId: nil,
                notificationMuted: false,
                joinedAt: "2026-09-09T00:00:00Z"
            )
        )
    }

    fileprivate static func httpError(_ code: Int) -> HttpException {
        HttpException(Response<Void>.error(code, "{}"))
    }
}

private struct FakeSession: UserSession {
    let authState: StateFlow<AuthState>

    init(uuid: String?) {
        authState = MutableStateFlow<AuthState>(uuid.map { .authenticated(userUuid: $0) } ?? .unauthenticated)
    }
}

private final class FakeActivePartyStorage: ActivePartyStorage {
    private let stored: Locked<RememberedParty?>

    init(_ remembered: RememberedParty?) {
        stored = Locked(remembered)
    }

    func load() async throws -> RememberedParty? { stored.value }
    func save(party: RememberedParty) async throws { stored.value = party }
    func clear() async throws { stored.value = nil }
}

private final class FakeRideRepository: RideRepository {
    private let details: [Int64: Ride]
    private let errors: [Int64: any Error]
    let detailCalls = Locked<[Int64]>([])

    init(details: [Int64: Ride] = [:], errors: [Int64: any Error] = [:]) {
        self.details = details
        self.errors = errors
    }

    func getPartyDetail(partyId: Int64) async throws -> Ride {
        detailCalls.append(partyId)
        if let error = errors[partyId] { throw error }
        guard let ride = details[partyId] else {
            throw RemoteActivePartyRepositoryTest.httpError(404)
        }
        return ride
    }

    // 이 테스트는 순번을 보지 않는다 — 상세 경로가 같다는 것만 유지하고 version 은 null 로 둔다.
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail {
        PartyDetail(ride: try await getPartyDetail(partyId: partyId), version: nil)
    }

    // 이 테스트는 추천을 보지 않는다 — 빈 목록이 "후보 없음"이라 가장 정직한 기본값이다.
    func findRealtimeCandidates(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> [MatchCandidate] { [] }

    func getNearbyParties() -> [Ride] { [] }
    func getParties() async throws -> [Ride] { [] }
    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] { [] }
    func createParty(request: NewParty) async throws -> Ride { throw IllegalStateException("쓰이지 않는다") }
    func joinParty(partyId: Int64) async throws -> PartyStatus { throw IllegalStateException("쓰이지 않는다") }
    func leaveParty(partyId: Int64) async throws { throw IllegalStateException("쓰이지 않는다") }
    func finishParty(partyId: Int64) async throws { throw IllegalStateException("쓰이지 않는다") }
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw IllegalStateException("쓰이지 않는다") }
    func reportEmergency(partyId: Int64?) async throws -> Int64 { throw IllegalStateException("쓰이지 않는다") }
    func confirmEmergencyCall(called: Bool) async throws { throw IllegalStateException("쓰이지 않는다") }
    func previewRoute(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> RouteEstimate { throw IllegalStateException("쓰이지 않는다") }
}

private final class FakeChatRepository: ChatRepository {
    private let rooms: [MyChatRoom]
    private let failing: Bool
    /// 채팅방 상세가 돌려줄 partyId. 목록에 없는 값을 여기서 건져 온다(서버 `ChatRoomResult.partyId`).
    private let partyIdsByRoom: [Int64: Int64]
    /// 이 채팅방들의 상세 조회는 네트워크 실패로 떨어뜨린다.
    private let detailFailingRooms: Set<Int64>

    let myRoomsCalls = Locked(0)

    /// 상세를 읽은 채팅방 id — 추가 요청이 예산 안에서만 나가는지 고정한다.
    let roomDetailCalls = Locked<[Int64]>([])

    init(
        rooms: [MyChatRoom] = [],
        failing: Bool = false,
        partyIdsByRoom: [Int64: Int64] = [:],
        detailFailingRooms: Set<Int64> = []
    ) {
        self.rooms = rooms
        self.failing = failing
        self.partyIdsByRoom = partyIdsByRoom
        self.detailFailingRooms = detailFailingRooms
    }

    func getMyChatRooms() async throws -> [MyChatRoom] {
        myRoomsCalls.update { $0 += 1 }
        if failing { throw IOException("offline") }
        return rooms
    }

    func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> { AsyncStream { $0.finish() } }

    func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom {
        roomDetailCalls.append(chatRoomId)
        if detailFailingRooms.contains(chatRoomId) { throw IOException("offline") }
        guard var found = rooms.first(where: { $0.room.id == chatRoomId })?.room else {
            throw IllegalStateException("없는 채팅방 \(chatRoomId)")
        }
        found.partyId = partyIdsByRoom[chatRoomId] ?? 0
        return found
    }

    func joinChatRoom(chatRoomId: Int64) async throws { throw IllegalStateException("쓰이지 않는다") }
    func leaveChatRoom(chatRoomId: Int64) async throws { throw IllegalStateException("쓰이지 않는다") }
    func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws { throw IllegalStateException("쓰이지 않는다") }
    func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] { throw IllegalStateException("쓰이지 않는다") }
    func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws { throw IllegalStateException("쓰이지 않는다") }
    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        throw IllegalStateException("쓰이지 않는다")
    }
    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage {
        throw IllegalStateException("쓰이지 않는다")
    }
    func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage { throw IllegalStateException("쓰이지 않는다") }
    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws { throw IllegalStateException("쓰이지 않는다") }
    func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        throw IllegalStateException("쓰이지 않는다")
    }
    func reportMessage(
        chatRoomId: Int64,
        chatMessageId: Int64,
        reason: ChatReportReason,
        description: String?
    ) async throws { throw IllegalStateException("쓰이지 않는다") }
}
