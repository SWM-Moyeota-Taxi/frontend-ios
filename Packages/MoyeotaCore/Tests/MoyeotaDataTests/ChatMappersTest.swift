import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

private let UUID_ME = "uuid-me"
private let UUID_OTHER = "uuid-other"

@Suite struct ChatMappersTest {

    // 참여자 목록을 아직 못 받은 상태. isMine 은 여기서도 정확해야 한다 — 사전은 이름 전용이다.
    private let noDictionary = ChatIdentity(myUuid: UUID_ME)

    // 참여자 목록을 받아 둔 상태: 나 / 동승자 / 방을 나간 사람.
    private let known = ChatIdentity(
        myUuid: UUID_ME,
        members: Dictionary(
            uniqueKeysWithValues: [
                member(publicId: UUID_ME, nickname: "성윤"),
                member(publicId: UUID_OTHER, nickname: "자동에이"),
                member(publicId: "uuid-gone", nickname: "먼저내림", active: false),
            ].map { ($0.publicId, $0) }
        )
    )

    @Test("채팅방 응답을 도메인 ChatRoom 으로 매핑한다")
    func mapsChatRoom() {
        let room = ChatRoomResponse(
            id: 5,
            partyId: 7,
            departure: "서울시청",
            destination: "강남역",
            createdAt: "2026-08-24T09:00:00Z",
            status: "CLOSED"
        ).toChatRoom()

        #expect(room.id == 5)
        #expect(room.partyId == 7)
        #expect(room.status == .closed)
        #expect(room.createdAt == "2026-08-24T09:00:00Z")
    }

    @Test("알 수 없는 방 상태와 메시지 타입은 기본값으로 흡수한다")
    func unknownEnumsFallBack() {
        #expect(chatRoomStatusOf(raw: "SOMETHING_NEW") == .active)
        #expect(chatMessageTypeOf(raw: "SOMETHING_NEW") == .text)
        #expect(chatMessageTypeOf(raw: "LOCATION") == .location)
    }

    /// 배포 서버 실측 응답(2026-09-09) 그대로. 발신자는 `publicId` 로 오고 `userId` 는 없다 —
    /// 이 JSON 이 파싱되고 publicId 가 도메인까지 흐르는지가 이번 전환의 핵심이다.
    @Test("서버 실측 응답의 publicId 를 senderPublicId 로 매핑한다")
    func mapsPublicId() throws {
        let body = """
            {"id":4,"chatRoomId":1,"publicId":"uuid-me","content":"probe","type":"TEXT",
             "createdAt":"2026-09-09T07:23:16.242906Z","deleted":false}
            """

        let message = try decodeJSON(ChatMessageResponse.self, body).toChatMessage(identity: noDictionary)

        #expect(message.senderPublicId == UUID_ME)
        #expect(message.content == "probe")
        #expect(message.type == .text)
        #expect(message.isMine, "서버가 준 publicId 가 내 uuid 인데 남의 메시지로 판정했다")
    }

    @Test("발신자 publicId 가 세션 uuid 와 다르면 남의 메시지다")
    func otherSenderIsNotMine() {
        #expect(!chatMessage(id: 21, publicId: UUID_OTHER).toChatMessage(identity: noDictionary).isMine)
    }

    /// 관용 필드. 서버가 필드명을 `senderPublicId` 로 되돌려도 앱이 따라간다.
    @Test("senderPublicId 로 와도 같은 값으로 읽는다")
    func readsSenderPublicId() {
        let message = ChatMessageResponse(id: 22, senderPublicId: UUID_ME).toChatMessage(identity: noDictionary)

        #expect(message.senderPublicId == UUID_ME)
        #expect(message.isMine)
    }

    @Test("senderPublicId 와 publicId 가 함께 오면 senderPublicId 가 이긴다")
    func senderPublicIdWins() {
        let message = ChatMessageResponse(id: 23, publicId: UUID_ME, senderPublicId: UUID_OTHER)

        #expect(!message.toChatMessage(identity: noDictionary).isMine)
    }

