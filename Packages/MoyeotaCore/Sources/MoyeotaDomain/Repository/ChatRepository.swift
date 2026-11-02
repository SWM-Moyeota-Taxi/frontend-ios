/// 조회·상태 변경은 REST, 대화의 실시간 구간(수신·전송·읽음)은 STOMP(WebSocket)다.
/// 소켓이 붙어 있지 않을 때를 위해 같은 일을 하는 REST 경로를 함께 둔다 — `trySendMessage` 가
/// 거짓을 돌려주면 `sendMessage` 로 보낸다.
///
/// 요청 주체는 전부 **Bearer 토큰**이 정한다 — 채팅 컨트롤러도 `@CurrentUser` 로 전환돼
/// 더 이상 userId 를 파라미터로 받지 않는다. 실패는 전부
/// `ChatException` 으로 좁혀 올라온다.
public protocol ChatRepository: Sendable {

    /// GET /api/v1/chat-rooms/me.
    /// 서버는 membership 만 주고 방 이름을 주지 않아, 각 방 상세를 합쳐서 돌려준다(방 수만큼 추가 요청).
    /// 상세 조회에 실패한 방은 목록에서 제외한다 — 종료된 방 때문에 목록 전체가 깨지지 않게 한다.
    func getMyChatRooms() async throws -> [MyChatRoom]

    /// GET /api/v1/chat-rooms/{chatRoomId}
    func getChatRoom(chatRoomId: Int64) async throws -> ChatRoom

    /// POST /api/v1/chat-rooms/{chatRoomId}/users (201). 합류 시 호출.
    func joinChatRoom(chatRoomId: Int64) async throws

    /// DELETE /api/v1/chat-rooms/{chatRoomId}/users. 나 혼자 방에서 나간다(방은 유지).
    func leaveChatRoom(chatRoomId: Int64) async throws

    // GET /api/v1/chat-rooms/{chatRoomId}/users — 방 참여자 목록(나간 사람은 active=false 로 포함).
    // 저장소는 이 목록을 방별로 캐시해 메시지의 발신자 publicId → 닉네임을 푼다("내 메시지" 판정은
    // 메시지 자체의 publicId 로 끝나므로 이 목록이 없어도 정확하다). 화면이 직접 부를 일은 아직
    // 없지만(참여자 N명 표시 등), 판정의 근거를 계약으로 드러내 둔다.
    // 참여자가 아니면 403 CHAT_NOT_PARTICIPANT.
    func getChatRoomMembers(chatRoomId: Int64) async throws -> [ChatMember]

    /// 이 방의 **푸시 알림** 끄기/켜기 — POST(끄기) / DELETE(켜기) `/api/v1/chat-rooms/{chatRoomId}/users/notification/mute` (200).
    /// 서버는 음소거한 참여자에게 새 메시지 푸시(`CHAT_MESSAGE`)를 보내지 않는다. 방 목록의
    /// `ChatRoomMembership.notificationMuted` 로 현재 상태를 읽는다.
    /// 참여자가 아니면 403 CHAT_NOT_PARTICIPANT.
    func setNotificationMuted(chatRoomId: Int64, muted: Bool) async throws

    /// POST /api/v1/chat-rooms/{chatRoomId}/users/read/{readMessageId}. 성공 후 목록의 안읽음 배지 갱신 필요.
    /// 서버는 읽음 위치를 **5초 모았다가 한 번에** 반영한다(Backend #188) — 바로 저장되지 않아도 정상이다.
    /// 내 목록 조회(`GET /chat-rooms/me`) 직전에는 내 것만 먼저 반영하므로 방금 읽은 방이 안 읽음으로 보이진 않는다.
    func markAsRead(chatRoomId: Int64, readMessageId: Int64) async throws

    /// GET /api/v1/chat-rooms/{chatRoomId}/messages — cursor 이전(과거) 방향 페이징.
    /// 최초 진입 시 cursor = null. 이후 응답의 nextCursor 를 넘겨 위로 더 불러온다.
    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessagePage

