import MoyeotaDomain
import Testing
@testable import FeatureChat

/// 소켓 전송은 응답이 없다 — 보낸 메시지는 구독으로 **되돌아와야** 확인된다.
/// 그 확인이 어떤 메시지와 짝지어지는지가 「보내는 중」 말풍선이 사라지는 규칙이다.
@Suite struct PendingMessageTest {

    private func message(_ id: Int64, _ content: String, mine: Bool = true) -> ChatMessage {
        ChatMessage(
            id: id,
            chatRoomId: 1,
            senderPublicId: mine ? "me" : "peer",
            content: content,
            type: .text,
            createdAt: "2026-09-15T00:00:00Z",
            deleted: false,
            isMine: mine,
            senderName: mine ? nil : "동승자"
        )
    }

    private func pending(_ localId: Int64, _ content: String, sinceId: Int64) -> ChatRoomViewModel.PendingMessage {
        ChatRoomViewModel.PendingMessage(localId: localId, content: content, sinceId: sinceId)
    }

    @Test("되돌아온 내 메시지와 짝지어지면 사라진다")
    func echoRemovesPending() {
        let left = reconcilePending(
            messages: [message(10, "다 왔어요")],
            pending: [pending(-1, "다 왔어요", sinceId: 9)]
        )

        #expect(left.isEmpty)
    }

    @Test("보내기 전에 있던 같은 문장은 확인이 아니다")
    func olderSameTextIsNotEcho() {
        let left = reconcilePending(
            messages: [message(9, "네")],
            pending: [pending(-1, "네", sinceId: 9)]
        )

        #expect(left.count == 1)
    }

    @Test("같은 문장을 두 번 보내면 하나씩 짝지어진다")
    func sameTextPairsOneByOne() {
        let waiting = [pending(-1, "네", sinceId: 5), pending(-2, "네", sinceId: 5)]

        let one = reconcilePending(messages: [message(6, "네")], pending: waiting)
        #expect(one.map(\.localId) == [-2])

        let none = reconcilePending(messages: [message(6, "네"), message(7, "네")], pending: waiting)
        #expect(none.map(\.localId) == [])
    }

    @Test("같은 내용이어도 상대가 보낸 메시지는 확인이 아니다")
    func peerSameTextIsNotEcho() {
        let left = reconcilePending(
            messages: [message(10, "네", mine: false)],
            pending: [pending(-1, "네", sinceId: 5)]
        )

        #expect(left.count == 1)
    }
}