    /// 빈 문자열끼리의 비교로 남의 메시지가 내 것이 되면 안 된다. 미로그인(myUuid=null)이면 더 위험하다.
    @Test("발신자 식별자가 비었으면 누구의 메시지도 아니다")
    func blankSenderIsNobody() {
        let blank = ChatMessageResponse(id: 24, publicId: " ", senderPublicId: "")

        #expect(blank.toChatMessage(identity: noDictionary).senderPublicId == nil)
        #expect(!blank.toChatMessage(identity: noDictionary).isMine)
        #expect(!blank.toChatMessage(identity: ChatIdentity(myUuid: nil)).isMine)
    }

    @Test("미로그인 상태에서는 어떤 메시지도 내 것이 아니다")
    func loggedOutOwnsNothing() {
        #expect(!chatMessage(id: 25, publicId: UUID_ME).toChatMessage(identity: ChatIdentity(myUuid: nil)).isMine)
    }

    @Test("삭제된 메시지는 deleted 플래그와 치환된 본문을 유지한다")
    func deletedMessage() {
        let message = ChatMessageResponse(
            id: 26,
            chatRoomId: 5,
            publicId: UUID_ME,
            content: "삭제된 메시지입니다",
            type: "TEXT",
            deleted: true
        ).toChatMessage(identity: noDictionary)

        #expect(message.deleted)
        #expect(message.content == "삭제된 메시지입니다")
    }

    @Test("참여자 목록에서 보낸 사람 닉네임을 채운다")
    func senderNameFromMembers() {
        #expect(chatMessage(id: 27, publicId: UUID_OTHER).toChatMessage(identity: known).senderName == "자동에이")
    }

    // 나간 사람(active=false)도 사전에 남는다. 빼면 그 사람이 남긴 대화가 통째로 "동승자"가 된다.
    @Test("방을 나간 참여자의 메시지도 이름을 유지한다")
    func departedMemberKeepsName() {
        let message = chatMessage(id: 28, publicId: "uuid-gone").toChatMessage(identity: known)

        #expect(message.senderName == "먼저내림")
        #expect(!message.isMine)
    }

    @Test("사전에 없는 발신자는 senderNickname 폴백을 쓰고 없으면 null 이다")
    func senderNicknameFallback() {
        let withNickname = ChatMessageResponse(id: 29, publicId: "uuid-newcomer", senderNickname: "중간합류")
        let without = chatMessage(id: 30, publicId: "uuid-newcomer")

        #expect(withNickname.toChatMessage(identity: known).senderName == "중간합류")
        #expect(without.toChatMessage(identity: known).senderName == nil)
    }

    /// 사전이 우선이다 — 서버가 실어 준 닉네임보다 방 참여자 목록이 최신이다.
    @Test("참여자 목록의 닉네임이 senderNickname 보다 우선한다")
    func membersWinOverSenderNickname() {
        let message = ChatMessageResponse(id: 31, publicId: UUID_OTHER, senderNickname: "옛이름")

        #expect(message.toChatMessage(identity: known).senderName == "자동에이")
    }

    @Test("커서 페이징 응답을 ChatMessagePage 로 매핑한다")
    func mapsPage() {
        let page = ChatMessageSliceResponse(
            messages: [ChatMessageResponse(id: 1), ChatMessageResponse(id: 2)],
            nextCursor: 1,
            hasNext: true
        ).toPage(identity: noDictionary)

        #expect(page.messages.count == 2)
        #expect(page.nextCursor == 1)
        #expect(page.hasNext)
    }

    @Test("마지막 페이지는 nextCursor 가 null 이다")
    func lastPage() {
        let page = ChatMessageSliceResponse(messages: [], nextCursor: nil, hasNext: false)
            .toPage(identity: noDictionary)

        #expect(page.nextCursor == nil)
        #expect(page.messages.isEmpty)
    }

    @Test("아직 아무것도 안 읽은 참여자는 lastReadMessageId 가 null 이다")
    func nothingRead() {
        let membership = ChatRoomUserResponse(chatRoomId: 5, lastReadMessageId: nil).toMembership()

        #expect(membership.lastReadMessageId == nil)
        #expect(membership.chatRoomId == 5)
        #expect(membership.joinedAt == "")
    }

    // /chat-rooms/me 는 래핑 객체가 아니라 배열을 그대로 내려준다.
    @Test("내 채팅방 목록 응답 JSON 을 배열로 역직렬화한다")
    func decodesRoomArray() throws {
        let body = """
            [{"chatRoomId":1,"lastReadMessageId":null,"notificationMuted":false,"joinedAt":"2026-09-08T06:14:44.468742Z"}]
            """

        let decoded = try decodeJSON([ChatRoomUserResponse].self, body)

        #expect(decoded.count == 1)
        #expect(decoded[0].toMembership().lastReadMessageId == nil)
    }