    /// 이 방의 **실시간 연결**(STOMP `/sub/chat-rooms/{id}`) — 연결됨·새 메시지·끊김 신호.
    ///
    /// 수집하는 동안만 연결되고, 끊기면 알아서 다시 붙는다. 실패는 흐름을 끝내지 않고 재시도로 삼킨다.
    /// 서버는 지난 메시지를 다시 주지 않으므로 호출부는 `ChatRealtimeEvent.connected` 마다 `getMessagesAfter` 로
    /// 공백을 메워야 한다 — 이것만 하면 연결이 살아 있는 동안은 폴링이 필요 없다.
    func observeRoom(chatRoomId: Int64) -> AsyncStream<ChatRealtimeEvent>

    /// GET /api/v1/chat-rooms/{chatRoomId}/messages/after — cursor 이후(신규) 방향.
    /// 소켓이 끊겼거나 재연결 사이에 오간 메시지를 메우는 수단이다(마지막 메시지 id 를 cursor 로 폴링).
    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessagePage

    /// 실시간 연결로 메시지를 보낸다 — STOMP SEND `/pub/chat-rooms/{id}/messages`.
    ///
    /// **응답이 없다.** 서버 핸들러는 void 라 저장 결과가 프레임으로 돌아오지 않고, 저장된 메시지가
    /// `observeRoom` 으로 온다(보낸 사람도 같은 구독을 받는다). 그래서 참을 돌려줘도 "저장됐다"가 아니라
    /// **"살아 있는 연결에 써 넣었다"**는 뜻이다 — 화면은 되돌아온 메시지를 확인으로 삼고, 오지 않으면
    /// 실패로 보여야 한다.
    ///
    /// 연결이 없으면 거짓을 돌려준다. 그때는 `sendMessage` 로 보낸다 — **둘 중 하나만** 써야 한다.
    /// 보낸 뒤 확인이 늦다고 REST 로 다시 보내면 같은 메시지가 두 번 저장된다.
    func trySendMessage(chatRoomId: Int64, content: String) async throws -> Bool

    /// 읽음 지점을 실시간 연결로 알린다 — STOMP SEND `/pub/chat-rooms/{id}/read`.
    /// 새 메시지마다 한 번씩 일어나는 일이라 소켓이 붙어 있으면 REST 왕복을 아낀다.
    /// 연결이 없으면 거짓 — 그때는 `markAsRead` 를 쓴다.
    func tryMarkAsRead(chatRoomId: Int64, readMessageId: Int64) async throws -> Bool

    /// POST /api/v1/chat-rooms/{chatRoomId}/messages (201). 내용은 1~1000자, 빈 문자열이면 400.
    /// 실시간 연결이 없을 때의 경로다 — 연결돼 있으면 `trySendMessage` 가 먼저다.
    ///
    /// 응답은 다른 조회와 같은 메시지 shape 이며 발신자 publicId 가 실려 있으므로
    /// 방금 보낸 메시지부터 `ChatMessage.isMine` 이 참이다(예전의 "내 id 학습" 부수효과는 사라졌다).
    func sendMessage(chatRoomId: Int64, content: String) async throws -> ChatMessage

    /// DELETE /api/v1/chat-rooms/{chatRoomId}/messages/{messageId} (204). 본인 메시지만 가능(403 CHAT_NOT_MESSAGE_OWNER).
    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws

    /// GET /api/v1/chat-rooms/{chatRoomId}/messages/search — 방 안 키워드 검색.
    /// keyword 는 **2자 이상**이어야 한다(미만이면 400 CHAT_INVALID_KEYWORD).
    /// 아직 화면이 없다 — 채팅방 검색 UI 가 붙을 때 쓰기 위해 계약만 열어 둔다.
    func searchMessages(chatRoomId: Int64, keyword: String, cursor: Int64?, size: Int) async throws -> ChatMessagePage

