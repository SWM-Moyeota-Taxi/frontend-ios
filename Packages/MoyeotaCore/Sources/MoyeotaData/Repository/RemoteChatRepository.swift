import MoyeotaDomain
import os

// 이 저장소의 두 번째 책임은 조회가 아니라 **"보낸 사람이 누구인가"의 번역**이다.
//
// 서버 ChatMessageResult 는 발신자를 공개 UUID(publicId)로 밝힌다 — 세션 uuid 와 같은 체계라
// "내 메시지인가"는 문자열 비교 한 번으로 끝난다(매퍼가 한다). 남는 일은 이름뿐이다:
// 메시지에 닉네임이 없어 GET /chat-rooms/{id}/users 를 publicId → 닉네임 사전으로 캐시한다.
//
// 예전에는 서버가 발신자를 내부 PK(userId)로만 표시해, 앱이 "내가 보낸 메시지의 응답에 담긴 userId"를
// **학습**해 내 메시지를 가렸다. 서버가 userId 를 응답에서 빼고 publicId 를 실어 주면서(2026-09-09 실측)
// 그 학습 전략은 근거가 사라져 통째로 삭제됐다 — 42·46 문서의 "학습 폴백" 설명은 폐기다.
//
// 캐시 전략:
// - 방 진입(getMessages 의 cursor == null)에 참여자 목록을 받아 방별로 캐시한다.
//   실패해도 메시지 로드는 그대로 진행한다 — 이름이 덜 보일 뿐, 대화는 열려야 하고
//   **내 말풍선 위치는 사전과 무관하게 정확하다**.
// - 사전에 없는 발신자가 나오면(중간 합류자) 그 로드에서 **한 번만** 재조회한다.
// - 재조회해도 못 찾은 publicId 는 unresolved 에 적어 두고 다시 부르지 않는다(폴링마다 재조회 방지).
//
// 계정 경계: 참여자 캐시는 "그때 그 계정"의 것이다. 캐시를 만든 uuid 를 함께 들고 있다가 현재 세션
// uuid 와 다르면(로그아웃 → null, 재로그인 → 다른 값) 통째로 버린다.
public final class RemoteChatRepository: ChatRepository {
    private let api: any ChatApi
    private let session: any UserSession
    /// 실시간 수신 통로. 미주입(테스트·더미 구동)이면 빈 흐름이라 **폴링만으로 동작한다** —
    /// 소켓은 있으면 빠르고 없으면 느릴 뿐, 없다고 채팅이 멈추지 않는다.
    private let socket: ChatSocket?

    // 방 id → 그 방의 참여자 사전. 캐시가 어느 계정의 것인지는 cacheOwnerUuid 가 들고 있다.
    private struct MemberCache: Sendable {
        var memberCache: [Int64: RoomMembers] = [:]
        var cacheOwnerUuid: String?
    }

    private let cache = OSAllocatedUnfairLock(initialState: MemberCache())

    public init(api: any ChatApi, session: any UserSession, socket: ChatSocket? = nil) {
        self.api = api
        self.session = session
        self.socket = socket
    }

    /// 목록 한 번으로 끝낸다 — 응답에 방 정보(출발·도착·상태)와 참여자가 함께 온다(서버 2026-09-14).
    ///
    /// 그 전에는 방마다 `GET /chat-rooms/{id}`(이름) + `/users`(참여자)를 더 불러 **요청이 1+2N 회**였고,
    /// 게다가 방 상세는 순차로 돌아 방 3개에 5초 가까이 걸렸다(실측). 지금은 1회다.
    /// 필드를 주지 않는 구버전 서버에서는 예전처럼 방별 상세를 채워 넣는다 — 서버 배포 순서와 무관하게 동작한다.
    public func getMyChatRooms() async throws -> [MyChatRoom] {
        try await chatCall {
            // 마지막 메시지의 isMine 판정용. 목록 조회 시점의 세션 하나로 전 방을 매핑한다.
            let myUuid = session.currentUserUuid
            let memberships = try await api.getMyRooms()
            // 동시에 돌리되 결과는 서버가 준 순서대로 모은다(원본 `awaitAll` 이 입력 순서를 지킨다).
            let rooms = try await withThrowingTaskGroup(of: (Int, MyChatRoom?).self) { group in
                for (index, membership) in memberships.enumerated() {
                    group.addTask { [self] in
                        (index, try await toMyChatRoom(membership, myUuid: myUuid))
                    }
                }
                var collected = [MyChatRoom?](repeating: nil, count: memberships.count)
                for try await (index, room) in group {
                    collected[index] = room
                }
                return collected.compactMap { $0 }
            }
            // 원본 `coroutineScope` 는 취소된 채 끝나면 결과 대신 취소를 던진다.
            try Task.checkCancellation()
            return rooms
        }
    }

