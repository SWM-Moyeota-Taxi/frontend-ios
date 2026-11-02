// 백엔드 chat/app/dto/*.java, chat/presentation/dto/*.java (origin/develop) 와 필드 1:1
// enum(status/type)은 문자열로 받고 매퍼에서 도메인 enum 으로 방어적으로 변환한다.

// GET /api/v1/chat-rooms/{id} → ChatRoomResult
public struct ChatRoomResponse: Decodable, Equatable, Sendable {
    public var id: Int64
    public var partyId: Int64
    public var departure: String
    public var destination: String
    public var createdAt: String?
    public var status: String

    public init(
        id: Int64,
        partyId: Int64 = 0,
        departure: String = "",
        destination: String = "",
        createdAt: String? = nil,
        status: String = ""
    ) {
        self.id = id
        self.partyId = partyId
        self.departure = departure
        self.destination = destination
        self.createdAt = createdAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, partyId, departure, destination, createdAt, status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        partyId = try c.decodeOrDefault(.partyId, default: 0)
        departure = try c.decodeOrDefault(.departure, default: "")
        destination = try c.decodeOrDefault(.destination, default: "")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        status = try c.decodeOrDefault(.status, default: "")
    }
}

// GET /api/v1/chat-rooms/me → List<ChatRoomUserResult>
// 방 이름 정보가 없다는 점에 주의(방마다 상세를 따로 조회해야 한다).
// lastMessage 는 2026-09-11 서버 커밋(963c340)부터 실린다 — 그 전 서버는 필드가 없어 null.
public struct ChatRoomUserResponse: Decodable, Equatable, Sendable {
    public var chatRoomId: Int64
    public var lastReadMessageId: Int64?
    public var notificationMuted: Bool
    public var joinedAt: String?
    public var lastMessage: ChatLastMessageResponse?
    // 2026-09-12 서버(7c95683)부터. 필드가 없는 구서버는 null 로 두어 앱이 「개수 모름」으로 다룬다.
    public var unreadCount: Int64?
    // 2026-09-14 서버(69e991e·c0cbe7a)부터 방 정보와 참여자가 목록에 함께 온다.
    // 이 셋이 채워지면 앱은 방마다 GET /chat-rooms/{id} · /users 를 더 부르지 않는다(요청 1+2N → 1).
    // 아직 배포 전인 서버는 전부 null 이라 예전 경로(방별 추가 조회)로 떨어진다.
    public var departure: String?
    public var destination: String?
    public var status: String?
    public var members: [ChatMemberResponse]?

    public init(
        chatRoomId: Int64,
        lastReadMessageId: Int64? = nil,
        notificationMuted: Bool = false,
        joinedAt: String? = nil,
        lastMessage: ChatLastMessageResponse? = nil,
        unreadCount: Int64? = nil,
        departure: String? = nil,
        destination: String? = nil,
        status: String? = nil,
        members: [ChatMemberResponse]? = nil
    ) {
        self.chatRoomId = chatRoomId
        self.lastReadMessageId = lastReadMessageId
        self.notificationMuted = notificationMuted
        self.joinedAt = joinedAt
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.departure = departure
        self.destination = destination
        self.status = status
        self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case chatRoomId, lastReadMessageId, notificationMuted, joinedAt, lastMessage, unreadCount
        case departure, destination, status, members
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatRoomId = try c.decode(Int64.self, forKey: .chatRoomId)
        lastReadMessageId = try c.decodeIfPresent(Int64.self, forKey: .lastReadMessageId)
        notificationMuted = try c.decodeOrDefault(.notificationMuted, default: false)
        joinedAt = try c.decodeIfPresent(String.self, forKey: .joinedAt)
        lastMessage = try c.decodeIfPresent(ChatLastMessageResponse.self, forKey: .lastMessage)
        unreadCount = try c.decodeIfPresent(Int64.self, forKey: .unreadCount)
        departure = try c.decodeIfPresent(String.self, forKey: .departure)
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        members = try c.decodeIfPresent([ChatMemberResponse].self, forKey: .members)
    }
}

