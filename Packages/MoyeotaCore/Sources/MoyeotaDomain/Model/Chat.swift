// 백엔드 chat 도메인 enum 과 1:1. 알 수 없는 값은 매퍼에서 ACTIVE/TEXT 로 방어한다.
public enum ChatRoomStatus: String, CaseIterable, Sendable {
    case active = "ACTIVE"
    case closed = "CLOSED"
    case archived = "ARCHIVED"

    /// Kotlin `enum.name` — 원본 상수 이름 그대로.
    public var name: String { rawValue }
}

public enum ChatMessageType: String, CaseIterable, Sendable {
    case text = "TEXT"
    case location = "LOCATION"

    /// Kotlin `enum.name` — 원본 상수 이름 그대로.
    public var name: String { rawValue }
}

// 채팅방. createdAt 은 서버가 ISO-8601(Instant) 문자열로 내려주며 도메인에서는 문자열로 보관한다.
// (domain 모듈은 시각 변환을 두지 않는다 — 표시 포맷은 presentation 책임)
public struct ChatRoom: Hashable, Sendable {
    public var id: Int64
    public var partyId: Int64
    public var departure: String
    public var destination: String
    public var createdAt: String
    public var status: ChatRoomStatus

    public init(
        id: Int64,
        partyId: Int64,
        departure: String,
        destination: String,
        createdAt: String,
        status: ChatRoomStatus
    ) {
        self.id = id
        self.partyId = partyId
        self.departure = departure
        self.destination = destination
        self.createdAt = createdAt
        self.status = status
    }
}

/// 방의 **마지막 메시지** 요약(백엔드 `ChatRoomUserResult.LastMessage`, 2026-09-11 추가).
/// 목록의 미리보기·정렬·안읽음 판정에 쓴다. 삭제된 메시지는 서버가 content 를 「삭제된 메시지입니다」로 바꿔 준다.
///
/// - `senderPublicId`: 보낸 사람 공개 UUID. 탈퇴 등으로 서버가 못 찾으면 null
/// - `isMine`: 내가 보낸 메시지인지(senderPublicId == 세션 uuid). 내 메시지가 마지막이면 안읽음이 아니다
public struct ChatLastMessage: Hashable, Sendable {
    public var id: Int64
    public var senderPublicId: String?
    public var content: String
    public var type: ChatMessageType
    public var createdAt: String
    public var isMine: Bool