    /// 서버 커밋 963c340(2026-09-11): 목록 항목에 lastMessage 가 실린다. 발신자·읽음 커서로 안읽음을 가른다.
    @Test("목록의 lastMessage 를 매핑하고 남의 메시지가 커서 뒤면 안읽음이다")
    func lastMessageAfterCursorIsUnread() throws {
        let body = """
            [{"chatRoomId":7,"lastReadMessageId":40,"notificationMuted":false,"joinedAt":"2026-09-08T06:14:44Z",
              "lastMessage":{"id":41,"senderPublicId":"peer-uuid","content":"어디쯤이세요?","type":"TEXT","createdAt":"2026-09-11T02:52:55.123Z"}}]
            """

        let membership = try decodeJSON([ChatRoomUserResponse].self, body)[0].toMembership(myUuid: "me-uuid")

        let last = try #require(membership.lastMessage, "lastMessage 가 없다")
        #expect(last.id == 41)
        #expect(last.content == "어디쯤이세요?")
        #expect(last.type == .text)
        #expect(last.senderPublicId == "peer-uuid")
        #expect(!last.isMine)
        #expect(membership.hasUnread)
    }

    @Test("내가 보낸 메시지가 마지막이면 커서가 뒤처져도 안읽음이 아니다")
    func myLastMessageIsNotUnread() throws {
        let membership = ChatRoomUserResponse(
            chatRoomId: 7,
            lastReadMessageId: 40,
            lastMessage: ChatLastMessageResponse(id: 41, senderPublicId: "me-uuid", content: "네", type: "TEXT")
        ).toMembership(myUuid: "me-uuid")

        #expect(try #require(membership.lastMessage).isMine)
        #expect(!membership.hasUnread)
    }

    @Test("커서가 마지막 메시지에 닿아 있으면 안읽음이 아니고, 메시지가 없으면 커서가 없어도 안읽음이 아니다")
    func cursorAtLastAndEmptyRoom() {
        let read = ChatRoomUserResponse(
            chatRoomId: 7,
            lastReadMessageId: 41,
            lastMessage: ChatLastMessageResponse(id: 41, senderPublicId: "peer", content: "네", type: "TEXT")
        ).toMembership(myUuid: "me-uuid")
        #expect(!read.hasUnread)

        let empty = ChatRoomUserResponse(chatRoomId: 8, lastReadMessageId: nil).toMembership(myUuid: "me-uuid")
        #expect(empty.lastMessage == nil)
        #expect(!empty.hasUnread)
    }

    /// 서버 7c95683(2026-09-12): 목록 항목에 unreadCount. 개수가 오면 그것이 안읽음의 유일한 근거다.
    @Test("unreadCount 가 오면 마지막 메시지 판정보다 우선한다")
    func unreadCountWins() throws {
        let body = """
            [{"chatRoomId":7,"lastReadMessageId":null,"notificationMuted":true,"joinedAt":"2026-09-08T06:14:44Z","unreadCount":3,
              "lastMessage":{"id":41,"senderPublicId":"peer","content":"안녕","type":"TEXT","createdAt":"2026-09-11T02:52:55Z"}}]
            """
        let membership = try decodeJSON([ChatRoomUserResponse].self, body)[0].toMembership(myUuid: "me-uuid")

        #expect(membership.unreadCount == 3)
        #expect(membership.hasUnread)
        #expect(membership.notificationMuted)

        // 커서가 없어도(한 번도 안 읽음) 서버가 0 이라 하면 0 이다 — 내 메시지뿐인 방
        let zero = ChatRoomUserResponse(
            chatRoomId: 7,
            lastReadMessageId: nil,
            lastMessage: ChatLastMessageResponse(id: 41, senderPublicId: "peer", content: "안녕", type: "TEXT"),
            unreadCount: 0
        ).toMembership(myUuid: "me-uuid")
        #expect(zero.unreadCount == 0)
        #expect(!zero.hasUnread)
    }

