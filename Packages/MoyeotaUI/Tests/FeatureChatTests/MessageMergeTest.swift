import MoyeotaDomain
import Testing
@testable import FeatureChat

/// 같은 id 의 메시지가 두 번 들어올 때 **어느 사본이 남는가**(`mergeMessagesById`).
///
/// 예전에는 `distinctBy { it.id }` 였고, 그건 **먼저 등장한** 쪽을 남긴다. 그래서 동승자가 메시지를
/// 지우면 서버가 같은 id 를 `deleted=true`·「삭제된 메시지입니다」로 다시 브로드캐스트하는데도
/// (`ChatMessageBroadcaster.onMessageDeleted`) 화면은 삭제 전 원문을 그대로 들고 있었다 —
/// **지운 말이 화면에 남는다.** 증상이 「아무 일도 안 일어남」이라 눈으로는 회귀를 못 잡는다.
@Suite struct MessageMergeTest {

    private func message(_ id: Int64, _ content: String, deleted: Bool = false) -> ChatMessage {
        ChatMessage(
            id: id,
            chatRoomId: 1,
            senderPublicId: "uuid-peer",
            content: content,
            type: .text,
            createdAt: "2026-10-28T02:00:0\(id)Z",
            deleted: deleted,
            isMine: false,
            senderName: "동승자"
        )
    }

    @Test("같은 id 의 새 사본이 이긴다")
    func newCopyWins() throws {
        let held = [message(1, "안녕"), message(2, "지울 말")]
        let deletedCopy = message(2, "삭제된 메시지입니다", deleted: true)

        let merged = mergeMessagesById(held: held, incoming: [deletedCopy])

        #expect(merged.count == 2)
        let second = try #require(merged.last)
        #expect(second.content == "삭제된 메시지입니다")
        #expect(second.deleted, "deleted 플래그까지 새 사본을 따라야 한다")
    }

    @Test("합친 뒤에도 id 오름차순이다")
    func sortedAscending() {
        // 소켓·조회·REST 응답이 섞여 들어오는 자리라 순서를 믿을 수 없다 — 말풍선 순서의 유일한 근거다
        let merged = mergeMessagesById(
            held: [message(5, "다섯"), message(1, "하나")],
            incoming: [message(9, "아홉"), message(3, "셋")]
        )

        #expect(merged.map(\.id) == [1, 3, 5, 9])
    }

    @Test("겹치지 않으면 둘 다 남는다")
    func disjointKeepsBoth() {
        let merged = mergeMessagesById(held: [message(1, "하나")], incoming: [message(2, "둘")])

        #expect(merged.map(\.id) == [1, 2])
    }

    @Test("한쪽이 비어도 그대로 돌려준다")
    func emptySideReturnsOther() {
        let held = [message(1, "하나")]

        #expect(mergeMessagesById(held: held, incoming: []) == held)
        #expect(mergeMessagesById(held: [], incoming: held) == held)
    }
}
