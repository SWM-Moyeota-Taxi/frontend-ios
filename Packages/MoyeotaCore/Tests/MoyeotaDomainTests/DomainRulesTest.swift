import Foundation
import Testing
@testable import MoyeotaDomain

/// 모델에 붙은 판정과 Kotlin 인터페이스 기본값(프로토콜 확장으로 옮긴 자리)이 원본과 같은지 본다.
@Suite struct DomainRulesTest {
    private func user(isMe: Bool = false, isHost: Bool = false) -> User {
        User(id: "u", nickname: "n", verifiedLabel: "", rating: 0, rideCount: 0, isMe: isMe, isHost: isHost)
    }

    private func ride(members: [User]) -> Ride {
        Ride(
            id: "1", origin: "a", destination: "b", departureLabel: "지금 출발", capacity: 3,
            members: members, farePerPerson: 0, totalFare: 0, status: .recruiting
        )
    }

    @Test("내가 방장인가는 내 멤버 한 명의 isHost 만 본다")
    func isHostedByMe() {
        #expect(ride(members: [user(isMe: true, isHost: true)]).isHostedByMe)
        #expect(!ride(members: [user(isHost: true), user(isMe: true)]).isHostedByMe)
        #expect(!ride(members: [user(isHost: true)]).isHostedByMe)
        #expect(!ride(members: []).isHostedByMe)
    }

    @Test("안읽음은 서버 개수가 유일한 근거이고, 없을 때만 어림한다")
    func hasUnread() {
        func membership(lastRead: Int64?, last: ChatLastMessage?, unread: Int?) -> ChatRoomMembership {
            ChatRoomMembership(chatRoomId: 1, lastReadMessageId: lastRead, notificationMuted: false, joinedAt: "", lastMessage: last, unreadCount: unread)
        }
        func last(id: Int64, mine: Bool) -> ChatLastMessage {
            ChatLastMessage(id: id, senderPublicId: nil, content: "", type: .text, createdAt: "", isMine: mine)
        }
        #expect(!membership(lastRead: 1, last: last(id: 5, mine: false), unread: 0).hasUnread)
        #expect(membership(lastRead: 9, last: last(id: 5, mine: true), unread: 2).hasUnread)
        #expect(!membership(lastRead: nil, last: nil, unread: nil).hasUnread)
        #expect(!membership(lastRead: nil, last: last(id: 5, mine: true), unread: nil).hasUnread)
        #expect(membership(lastRead: nil, last: last(id: 5, mine: false), unread: nil).hasUnread)
        #expect(membership(lastRead: 4, last: last(id: 5, mine: false), unread: nil).hasUnread)
        #expect(!membership(lastRead: 5, last: last(id: 5, mine: false), unread: nil).hasUnread)
    }

    @Test("합류 예외는 내 방·다른 방을 가른다")
    func partyJoinException() {
        let code = PartyJoinException.ALREADY_JOINED_OTHER_PARTY
        let mine = PartyStatus(status: .recruiting, currentMembers: 2)
        #expect(PartyJoinException(code: code, serverMessage: nil, joinedStatus: mine).isAlreadyInThisParty)
        #expect(!PartyJoinException(code: code, serverMessage: nil, joinedStatus: mine).isAlreadyInAnotherParty)
        #expect(PartyJoinException(code: code, serverMessage: nil).isAlreadyInAnotherParty)
        #expect(PartyJoinException(code: "ALREADY_JOINED_PARTY", serverMessage: nil).isAlreadyJoined)
        #expect(!PartyJoinException(code: "ALREADY_JOINED_PARTY", serverMessage: nil).isAlreadyInAnotherParty)
        #expect(PartyJoinException(code: nil, serverMessage: nil, httpStatus: 404).isPartyNotFound)
        #expect(!PartyJoinException(code: "X", serverMessage: nil, httpStatus: 404).isPartyNotFound)
    }

    @Test("완료 예외는 상태 코드로 폴백하지 않는다")
    func partyFinishException() {
        #expect(!PartyFinishException(code: nil, serverMessage: nil, httpStatus: 403).isNotHost)
        #expect(!PartyFinishException(code: nil, serverMessage: nil, httpStatus: 404).isPartyNotFound)
        #expect(PartyFinishException(code: "NOT_PARTY_HOST", serverMessage: nil).isNotHost)
    }

