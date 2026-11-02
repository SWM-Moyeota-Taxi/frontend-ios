import MoyeotaDomain
import Testing
@testable import FeatureChat

/// 「이 채팅방이 지금 진행 중인 방의 것인가」(`ChatRoom.isActiveParty`) — **두 가지를 동시에 정하는 판정**이다.
///
/// | 판정이 참이면 | 화면 |
/// |---|---|
/// | 「매칭 화면으로 →」 배너를 그린다 | `ChatRoute` 가 `onOpenMatching` 을 넘긴다 → `ChatScreen` 이 `onOpenMatching != nil` 일 때만 그린다 |
/// | 「나가기」를 메뉴에서 **감춘다** | `canLeave = onOpenMatching == nil` |
///
/// 그래서 이 함수가 틀리면 **되돌릴 수 없는 「나가기」가 진행 중인 방에 노출되고**, 동시에 목록에서 들어온
/// 사용자의 **유일한 복귀 길**이 사라진다(`ChatScreen` 의 `onOpenMatching` 주석).
///
/// 2026-10-28 결함: 판정이 `partyId.toString() == activePartyId` 였는데, 채팅 **탭 목록**에서 연 방은
/// `partyId` 가 0(= 「모른다」 — `GET /chat-rooms/me` 에 partyId 가 없어 매퍼가 채운 자리값)이라
/// `"0" == "57"` 로 **언제나 거짓**이었다. 운영 서버가 목록에 `departure`/`destination` 을 실어 주므로
/// 목록 경로는 늘 그 방을 쓴다 — 즉 **실사용 경로에서만** 깨져 있었다. 그래서 「목록에서 연 방」 모양을
/// 여기서 못 박는다.
@Suite struct ActiveRoomGateTest {

    /// 채팅 탭 목록에서 연 방 — `toChatRoomOrNull()` 산물이라 partyId 가 0(모름)이다
    private func roomFromList(id: Int64) -> ChatRoom {
        ChatRoom(
            id: id,
            partyId: 0,
            departure: "서면역",
            destination: "해운대역",
            createdAt: "2026-10-28T02:00:00Z",
            status: .active
        )
    }

    /// 21·25·26 의 「채팅 열기」로 연 방 — 방 상세에서 온 **진짜** partyId 를 들고 있다
    private func roomFromDetail(id: Int64, partyId: Int64) -> ChatRoom {
        var room = roomFromList(id: id)
        room.partyId = partyId
        return room
    }

    @Test("채팅 탭 목록에서 연 진행 중 방은 나가기를 노출하지 않는다")
    func listRoomHidesLeave() {
        // 나가기 노출은 canLeave = (onOpenMatching == nil) 이고, onOpenMatching 은 이 판정이
        // 참일 때만 넘어간다 — 참이면 나가기가 사라진다.
        let room = roomFromList(id: 26)

        #expect(
            room.isActiveParty(activeChatRoomId: 26, activePartyId: "57"),
            "목록에서 연 방이라 partyId=0 이지만 채팅방 id 로 진행 중임을 알 수 있어야 한다"
        )
    }

    @Test("채팅 탭 목록에서 연 진행 중 방은 매칭 복귀 배너를 그린다")
    func listRoomShowsMatchingBanner() {
        // 배너는 ChatScreen 이 onOpenMatching != nil 일 때만 그린다 — 위와 같은 판정이 근거다.
        // 목록에서 들어온 사용자에게는 이게 21/25/26 으로 돌아가는 유일한 길이다.
        let room = roomFromList(id: 26)

        #expect(room.isActiveParty(activeChatRoomId: 26))
    }

    @Test("진행 중이 아닌 방은 그대로 거짓이다")
    func otherRoomIsFalse() {
        // 다른 방을 열었다 — 배너도 없고 나가기는 메뉴에 남는다(단, 재확인을 거친다)
        #expect(!roomFromList(id: 31).isActiveParty(activeChatRoomId: 26, activePartyId: "57"))
    }

    @Test("진행 중인 방이 없으면 언제나 거짓이다")
    func noActivePartyIsFalse() {
        #expect(!roomFromList(id: 26).isActiveParty(activeChatRoomId: nil, activePartyId: nil))
    }

    /// 0 은 「모른다」지 「0번 파티」가 아니다. 진행 중인 방 id 가 어쩌다 "0" 으로 들어와도
    /// 목록에서 연 모든 방이 진행 중으로 뒤집히면 안 된다.
    @Test("partyId 0 은 모른다는 뜻이라 비교에 쓰이지 않는다")
    func unknownPartyIdIsNotCompared() {
        #expect(!roomFromList(id: 26).isActiveParty(activeChatRoomId: nil, activePartyId: "0"))
    }

    /// 단독 목적지 경로(21·25·26 의 「채팅 열기」)는 진짜 partyId 를 들고 있다 — 진행 중인 방의
    /// **채팅방 id 를 아직 못 찾은 구간**(ActivePartyViewModel 이 10초 주기로 찾는다)에도 판정이 서야 한다.
    @Test("채팅방 id 를 아직 모르면 방 상세의 partyId 가 받친다")
    func detailPartyIdBacksUp() {
        let room = roomFromDetail(id: 26, partyId: 57)

        #expect(room.isActiveParty(activeChatRoomId: nil, activePartyId: "57"))
        #expect(!room.isActiveParty(activeChatRoomId: nil, activePartyId: "58"))
    }
}