// ChatRoomUserResult.LastMessage — 방의 마지막 메시지 요약. 삭제된 메시지는 서버가 content 를 치환해 준다.
// senderPublicId 는 발신자를 못 찾으면(탈퇴) null.
public struct ChatLastMessageResponse: Decodable, Equatable, Sendable {
    public var id: Int64
    public var senderPublicId: String?
    public var content: String
    public var type: String
    public var createdAt: String?

    public init(
        id: Int64,
        senderPublicId: String? = nil,
        content: String = "",
        type: String = "",
        createdAt: String? = nil
    ) {
        self.id = id
        self.senderPublicId = senderPublicId
        self.content = content
        self.type = type
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, senderPublicId, content, type, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        senderPublicId = try c.decodeIfPresent(String.self, forKey: .senderPublicId)
        content = try c.decodeOrDefault(.content, default: "")
        type = try c.decodeOrDefault(.type, default: "")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

// POST /api/v1/chat-rooms/{id}/messages 요청 본문 (SendMessageRequest)
public struct SendMessageRequestDto: Codable, Equatable, Sendable {
    public var content: String

    public init(content: String) {
        self.content = content
    }
}

// 메시지 1건 (ChatMessageResult). 삭제된 메시지는 서버가 content 를 "삭제된 메시지입니다" 로 치환해 내려준다.
//
// 배포 서버 실측(2026-09-09, GET /chat-rooms/1/messages · POST .../messages):
//   {"id","chatRoomId","publicId","content","type","createdAt","deleted"}
// 즉 **userId 는 더 이상 오지 않고 publicId(발신자 공개 UUID)가 그 자리를 대신한다.**
public struct ChatMessageResponse: Decodable, Equatable, Sendable {
    public var id: Int64
    public var chatRoomId: Int64
    /// 보낸 사람의 **공개 UUID**(JWT `sub` 와 같은 값). 현행 서버가 실어 주는 발신자 신원이며,
    /// 세션 uuid 와 비교하는 것만으로 내 메시지를 가릴 수 있다 — 학습도 사전도 필요 없다.
    public var publicId: String?
    /// 같은 값의 옛 이름. 앱이 백엔드에 요청했던 필드명이 `senderPublicId` 였고 서버는 `publicId` 로
    /// 냈다 — 어느 쪽이 와도 읽도록 둘 다 받는다(`publicId` 보다 이쪽이 우선).
    public var senderPublicId: String?
    /// 보낸 사람의 서버 내부 PK. **현행 서버는 주지 않는다**(기본값 0 이 그대로 남는다).
    /// 앱은 이 값을 더 이상 쓰지 않으며, 필드는 구버전 서버 응답을 파싱 에러 없이 받기 위해서만 남겼다.
    public var userId: Int64
    public var content: String
    public var type: String
    public var createdAt: String?
    public var deleted: Bool
    /// 보낸 사람 닉네임. 서버가 주지 않아 참여자 목록에서 채운다 — 오면 쓰는 관용 필드.
    public var senderNickname: String?

    public init(
        id: Int64,
        chatRoomId: Int64 = 0,
        publicId: String? = nil,
        senderPublicId: String? = nil,
        userId: Int64 = 0,
        content: String = "",
        type: String = "",
        createdAt: String? = nil,
        deleted: Bool = false,
        senderNickname: String? = nil
    ) {
        self.id = id
        self.chatRoomId = chatRoomId
        self.publicId = publicId
        self.senderPublicId = senderPublicId
        self.userId = userId
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.deleted = deleted
        self.senderNickname = senderNickname
    }

    private enum CodingKeys: String, CodingKey {
        case id, chatRoomId, publicId, senderPublicId, userId, content, type, createdAt, deleted, senderNickname
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        chatRoomId = try c.decodeOrDefault(.chatRoomId, default: 0)
        publicId = try c.decodeIfPresent(String.self, forKey: .publicId)
        senderPublicId = try c.decodeIfPresent(String.self, forKey: .senderPublicId)
        userId = try c.decodeOrDefault(.userId, default: 0)
        content = try c.decodeOrDefault(.content, default: "")
        type = try c.decodeOrDefault(.type, default: "")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        deleted = try c.decodeOrDefault(.deleted, default: false)
        senderNickname = try c.decodeIfPresent(String.self, forKey: .senderNickname)
    }
}

// 커서 페이징 응답 (ChatMessageSlice)
public struct ChatMessageSliceResponse: Decodable, Equatable, Sendable {
    public var messages: [ChatMessageResponse]
    public var nextCursor: Int64?
    public var hasNext: Bool

    public init(messages: [ChatMessageResponse] = [], nextCursor: Int64? = nil, hasNext: Bool = false) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.hasNext = hasNext
    }

    private enum CodingKeys: String, CodingKey {
        case messages, nextCursor, hasNext
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeOrDefault(.messages, default: [])
        nextCursor = try c.decodeIfPresent(Int64.self, forKey: .nextCursor)
        hasNext = try c.decodeOrDefault(.hasNext, default: false)
    }
}

// GET /api/v1/chat-rooms/{chatRoomId}/users → List<ChatRoomMemberResult>
// 배포 서버 실측(2026-09-09): {"publicId","nickname","imageUrl","active"} — userId 는 없다.
//
// 메시지도 publicId 로 발신자를 밝히므로 이 목록은 **publicId → 닉네임/프로필 사전**으로만 쓰인다
// (예전처럼 내부 PK 를 공개 신원으로 번역하는 다리 역할은 끝났다).
// active=false 는 방을 나간 사람이며, 그 사람이 남긴 메시지의 이름을 지우지 않기 위해 목록에 남는다.
public struct ChatMemberResponse: Decodable, Equatable, Sendable {
    /// 현행 서버는 주지 않는다(항상 null). 구버전 응답 호환으로만 남긴 필드.
    public var userId: Int64?
    public var publicId: String
    /// 참여자 닉네임. **nullable 인 건 방어가 아니라 서버 계약이다** —
    /// `users.nickname` 에 NOT NULL 제약이 없고(마이그레이션 V1~V9 어디에도 없다),
    /// `User` 엔티티에 `nickname = null` 로 사용자를 만드는 정식 경로(소셜 가입)가 있다.
    /// 같은 서버 값을 받는 `PartyDetailResponse.MemberInfo.nickname` 이 이미 nullable 이다 —
    /// 한쪽만 논-널로 두면 둘 중 하나가 거짓이 된다.
    ///
    /// **논-널로 선언하면 안 된다.** `JSONDecoder` 가 무시하는 건 모르는 **필드**이고
    /// (명시적 null 을 기본값으로 접지 않는다 — `decodeOrDefault` 주석) 논-널 필드에 명시적 `null` 이
    /// 오면 그 자리에서 예외다 — 닉네임 없는 참여자 한 명 때문에 `GET /chat-rooms/me` **응답 전체**가
    /// 깨져 채팅 탭이 영구 에러가 되고, 거기서 진행 중인 방을 찾는
    /// `RemoteActivePartyRepository.findFromChatRooms()` 까지 빈손이 된다(앱을 다시 설치한 사용자의
    /// 방 복귀 경로다).
    ///
    /// 매퍼는 이 null 을 빈 문자열로 떨어뜨린다(`toChatMember`) — 필드 자체가 없을 때와 같은 자리다.
    public var nickname: String?
    public var imageUrl: String?
    public var active: Bool

    public init(
        userId: Int64? = nil,
        publicId: String = "",
        nickname: String? = nil,
        imageUrl: String? = nil,
        active: Bool = true
    ) {
        self.userId = userId
        self.publicId = publicId
        self.nickname = nickname
        self.imageUrl = imageUrl
        self.active = active
    }

    private enum CodingKeys: String, CodingKey {
        case userId, publicId, nickname, imageUrl, active
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decodeIfPresent(Int64.self, forKey: .userId)
        publicId = try c.decodeOrDefault(.publicId, default: "")
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        active = try c.decodeOrDefault(.active, default: true)
    }
}