    /// 목록 항목 하나 → 화면이 쓰는 모델. 방 정보가 함께 왔으면 그대로 쓰고, 없으면 방 상세를 한 번 더 읽는다.
    /// 상세 조회에 실패한 방은 null 로 떨어뜨린다 — 종료된 방 하나 때문에 목록 전체가 깨지지 않게.
    /// 취소는 실패가 아니라 그대로 올린다.
    private func toMyChatRoom(_ response: ChatRoomUserResponse, myUuid: String?) async throws -> MyChatRoom? {
        let membership = response.toMembership(myUuid: myUuid)
        // 참여자가 함께 왔으면 사전에 채워 둔다 — 방을 열 때 /users 를 다시 부르지 않아도 이름이 보인다
        if let members = response.members {
            cacheMembers(chatRoomId: response.chatRoomId, members: members, myUuid: myUuid)
        }
        if let listed = response.toChatRoomOrNull() {
            return MyChatRoom(room: listed, membership: membership)
        }
        do {
            let room = try await api.getRoom(chatRoomId: response.chatRoomId).toChatRoom()
            return MyChatRoom(room: room, membership: membership)
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            return nil
        }
    }

    // 소켓이 밀어 준 프레임도 조회와 **같은 경로로 신원을 푼다** — 모르는 발신자가 오면 참여자 사전을
    // 한 번 새로 읽는다(중간 합류자). 그래야 실시간으로 온 메시지도 이름과 좌우 정렬이 맞는다.
    public func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent> {
        guard let socket else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let task = Task { [self] in
                // 신호를 받은 순서대로 하나씩 푼다. 푸는 동안 던지는 건 취소뿐이라 흐름을 닫기만 하면 된다.
                do {
                    for await signal in socket.room(chatRoomId: chatRoomId) {
                        continuation.yield(try await toRealtimeEvent(signal, chatRoomId: chatRoomId))
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func toRealtimeEvent(_ signal: ChatSocket.RoomSignal, chatRoomId: Int64) async throws -> ChatRealtimeEvent {
        switch signal {
        case .connected:
            return .connected
        case .disconnected:
            return .disconnected
        case .message(let response):
            let identity = try await resolveIdentity(chatRoomId: chatRoomId, messages: [response], priorRefresh: nil)
            return .message(message: response.toChatMessage(identity: identity))
        }
    }

    public func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom {
        try await chatCall {
            try await api.getRoom(chatRoomId: chatRoomId).toChatRoom()
        }
    }

    public func joinChatRoom(chatRoomId: Int64) async throws {
        try await chatCall { try await api.joinRoom(chatRoomId: chatRoomId) }
    }

    public func leaveChatRoom(chatRoomId: Int64) async throws {
        try await chatCall { try await api.leaveRoom(chatRoomId: chatRoomId) }
    }

    public func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws {
        try await chatCall {
            if muted {
                try await api.muteNotification(chatRoomId: chatRoomId)
            } else {
                try await api.unmuteNotification(chatRoomId: chatRoomId)
            }
        }
    }

    // 목록은 그대로 돌려주되 캐시도 함께 채운다 — 호출자가 참여자를 보려고 부른 김에
    // 다음 메시지 매핑도 정확해진다. userId 가 없는 참여자는 캐시에 넣을 수 없지만(이을 키가 없다)
    // 반환 목록에는 그대로 포함한다.
    public func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember] {
        try await chatCall {
            try await fetchMembers(chatRoomId: chatRoomId)
        }
    }

    public func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws {
        try await chatCall {
            try await api.readRoom(chatRoomId: chatRoomId, readMessageId: readMessageId)
        }
    }

    // 방 진입(cursor == null)에만 참여자 목록을 먼저 받는다. 위로 더 불러오는 페이징에서는
    // 사전에 없는 발신자가 실제로 나왔을 때만 재조회한다.
    public func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage {
        try await chatCall {
            let refreshed: Bool? = cursor == nil ? try await refreshMembersQuietly(chatRoomId: chatRoomId) : nil
            let slice = try await api.getMessages(chatRoomId: chatRoomId, cursor: cursor, size: size)
            return slice.toPage(
                identity: try await resolveIdentity(chatRoomId: chatRoomId, messages: slice.messages, priorRefresh: refreshed)
            )
        }
    }

    public func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage {
        try await chatCall {
            let slice = try await api.getMessagesAfter(chatRoomId: chatRoomId, cursor: cursor, size: size)
            return slice.toPage(
                identity: try await resolveIdentity(chatRoomId: chatRoomId, messages: slice.messages, priorRefresh: nil)
            )
        }
    }

    // 소켓이 이 방에 붙어 있을 때만 참. 저장 결과는 응답이 아니라 observeRoom 으로 돌아온다.
    public func trySendMessage(chatRoomId: Int64, content: String) async throws -> Bool {
        await socket?.sendMessage(chatRoomId: chatRoomId, content: content) ?? false
    }

    public func tryMarkAsRead(chatRoomId: Int64, readMessageId: Int64) async throws -> Bool {
        await socket?.markAsRead(chatRoomId: chatRoomId, readMessageId: readMessageId) ?? false
    }

    // 전송 응답도 조회와 같은 shape 이라 발신자 publicId 가 들어 있다 — 방금 보낸 메시지가
    // 그 자리에서 바로 내 것으로 판정된다(화면이 전송 결과를 그대로 목록에 붙이기 때문에 중요하다).
    public func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage {
        try await chatCall {
            let sent = try await api.sendMessage(chatRoomId: chatRoomId, request: SendMessageRequestDto(content: content))
            return sent.toChatMessage(
                identity: try await resolveIdentity(chatRoomId: chatRoomId, messages: [sent], priorRefresh: nil)
            )
        }
    }

    public func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws {
        try await chatCall {
            try await api.deleteMessage(chatRoomId: chatRoomId, messageId: messageId)
        }
    }

    /// 신고는 참여자 사전과 **아무 상관이 없다** — 서버가 신고자를 토큰에서, 피신고자를 메시지에서
    /// 각각 찾는다. 그래서 다른 호출처럼 `resolveIdentity` 를 끼우지 않는다.
    ///
    /// 사유는 enum 직렬화에 맡기지 않고 `ChatReportReason.name` 을 명시적으로 넣는다 — 서버가
    /// 소문자를 400 으로 거절하므로(실측) 대문자 보장을 이 한 줄에 모아 둔다.
    public func reportMessage(
        chatRoomId: Int64,
        chatMessageId: Int64,
        reason: ChatReportReason,
        description: String?
    ) async throws {
        try await chatCall {
            try await api.reportMessage(
                chatRoomId: chatRoomId,
                request: ChatReportRequestDto(
                    chatMessageId: chatMessageId,
                    reason: reason.name,
                    // 빈 문자열·공백은 **없는 것과 같게 접는다.** 서버가 ETC 에서 isBlank 를 400 으로
                    // 거절하므로(실측) 공백을 그대로 실어 보내면 「썼는데 거절당했다」가 된다.
                    description: description?.takeIfNotBlank()
                )
            )
        }
    }

    public func searchMessages(
        chatRoomId: Int64,
        keyword: String,
        cursor: Int64?,
        size: Int
    ) async throws -> ChatMessagePage {
        try await chatCall {
            let slice = try await api.searchMessages(chatRoomId: chatRoomId, keyword: keyword, cursor: cursor, size: size)
            return slice.toPage(
                identity: try await resolveIdentity(chatRoomId: chatRoomId, messages: slice.messages, priorRefresh: nil)
            )
        }
    }

    // MARK: - 참여자 사전(publicId → 닉네임)

    // 이 응답에 사전이 모르는 발신자가 있으면 한 번 재조회하고, 그래도 못 찾으면 다시 묻지 않게 적어 둔다.
    // 사전은 이름을 위한 것이므로, 여기서 실패해도 isMine 판정은 흔들리지 않는다.
    //
    // priorRefresh: 이 호출에서 이미 참여자 목록을 불렀다면 그 성공 여부(같은 로드에서 두 번 부르지 않는다).
    //   null 이면 아직 부르지 않았다는 뜻.
    private func resolveIdentity(
        chatRoomId: Int64,
        messages: [ChatMessageResponse],
        priorRefresh: Bool?
    ) async throws -> ChatIdentity {
        var current = identity(chatRoomId: chatRoomId)
        let missing = missingSenderPublicIds(chatRoomId: chatRoomId, messages: messages, identity: current)
        if missing.isEmpty { return current }

        let refreshed: Bool
        if let priorRefresh {
            refreshed = priorRefresh
        } else {
            refreshed = try await refreshMembersQuietly(chatRoomId: chatRoomId)
            current = identity(chatRoomId: chatRoomId)
        }
        // 조회 자체가 실패했다면 "없는 사람"으로 단정하지 않는다 — 다음 로드에서 다시 시도한다.
        if refreshed {
            let known = current.members
            markUnresolved(chatRoomId: chatRoomId, ids: missing.filter { known[$0] == nil })
        }
        return current
    }

    private func missingSenderPublicIds(
        chatRoomId: Int64,
        messages: [ChatMessageResponse],
        identity: ChatIdentity
    ) -> [String] {
        let unresolved = roomMembers(chatRoomId: chatRoomId).unresolved
        var seen = Set<String>()
        return messages
            .compactMap { $0.senderPublicId?.takeIfNotBlank() ?? $0.publicId?.takeIfNotBlank() }
            .filter { identity.members[$0] == nil && !unresolved.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    // 실패를 삼킨다 — 참여자 목록은 표시를 좋게 할 뿐, 이것 때문에 채팅방이 안 열리면 안 된다.
    // 취소만은 통과시킨다(화면 이탈을 "조회 실패"로 기록하지 않기 위해).
    private func refreshMembersQuietly(chatRoomId: Int64) async throws -> Bool {
        do {
            _ = try await fetchMembers(chatRoomId: chatRoomId)
            return true
        } catch where isCancellation(throwable: error) {
            throw error
        } catch {
            return false
        }
    }

    /// 목록 응답에 실려 온 참여자를 사전에 채운다 — 방을 열 때 /users 를 다시 부르지 않아도 이름이 보인다
    private func cacheMembers(chatRoomId: Int64, members: [ChatMemberResponse], myUuid: String?) {
        storeMembers(chatRoomId: chatRoomId, members: members.map { $0.toChatMember(myUuid: myUuid) })
    }

    private func fetchMembers(chatRoomId: Int64) async throws -> [ChatMember] {
        let myUuid = session.currentUserUuid
        let members = try await api.getMembers(chatRoomId: chatRoomId).map { $0.toChatMember(myUuid: myUuid) }
        storeMembers(chatRoomId: chatRoomId, members: members)
        return members
    }

    private func identity(chatRoomId: Int64) -> ChatIdentity {
        ChatIdentity(myUuid: session.currentUserUuid, members: roomMembers(chatRoomId: chatRoomId).byPublicId)
    }

    // 읽는 시점에 계정을 확인해 남의 캐시를 버린다(authState 구독보다 어긋날 여지가 적다).
    private func roomMembers(chatRoomId: Int64) -> RoomMembers {
        let uuid = session.currentUserUuid
        return cache.withLock { cache in
            if uuid == nil || uuid != cache.cacheOwnerUuid {
                cache.memberCache.removeAll()
                return RoomMembers.EMPTY
            }
            return cache.memberCache[chatRoomId] ?? RoomMembers.EMPTY
        }
    }

    private func storeMembers(chatRoomId: Int64, members: [ChatMember]) {
        guard let uuid = session.currentUserUuid else { return }
        // publicId 가 빈 참여자는 메시지와 이을 키가 없어 사전에 들어가지 못한다(응답이 깨진 경우).
        let byPublicId = Dictionary(
            members.filter { !$0.publicId.isBlank }.map { ($0.publicId, $0) },
            uniquingKeysWith: { _, last in last }
        )
        cache.withLock { cache in
            Self.claimCache(&cache, uuid: uuid)
            let stillUnknown = (cache.memberCache[chatRoomId]?.unresolved ?? []).subtracting(byPublicId.keys)
            cache.memberCache[chatRoomId] = RoomMembers(byPublicId: byPublicId, unresolved: stillUnknown)
        }
    }

    private func markUnresolved(chatRoomId: Int64, ids: [String]) {
        if ids.isEmpty { return }
        guard let uuid = session.currentUserUuid else { return }
        cache.withLock { cache in
            Self.claimCache(&cache, uuid: uuid)
            var updated = cache.memberCache[chatRoomId] ?? RoomMembers.EMPTY
            updated.unresolved.formUnion(ids)
            cache.memberCache[chatRoomId] = updated
        }
    }

    private static func claimCache(_ cache: inout MemberCache, uuid: String) {
        if uuid != cache.cacheOwnerUuid {
            cache.memberCache.removeAll()
            cache.cacheOwnerUuid = uuid
        }
    }

    // byPublicId: publicId → 참여자. unresolved: 재조회로도 못 찾은 발신자 publicId(무한 재조회 방지).
    private struct RoomMembers: Sendable {
        var byPublicId: [String: ChatMember]
        var unresolved: Set<String>

        static let EMPTY = RoomMembers(byPublicId: [:], unresolved: [])
    }
}