    /// POST /api/v1/chat-rooms/{chatRoomId}/reports (201, 본문 없음) — **메시지 1건**을 신고한다.
    ///
    /// 긴급 신고(`RideRepository.reportEmergency`)와 **다른 것**이다: 그쪽은 「파티 + 내 좌표」를 신고하고
    /// 사유 필드가 없으며 112 통화로 이어진다. 이쪽은 특정 메시지와 그 글을 쓴 사람을 가리키고
    /// 후속 통화가 없다. 그래서 신고 대상을 고를 수 없는 자리(상단바 메뉴·동승자 프로필)에는
    /// 붙일 수 없다 — `chatMessageId` 가 서버에서 필수다.
    ///
    /// - `description` 은 `ChatReportReason.etc` 에서만 필수이며, **공백만 있어도 서버가 거절한다**.
    ///   호출부가 비어 있는 값을 null 로 접어 보내므로 구현체는 빈 문자열을 그대로 싣지 않는다.
    /// - `ChatReportReason.MAX_DESCRIPTION_LENGTH`자를 넘기면 400 이다.
    /// - **종료된 방에서도 받는다** — 채팅방 참여 여부만 보고 파티 상태를 보지 않는다.
    ///
    /// 실패는 `ChatException` 으로 온다. 화면이 분기해야
    /// 하는 것은 `isAlreadyReported`
    /// (재시도해도 같은 답이다) ·
    /// `isMessageNotFound` ·
    /// `isNotParticipant` 다.
    func reportMessage(
        chatRoomId: Int64,
        chatMessageId: Int64,
        reason: ChatReportReason,
        description: String?
    ) async throws
}

/// Kotlin `ChatRepository.Companion` 의 자리. Swift 프로토콜은 메타타입에서 정적 멤버를 꺼낼 수 없어
/// (`ChatRepository.DEFAULT_PAGE_SIZE` 가 안 된다) 값을 여기 둔다. 구현 타입에서는 `Self.DEFAULT_PAGE_SIZE` 로도 읽는다.
public enum ChatRepositoryDefaults {
    public static let DEFAULT_PAGE_SIZE = 30
}

// Kotlin 인터페이스의 기본 인자·기본 구현 자리.
extension ChatRepository {
    public static var DEFAULT_PAGE_SIZE: Int { ChatRepositoryDefaults.DEFAULT_PAGE_SIZE }

    public func getMessages(chatRoomId: Int64, cursor: Int64? = nil) async throws -> ChatMessagePage {
        try await getMessages(chatRoomId: chatRoomId, cursor: cursor, size: ChatRepositoryDefaults.DEFAULT_PAGE_SIZE)
    }

    public func getMessages(chatRoomId: Int64, size: Int) async throws -> ChatMessagePage {
        try await getMessages(chatRoomId: chatRoomId, cursor: nil, size: size)
    }

    public func getMessagesAfter(chatRoomId: Int64, cursor: Int64) async throws -> ChatMessagePage {
        try await getMessagesAfter(chatRoomId: chatRoomId, cursor: cursor, size: ChatRepositoryDefaults.DEFAULT_PAGE_SIZE)
    }

    public func trySendMessage(chatRoomId: Int64, content: String) async throws -> Bool { false }

    public func tryMarkAsRead(chatRoomId: Int64, readMessageId: Int64) async throws -> Bool { false }

    public func searchMessages(
        chatRoomId: Int64,
        keyword: String,
        cursor: Int64? = nil
    ) async throws -> ChatMessagePage {
        try await searchMessages(
            chatRoomId: chatRoomId,
            keyword: keyword,
            cursor: cursor,
            size: ChatRepositoryDefaults.DEFAULT_PAGE_SIZE
        )
    }

    public func searchMessages(chatRoomId: Int64, keyword: String, size: Int) async throws -> ChatMessagePage {
        try await searchMessages(chatRoomId: chatRoomId, keyword: keyword, cursor: nil, size: size)
    }

    public func reportMessage(chatRoomId: Int64, chatMessageId: Int64, reason: ChatReportReason) async throws {
        try await reportMessage(chatRoomId: chatRoomId, chatMessageId: chatMessageId, reason: reason, description: nil)
    }
}