    @Test("생성 예외의 경로 실패 갈래")
    func partyOpenException() {
        #expect(PartyOpenException(code: "ROUTE_NOT_FOUND", serverMessage: nil).isRouteUnavailable)
        #expect(PartyOpenException(code: nil, serverMessage: nil, httpStatus: 502).isRouteUnavailable)
        #expect(!PartyOpenException(code: nil, serverMessage: nil, httpStatus: 400).isRouteUnavailable)
        #expect(PartyOpenException(code: "ALREADY_JOINED_PARTY", serverMessage: nil).isAlreadyInAnotherParty)
    }

    @Test("채팅 예외 플래그")
    func chatException() {
        #expect(ChatException(code: nil, serverMessage: nil, httpStatus: 403).isNotParticipant)
        #expect(!ChatException(code: "X", serverMessage: nil, httpStatus: 403).isNotParticipant)
        #expect(ChatException(code: "X", serverMessage: nil, httpStatus: 401).isUnauthorized)
        #expect(!ChatException(code: "CHAT_MESSAGE_NOT_FOUND", serverMessage: nil, httpStatus: 404).isRoomNotFound)
        #expect(ChatException(code: "CHAT_MESSAGE_NOT_FOUND", serverMessage: nil, httpStatus: 404).isMessageNotFound)
    }

    @Test("예외 메시지는 서버 원문 → 코드 → 기본 문구 순이다")
    func messages() {
        #expect(PartyJoinException(code: "C", serverMessage: "서버").message == "서버")
        #expect(PartyJoinException(code: "C", serverMessage: nil).message == "C")
        #expect(PartyJoinException(code: nil, serverMessage: nil).message == "방에 합류하지 못했습니다.")
        #expect(PartyFinishException(code: nil, serverMessage: nil).message == "합승을 완료하지 못했습니다.")
        #expect(RealtimeMatchException(code: nil, serverMessage: nil).message == "추천을 가져오지 못했습니다.")
        #expect(PartyOpenException(code: nil, serverMessage: nil).message == "방을 만들지 못했습니다.")
        #expect(PartyLeaveException(code: nil, serverMessage: nil).message == "방에서 나가지 못했습니다.")
        #expect(ChatException(code: nil, serverMessage: nil).message == "채팅 요청에 실패했습니다.")
        #expect(FavoritePlaceException(code: nil, serverMessage: nil).message == "즐겨찾기 요청에 실패했습니다.")
        #expect(AuthException(error: .smsCooldown).message == "SMS_COOLDOWN")
        #expect(AuthException(error: .smsCooldown, serverMessage: "서버").localizedDescription == "서버")
        #expect(PartyMembershipLostException(partyId: 7).message == "이 방의 참여자가 아닙니다. (partyId=7)")
        #expect(PartyMembershipLostException().message == "이 방의 참여자가 아닙니다. (partyId=null)")
    }

    @Test("서버로 나가는 enum 이름은 원본 상수 그대로다")
    func enumNames() {
        #expect(Gender.undisclosed.name == "UNDISCLOSED")
        #expect(ChatReportReason.etc.name == "ETC")
        #expect(ChatRoomStatus(rawValue: "ARCHIVED") == .archived)
        #expect(ChatReportReason.etc.requiresDescription)
        #expect(!ChatReportReason.abuse.requiresDescription)
        #expect(ChatReportReason.MIN_MESSAGE_ID == 1)
        #expect(AppConfig.Default == AppConfig(taxiEnabled: false, minVersionCode: nil, recommendedVersionCode: nil))
    }

    @Test("UserSession 의 기본 구현은 authState 를 읽는다")
    func userSession() {
        struct Session: UserSession {
            let flow: MutableStateFlow<AuthState>
            var authState: StateFlow<AuthState> { flow }
        }
        let flow = MutableStateFlow<AuthState>(.unknown)
        let session = Session(flow: flow)
        #expect(session.currentUserUuid == nil)
        #expect(!session.isLoggedIn)
        flow.value = .authenticated(userUuid: "uuid")
        #expect(session.currentUserUuid == "uuid")
        #expect(session.isLoggedIn)
        flow.value = .unauthenticated
        #expect(session.currentUserUuid == nil)
    }