    @Test("unreadCount 가 없는 구서버 응답은 마지막 메시지로 유무만 가리고, 음수는 0 으로 접는다")
    func legacyAndNegativeUnreadCount() {
        let legacy = ChatRoomUserResponse(
            chatRoomId: 7,
            lastReadMessageId: 40,
            lastMessage: ChatLastMessageResponse(id: 41, senderPublicId: "peer", content: "안녕", type: "TEXT")
        ).toMembership(myUuid: "me-uuid")
        #expect(legacy.unreadCount == nil)
        #expect(legacy.hasUnread)

        let negative = ChatRoomUserResponse(chatRoomId: 7, unreadCount: -5).toMembership(myUuid: "me-uuid")
        #expect(negative.unreadCount == 0)
        #expect(!negative.hasUnread)
    }

    /// 발신자를 못 찾은(탈퇴) 마지막 메시지: senderPublicId null → 내 것이 아니고, 빈 uuid 끼리 같다고 보지 않는다.
    @Test("발신자 없는 마지막 메시지는 세션이 없어도 내 것이 되지 않는다")
    func lastMessageWithoutSender() {
        let last = ChatLastMessageResponse(id: 1, senderPublicId: "", content: "x", type: "LOCATION")
            .toLastMessage(myUuid: nil)

        #expect(last.senderPublicId == nil)
        #expect(!last.isMine)
        #expect(last.type == .location)
    }

    /// 배포 서버 실측(2026-09-09): 참여자 응답에 userId 가 없다. 없어도 매핑이 깨지면 안 된다.
    @Test("참여자 응답을 도메인 ChatMember 로 매핑한다")
    func mapsChatMember() throws {
        let body = """
            [{"publicId":"uuid-me","nickname":"스모크일","imageUrl":null,"active":true},
             {"publicId":"uuid-other","nickname":"스모크이","imageUrl":"http://img","active":false}]
            """

        let decoded = try decodeJSON([ChatMemberResponse].self, body).map { $0.toChatMember(myUuid: UUID_ME) }

        #expect(decoded.map(\.userId) == [nil, nil], "서버가 안 주는 userId 가 채워졌다")
        #expect(decoded[0].isMe)
        #expect(decoded[0].nickname == "스모크일")
        #expect(!decoded[1].isMe)
        #expect(!decoded[1].active)
        #expect(decoded[1].imageUrl == "http://img")
    }

    // 로그아웃 상태(myUuid=null)에서 publicId 가 빈 참여자를 만나면 "빈 값끼리 같다"로
    // 남이 나로 둔갑할 수 있다 — 그 구멍을 막는다.
    @Test("publicId 가 비면 누구도 내가 되지 않는다")
    func blankPublicIdIsNeverMe() {
        #expect(!ChatMemberResponse(publicId: "").toChatMember(myUuid: nil).isMe)
        #expect(!ChatMemberResponse(publicId: "").toChatMember(myUuid: UUID_ME).isMe)
    }

    // 구버전 서버(userId 만 주고 publicId 는 없음) 응답도 파싱은 깨지지 않아야 한다.
    // 다만 발신자를 알 수 없으니 내 메시지 판정은 포기한다 — 학습 폴백은 삭제됐다.
    @Test("userId 만 오는 구버전 응답은 파싱되되 발신자를 알 수 없다")
    func legacyUserIdOnly() throws {
        let body = #"{"id":20,"chatRoomId":5,"userId":3,"content":"안녕","type":"TEXT","deleted":false}"#

        let decoded = try decodeJSON(ChatMessageResponse.self, body)
        let message = decoded.toChatMessage(identity: noDictionary)

        #expect(decoded.userId == 3)
        #expect(message.senderPublicId == nil)
        #expect(!message.isMine)
    }
}

// 원본 이름은 `message` 다. Swift 는 `let message = message(…)` 를 자기 참조로 보아 이름을 바꿨다.
private func chatMessage(id: Int64, publicId: String) -> ChatMessageResponse {
    ChatMessageResponse(
        id: id,
        chatRoomId: 1,
        publicId: publicId,
        content: "내용",
        type: "TEXT"
    )
}

private func member(publicId: String, nickname: String, active: Bool = true) -> ChatMember {
    ChatMemberResponse(
        publicId: publicId,
        nickname: nickname,
        imageUrl: nil,
        active: active
    ).toChatMember(myUuid: UUID_ME)
}
