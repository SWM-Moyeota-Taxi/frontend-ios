/// POST /api/v1/chat-rooms/{chatRoomId}/reports 요청 본문
/// (백엔드 chat/report/dto/ChatReportRequest.java 와 필드 1:1). 응답은 **201, 본문 없음**이다 —
/// reportId 를 주지 않으므로 응답 DTO 가 없다.
///
/// **기존 긴급 신고(`ReportRequestDto`)와 다른 것이다.** 그쪽은 「파티 + 내 좌표」를 신고하고 사유
/// 필드가 아예 없다(`ReportRequestDto` 주석의 「임의로 추가하지 말 것」). 이쪽은 **메시지 1건**을
/// 사유와 함께 신고한다. 둘을 한 DTO 로 합치면 어느 쪽이든 서버가 400 으로 거절한다 —
/// `ChatReportContractTest` 가 그 합침을 막는다.
///
/// ### 필드
/// - `chatMessageId` — 서버가 `@NotNull @Positive` 로 받는다. 0 을 보내면 400 `INVALID_REQUEST`
///   (「메시지 ID는 1 이상이어야 합니다」), 없는 id 면 404 `CHAT_MESSAGE_NOT_FOUND` 다.
/// - `reason` — **대문자 enum 이름**이어야 한다. 소문자 `abuse` 를 보내면 400 `INVALID_REQUEST`
///   (「요청 본문이 없거나 형식이 잘못되었습니다」)다 — 그래서 Swift enum 을 직렬화에 맡기지 않고
///   매퍼가 `ChatReportReason` 의 `name` 을 명시적으로 넣는다. 서버가 값을
///   하나 더 늘려도 이 계층이 조용히 깨지지 않는다.
/// - `description` — **`ChatReportReason.etc` 일 때만 필수**다. 없거나
///   공백만 있으면 400 `CHAT_REPORT_DESCRIPTION_REQUIRED`(서버가 `isBlank` 로 본다 — 실측). 그 밖의
///   사유에서는 **생략해도 201** 이다. 500자를 넘기면 400 `INVALID_REQUEST` 다.
///
/// 기본값 null 이라 `description` 이 없으면 키 자체가 본문에서 빠진다(합성 `Encodable` 의 `encodeIfPresent`).
/// 서버 엔티티에 `@Column(nullable = false)` 가 붙어 있지만 마이그레이션 쪽이 nullable 이라 실제로
/// 통과한다 — 애노테이션만 보고 「빈 문자열이라도 넣어야 한다」고 판단하면 ETC 검사에 걸린다.
///
/// 신고자는 Bearer 토큰이 정한다(`@CurrentUser`) — reporterId 를 싣지 않는다.
///
/// 전부 실측(2026-11-01, 로컬 :8080)으로 확인한 계약이다.
public struct ChatReportRequestDto: Codable, Equatable, Sendable {
    public var chatMessageId: Int64
    public var reason: String
    public var description: String?

    public init(chatMessageId: Int64, reason: String, description: String? = nil) {
        self.chatMessageId = chatMessageId
        self.reason = reason
        self.description = description
    }
}
