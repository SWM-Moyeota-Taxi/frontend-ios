import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// `GET /chat-rooms/me` 가 방 정보와 참여자까지 담게 되면서(서버 2026-09-14) 앱은 목록을 **한 번만** 부른다.
/// 필드를 주지 않는 구버전 서버에서도 깨지지 않아야 배포 순서에 상관없이 동작한다.
@Suite struct ChatRoomListMappingTest {

    @Test("방 정보가 함께 오면 목록 항목만으로 방을 만든다")
    func roomFromListItem() throws {
        let body = """
            [{"chatRoomId":26,"departure":"서면역","destination":"해운대역","status":"ACTIVE",
              "lastReadMessageId":null,"unreadCount":2,"notificationMuted":false,
              "joinedAt":"2026-09-15T02:00:00Z","lastMessage":null,
              "members":[{"publicId":"me-uuid","nickname":"나","active":true},
                         {"publicId":"peer","nickname":"폴링라","active":true}]}]
            """

        let items = try decodeJSON([ChatRoomUserResponse].self, body)
        #expect(items.count == 1)
        let item = try #require(items.first)
        let room = try #require(item.toChatRoomOrNull(), "방 정보가 있어야 한다")

        #expect(room.id == 26)
        #expect(room.departure == "서면역")
        #expect(room.destination == "해운대역")
        #expect(room.status == .active)

        let membership = item.toMembership(myUuid: "me-uuid")
        #expect(membership.members.count == 2)
        #expect(try #require(membership.members.first { $0.publicId == "me-uuid" }).isMe)
        #expect(try #require(membership.members.first { $0.publicId == "peer" }).nickname == "폴링라")
    }

    @Test("구버전 서버는 방 정보가 없어 null 이고 참여자도 비어 있다")
    func legacyServer() {
        let legacy = ChatRoomUserResponse(chatRoomId: 26, unreadCount: 0)

        #expect(legacy.toChatRoomOrNull() == nil)
        #expect(legacy.toMembership(myUuid: "me-uuid").members.isEmpty)
    }

    /// 출발지만 오고 도착지가 없는 반쪽 응답은 쓰지 않는다 — 제목이 반쪽으로 그려지느니 상세를 다시 읽는다
    @Test("방 정보가 반쪽이면 쓰지 않는다")
    func halfRoomInfo() {
        let half = ChatRoomUserResponse(chatRoomId: 26, departure: "서면역", destination: nil)

        #expect(half.toChatRoomOrNull() == nil)
    }

    /// 목록 매퍼는 `partyId` 를 **모른다** — 응답에 그 필드가 없다.
    ///
    /// `UNKNOWN_PARTY_ID`(0)는 「없음」을 적은 자리값이고 **비교에 쓰면 안 되는 값**이다. 예전에
    /// 화면이 `partyId.toString() == activePartyId` 로 「진행 중인 방인가」를 가렸는데, 목록에서 연 방은
    /// 늘 0 이라 그 판정이 **언제나 거짓**이었다 — 진행 중인 방인데도 되돌릴 수 없는 「나가기」가
    /// 확인 없이 노출됐다(실기 QA). 지금은 채팅방 id 로 가린다(`ChatRoute.isActiveParty`).
    @Test("목록 매퍼는 partyId 를 모른다")
    func listMapperDoesNotKnowPartyId() throws {
        let item = ChatRoomUserResponse(
            chatRoomId: 26,
            departure: "서면역",
            destination: "해운대역",
            status: "ACTIVE"
        )

        let room = try #require(item.toChatRoomOrNull(), "방 정보가 있어야 한다")

        #expect(room.partyId == UNKNOWN_PARTY_ID, "목록 응답에 partyId 가 없으므로 「모른다」여야 한다")
    }

    /// 닉네임이 `null` 인 참여자 하나로 **목록 전체**가 깨지면 안 된다.
    ///
    /// 서버 `users.nickname` 에는 NOT NULL 제약이 없고(마이그레이션 V1~V9 어디에도 없다) `User` 엔티티에
    /// `nickname = null` 로 사용자를 만드는 정식 경로(소셜 가입)가 있다. DTO 를 논-널로 선언하면
    /// `JSONDecoder` 가 그 자리에서 예외를 던지고(모르는 **필드**만 흘려보내고 명시적 null 은 기본값으로
    /// 접지 않는다) `GET /chat-rooms/me` **응답 전체**가 깨져
    /// 채팅 탭이 영구 에러가 된다 — 거기서 진행 중인 방을 찾는 `RemoteActivePartyRepository` 까지
    /// 빈손이 되어 앱을 다시 설치한 사용자의 방 복귀 경로가 끊긴다.
    ///
    /// 지금은 소셜 로그인이 운영에 없어 터지지 않지만, 붙이는 날 터진다. 그래서 미리 못 박는다.
    @Test("닉네임이 null 인 참여자가 있어도 목록이 열린다")
    func nullNicknameMember() throws {
        let body = """
            [{"chatRoomId":26,"departure":"서면역","destination":"해운대역","status":"ACTIVE",
              "lastReadMessageId":null,"unreadCount":0,"notificationMuted":false,
              "joinedAt":"2026-09-15T02:00:00Z","lastMessage":null,
              "members":[{"publicId":"me-uuid","nickname":"나","active":true},
                         {"publicId":"peer","nickname":null,"active":true}]}]
            """

        let items = try decodeJSON([ChatRoomUserResponse].self, body)
        #expect(items.count == 1)
        let members = try #require(items.first).toMembership(myUuid: "me-uuid").members

        #expect(members.count == 2)
        // 「탈퇴」가 아니라 「닉네임 미설정」이라 빈 문자열로 떨어진다 — 읽는 쪽이 「동승자」로 부른다
        // (ChatRoute.chatRoomPeerTitle 의 PEER_FALLBACK_NAME).
        #expect(try #require(members.first { $0.publicId == "peer" }).nickname == "")
        #expect(try #require(members.first { $0.publicId == "me-uuid" }).isMe)
    }
}