    /// 프로토콜 요구 사항만 구현하면 Kotlin 기본 인자로 부른 호출이 같은 곳으로 모인다.
    private actor FakeRecords: RideRecordRepository {
        var calls: [String] = []

        func getMyRecords(cursor: Int64?, size: Int) async throws -> RideRecordPage {
            calls.append("\(cursor.map { String($0) } ?? "nil"):\(size)")
            return RideRecordPage(records: [], nextCursor: nil, hasNext: false)
        }
    }

    @Test("탑승 기록의 기본 인자")
    func recordDefaults() async throws {
        let repository = FakeRecords()
        _ = try await repository.getMyRecords()
        _ = try await repository.getMyRecords(cursor: 9)
        _ = try await repository.getMyRecords(size: 5)
        _ = try await repository.getMyRecords(cursor: 9, size: 5)
        #expect(await repository.calls == ["nil:20", "9:20", "nil:5", "9:5"])
        #expect(RideRecordRepositoryDefaults.DEFAULT_PAGE_SIZE == 20)
        #expect(FakeRecords.DEFAULT_PAGE_SIZE == 20)
    }

    private actor FakeChat: ChatRepository {
        var calls: [String] = []

        func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
            calls.append("messages:\(cursor.map { String($0) } ?? "nil"):\(size)")
            return ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        }

        func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage {
            calls.append("after:\(cursor):\(size)")
            return ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        }

        func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
            calls.append("search:\(keyword):\(cursor.map { String($0) } ?? "nil"):\(size)")
            return ChatMessagePage(messages: [], nextCursor: nil, hasNext: false)
        }

        func reportMessage(chatRoomId: Int64, chatMessageId: Int64, reason: ChatReportReason, description: String?) async throws {
            calls.append("report:\(reason.name):\(description ?? "nil")")
        }

        // 이 테스트가 부르지 않는 요구 사항들.
        struct Unused: Error {}
        func getMyChatRooms() async throws -> [MyChatRoom] { throw Unused() }
        func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom { throw Unused() }
        func joinChatRoom(chatRoomId: Int64) async throws { throw Unused() }
        func leaveChatRoom(chatRoomId: Int64) async throws { throw Unused() }
        func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] { throw Unused() }
        func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws { throw Unused() }
        func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws { throw Unused() }
        nonisolated func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> { AsyncStream { $0.finish() } }
        func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage { throw Unused() }
        func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws { throw Unused() }
    }

    @Test("채팅의 기본 인자와 기본 구현")
    func chatDefaults() async throws {
        let repository = FakeChat()
        _ = try await repository.getMessages(chatRoomId: 1)
        _ = try await repository.getMessages(chatRoomId: 1, cursor: 2)
        _ = try await repository.getMessages(chatRoomId: 1, size: 3)
        _ = try await repository.getMessagesAfter(chatRoomId: 1, cursor: 4)
        _ = try await repository.searchMessages(chatRoomId: 1, keyword: "키워드")
        _ = try await repository.searchMessages(chatRoomId: 1, keyword: "키워드", cursor: 5)
        _ = try await repository.searchMessages(chatRoomId: 1, keyword: "키워드", size: 6)
        try await repository.reportMessage(chatRoomId: 1, chatMessageId: 2, reason: .spam)
        #expect(await repository.calls == [
            "messages:nil:30", "messages:2:30", "messages:nil:3", "after:4:30",
            "search:키워드:nil:30", "search:키워드:5:30", "search:키워드:nil:6", "report:SPAM:nil",
        ])
        // 소켓이 없는 구현(더미·테스트 저장소)은 거짓 — REST 로 넘어간다.
        #expect(try await repository.trySendMessage(chatRoomId: 1, content: "x") == false)
        #expect(try await repository.tryMarkAsRead(chatRoomId: 1, readMessageId: 2) == false)
        #expect(ChatRepositoryDefaults.DEFAULT_PAGE_SIZE == 30)
    }
}