    public init(
        id: Int64,
        senderPublicId: String?,
        content: String,
        type: ChatMessageType,
        createdAt: String,
        isMine: Bool
    ) {
        self.id = id
        self.senderPublicId = senderPublicId
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

// 내가 그 방에 대해 갖는 상태(마지막 읽은 메시지 등). 백엔드 ChatRoomUserResult 대응.
public struct ChatRoomMembership: Hashable, Sendable {
    public var chatRoomId: Int64
    public var lastReadMessageId: Int64?
    public var notificationMuted: Bool
    public var joinedAt: String
    /// 방의 마지막 메시지. 아직 아무 메시지도 없으면 null (구버전 서버 응답도 null 로 떨어진다)
    public var lastMessage: ChatLastMessage?
    /// 안 읽은 메시지 **개수**(서버 `unreadCount`, 2026-09-12 추가) — 남이 보낸 · 삭제 안 된 · 읽음 커서 뒤의 메시지 수.
    /// 필드를 안 주는 구버전 서버면 null 이고, 그때는 `hasUnread` 가 마지막 메시지로 유무만 가린다.
    public var unreadCount: Int?
    /// 방 참여자(서버 2026-09-14 부터 목록 응답에 함께 온다). 안 오는 구버전 서버면 빈 목록이고,
    /// 그때는 화면이 방마다 `GET /chat-rooms/{id}/users` 를 따로 불러 제목을 짓는다.
    public var members: [ChatMember]

    public init(
        chatRoomId: Int64,
        lastReadMessageId: Int64?,
        notificationMuted: Bool,
        joinedAt: String,
        lastMessage: ChatLastMessage? = nil,
        unreadCount: Int? = nil,
        members: [ChatMember] = []
    ) {
        self.chatRoomId = chatRoomId
        self.lastReadMessageId = lastReadMessageId
        self.notificationMuted = notificationMuted
        self.joinedAt = joinedAt
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.members = members
    }

    /// 안 읽은 메시지가 있는가. 서버가 개수를 주면 그 값이 **유일한 근거**다(0 이면 없음).
    /// 개수가 없는(구버전) 응답에서만 「마지막 메시지가 남의 것이고 읽음 커서가 그 앞」으로 어림한다.
    public var hasUnread: Bool {
        if let unreadCount { return unreadCount > 0 }
        guard let last = lastMessage else { return false }
        if last.isMine { return false }
        guard let cursor = lastReadMessageId else { return true }
        return cursor < last.id
    }
}

// GET /chat-rooms/me 는 membership(+마지막 메시지)만 주고 방 이름(출발지/목적지)을 주지 않는다.
// 채팅 목록 화면이 한 번에 그릴 수 있도록 Repository 에서 방 상세를 합쳐 내려준다.
public struct MyChatRoom: Hashable, Sendable {
    public var room: ChatRoom
    public var membership: ChatRoomMembership

    public init(room: ChatRoom, membership: ChatRoomMembership) {
        self.room = room
        self.membership = membership
    }
}

// 방 참여자 1명(백엔드 ChatRoomMemberResult). 메시지의 발신자 publicId 를 닉네임/프로필로 잇는 사전이다.
//
// `userId` 는 항상 null 이다 — 서버가 내부 PK 를 응답에서 뺐다(2026-09-09 실측). 필드를 남긴 건
// 구버전 서버 응답을 파싱 에러 없이 받기 위해서이며, 앱은 이 값으로 아무것도 판정하지 않는다.
// active=false 는 방을 나간 사람이다 — 목록에서 빼지 않는다. 남긴 메시지의 이름이 사라지면
// 대화가 "동승자"로 뭉개진다.
public struct ChatMember: Hashable, Sendable {
    /// 서버 내부 PK. 현행 서버는 주지 않아 항상 null 이다(구버전 호환 잔여 필드).
    public var userId: Int64?
    public var publicId: String
    public var nickname: String
    public var imageUrl: String?
    public var active: Bool
    public var isMe: Bool

    public init(
        userId: Int64?,
        publicId: String,
        nickname: String,
        imageUrl: String?,
        active: Bool,
        isMe: Bool
    ) {
        self.userId = userId
        self.publicId = publicId
        self.nickname = nickname
        self.imageUrl = imageUrl
        self.active = active
        self.isMe = isMe
    }
}

public struct ChatMessage: Hashable, Sendable {
    public var id: Int64
    public var chatRoomId: Int64
    /// 보낸 사람의 **공개 UUID**(서버 `publicId`, JWT `sub` 와 같은 값).
    /// 파티 멤버의 `User.id` 와 같은 체계라 프로필로 이을 수 있다.
    ///
    /// 서버가 신원을 빠뜨린 응답이면 null 이고, 그때는 `isMine` 이 false, `senderName` 이 null 이다.
    public var senderPublicId: String?
    public var content: String
    public var type: ChatMessageType
    public var createdAt: String
    public var deleted: Bool
    /// 내가 보낸 메시지인지. `senderPublicId == UserSession.currentUserUuid` 하나로 판정한다
    /// — 서버가 메시지에 발신자 publicId 를 실어 주면서 예전의 3단 근거(사전·학습)가 필요 없어졌다.
    public var isMine: Bool
    /// 보낸 사람 닉네임. 방 참여자 목록(GET /chat-rooms/{id}/users)을 publicId 로 찾은 값이 우선이고,
    /// 서버가 `senderNickname` 을 실어 주면 그걸 폴백으로 쓴다. 둘 다 없으면 null.
    public var senderName: String?

    public init(
        id: Int64,
        chatRoomId: Int64,
        senderPublicId: String?,
        content: String,
        type: ChatMessageType,
        createdAt: String,
        deleted: Bool,
        isMine: Bool,
        senderName: String?
    ) {
        self.id = id
        self.chatRoomId = chatRoomId
        self.senderPublicId = senderPublicId
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.deleted = deleted
        self.isMine = isMine
        self.senderName = senderName
    }
}

// 커서 페이징 결과. nextCursor 가 null 이거나 hasNext=false 면 더 불러올 것이 없다.
public struct ChatMessagePage: Hashable, Sendable {
    public var messages: [ChatMessage]
    public var nextCursor: Int64?
    public var hasNext: Bool

    public init(messages: [ChatMessage], nextCursor: Int64?, hasNext: Bool) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.hasNext = hasNext
    }
}

/// 채팅방 실시간 연결(STOMP `/sub/chat-rooms/{id}`)에서 오는 신호.
///
/// 서버 브로커는 **지금 구독 중인 사람에게만** 밀고 지난 메시지를 다시 주지 않는다. 그래서 끊겼다 다시 붙으면
/// 그 사이 메시지가 빠진다 — `connected` 를 받을 때마다 마지막 id 이후를 한 번 조회해 메워야 한다.
public enum ChatRealtimeEvent: Hashable, Sendable {
    /// 구독이 (다시) 걸렸다. 이 시점 이후 메시지는 `message` 로 오고, 그 전의 공백은 조회로 메운다
    case connected

    /// 새 메시지(보낸 사람 자신에게도 온다 — 소켓 전송의 확인이 이것이다)
    case message(message: ChatMessage)

    /// 연결이 끊겼다. 곧 다시 붙는다 — 그동안은 폴링이 메운다
    case disconnected
}
