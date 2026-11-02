/// 경로 기준: chat/presentation/{ChatRoom,ChatRoomUser,ChatMessage}Controller.java
/// + chat/report/presentation/ChatReportController.java
///
/// **주체는 Bearer 토큰 하나가 정한다.** 채팅 컨트롤러가 `@RequestHeader("X-User-Id") Long userId` 에서
/// `@CurrentUser Long userId` 로 전환되면서(백엔드 PR #72) 앱이 사용자 id 를 실어 보낼 자리는 사라졌다.
/// 남은 요구사항은 `Authorization: Bearer` 뿐이고, 이건 인터셉터가 붙인다
/// (NetworkModule 의 apiClient). 없으면 401 `USER005` 다.
///
/// 그래서 이 프로토콜에는 헤더 인자가 하나도 없어야 한다 — 되살아나면
/// `AuthenticatedPathContractTest` 가 깨진다.
/// (전환 전에는 헤더의 id 와 토큰 주체가 서로 검증되지 않아, 로그인 계정과 무관한 고정 id 로
/// 채팅이 나가고 있었다.)
///
/// 실패 본문은 이 도메인만 형식이 다르다: `ErrorResponse(code, message)` 이며 code 는
/// `ChatErrorCode` 의 enum 이름이다(`CHAT_NOT_PARTICIPANT` 등). 인증 쪽 `USER1xx` 번호 코드가 아니다.
public protocol ChatApi: Sendable {

    // --- ChatRoomController ---
    func getRoom(chatRoomId: Int64) async throws -> ChatRoomResponse

    // --- ChatRoomUserController ---
    // 방 이름 없이 내 참여 정보만 배열로 내려온다(래핑 객체 아님).
    func getMyRooms() async throws -> [ChatRoomUserResponse]

    // 201 Created, 본문 없음
    func joinRoom(chatRoomId: Int64) async throws

    // 200 OK, 본문 없음
    func leaveRoom(chatRoomId: Int64) async throws

    // 방 참여자 목록. 참여자만 부를 수 있다(아니면 403 CHAT_NOT_PARTICIPANT).
    // 나간 사람도 active=false 로 함께 내려온다 — 그 사람 메시지의 이름을 유지하기 위해서다.
    func getMembers(chatRoomId: Int64) async throws -> [ChatMemberResponse]

    // 200 OK, 본문 없음
    // 알림 음소거 — 같은 경로에 POST(끄기) / DELETE(켜기). 둘 다 200, 본문 없음.
    func muteNotification(chatRoomId: Int64) async throws

    func unmuteNotification(chatRoomId: Int64) async throws

    func readRoom(chatRoomId: Int64, readMessageId: Int64) async throws

    // --- ChatMessageController ---
    // cursor 생략 시 최신 메시지부터. 서버 기본 size 는 30.
    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessageSliceResponse

    // cursor 필수 — 이 값 이후의 새 메시지를 가져온다.
    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessageSliceResponse

    // 201 Created, 생성된 메시지 반환
    func sendMessage(chatRoomId: Int64, request: SendMessageRequestDto) async throws -> ChatMessageResponse

    // 204 No Content
    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws

    // keyword 는 2자 이상이어야 한다 — 미만이면 400 CHAT_INVALID_KEYWORD.
    // 응답은 조회와 같은 ChatMessageSlice 다.
    func searchMessages(
        chatRoomId: Int64,
        keyword: String,
        cursor: Int64?,
        size: Int
    ) async throws -> ChatMessageSliceResponse

    // --- ChatReportController ---
    /// 메시지 신고. **201 Created, 본문 없음** — reportId 를 주지 않는다(기존 긴급 신고
    /// `POST /api/v1/reports` 는 `{reportId}` 를 준다. 둘은 다른 엔드포인트다).
    ///
    /// 참여자만 부를 수 있다. 아니면 403 `CHAT_NOT_PARTICIPANT` 인데, **없는 방도 같은 403** 이다
    /// (404 가 아니다 — 실측). 반면 없는 메시지 id 는 404 `CHAT_MESSAGE_NOT_FOUND` 다.
    ///
    /// **방이 끝난 뒤에도 받는다** — 파티 상태를 보지 않고 채팅방 참여 여부만 본다
    /// (CANCELED 파티의 방에서도 201. 위치 공유 쪽과 권한 기준이 다른 지점이다).
    ///
    /// 같은 메시지를 두 번 신고하면 409 `CHAT_ALREADY_REPORTED` 이고, **사유를 바꿔도 409** 다 —
    /// 중복 판정이 「신고자 + 메시지」라 사유별로 따로 쌓이지 않는다(실측). 내 메시지면
    /// 400 `CHAT_CANNOT_REPORT_SELF` 라 화면이 애초에 길을 만들지 않는다.
    ///
    /// 실측(2026-11-01, 로컬 :8080).
    func reportMessage(chatRoomId: Int64, request: ChatReportRequestDto) async throws
}

enum ChatApiRoute: String, CaseIterable, ApiRouteSet {
    case getRoom, getMyRooms, joinRoom, leaveRoom, getMembers, muteNotification, unmuteNotification, readRoom
    case getMessages, getMessagesAfter, sendMessage, deleteMessage, searchMessages, reportMessage

    var route: ApiRoute {
        switch self {
        case .getRoom: .GET("api/v1/chat-rooms/{chatRoomId}")
        case .getMyRooms: .GET("api/v1/chat-rooms/me")
        case .joinRoom: .POST("api/v1/chat-rooms/{chatRoomId}/users")
        case .leaveRoom: .DELETE("api/v1/chat-rooms/{chatRoomId}/users")
        case .getMembers: .GET("api/v1/chat-rooms/{chatRoomId}/users")
        case .muteNotification: .POST("api/v1/chat-rooms/{chatRoomId}/users/notification/mute")
        case .unmuteNotification: .DELETE("api/v1/chat-rooms/{chatRoomId}/users/notification/mute")
        case .readRoom: .POST("api/v1/chat-rooms/{chatRoomId}/users/read/{readMessageId}")
        case .getMessages: .GET("api/v1/chat-rooms/{chatRoomId}/messages", query: ["cursor", "size"])
        case .getMessagesAfter: .GET("api/v1/chat-rooms/{chatRoomId}/messages/after", query: ["cursor", "size"])
        case .sendMessage: .POST("api/v1/chat-rooms/{chatRoomId}/messages")
        case .deleteMessage: .DELETE("api/v1/chat-rooms/{chatRoomId}/messages/{messageId}")
        case .searchMessages:
            .GET("api/v1/chat-rooms/{chatRoomId}/messages/search", query: ["keyword", "cursor", "size"])
        case .reportMessage: .POST("api/v1/chat-rooms/{chatRoomId}/reports")
        }
    }
}

struct RestChatApi: ChatApi {
    let rest: RestClient

    func getRoom(chatRoomId: Int64) async throws -> ChatRoomResponse {
        try await rest.call(ChatApiRoute.getRoom.route, path: ["chatRoomId": chatRoomId])
    }

    func getMyRooms() async throws -> [ChatRoomUserResponse] {
        try await rest.call(ChatApiRoute.getMyRooms.route)
    }

    func joinRoom(chatRoomId: Int64) async throws {
        try await rest.callUnit(ChatApiRoute.joinRoom.route, path: ["chatRoomId": chatRoomId])
    }

    func leaveRoom(chatRoomId: Int64) async throws {
        try await rest.callUnit(ChatApiRoute.leaveRoom.route, path: ["chatRoomId": chatRoomId])
    }

    func getMembers(chatRoomId: Int64) async throws -> [ChatMemberResponse] {
        try await rest.call(ChatApiRoute.getMembers.route, path: ["chatRoomId": chatRoomId])
    }

    func muteNotification(chatRoomId: Int64) async throws {
        try await rest.callUnit(ChatApiRoute.muteNotification.route, path: ["chatRoomId": chatRoomId])
    }

    func unmuteNotification(chatRoomId: Int64) async throws {
        try await rest.callUnit(ChatApiRoute.unmuteNotification.route, path: ["chatRoomId": chatRoomId])
    }

    func readRoom(chatRoomId: Int64, readMessageId: Int64) async throws {
        try await rest.callUnit(
            ChatApiRoute.readRoom.route,
            path: ["chatRoomId": chatRoomId, "readMessageId": readMessageId]
        )
    }

    func getMessages(chatRoomId: Int64, cursor: Int64?, size: Int) async throws -> ChatMessageSliceResponse {
        try await rest.call(
            ChatApiRoute.getMessages.route,
            path: ["chatRoomId": chatRoomId],
            query: ["cursor": cursor.map { String($0) }, "size": String(size)]
        )
    }

    func getMessagesAfter(chatRoomId: Int64, cursor: Int64, size: Int) async throws -> ChatMessageSliceResponse {
        try await rest.call(
            ChatApiRoute.getMessagesAfter.route,
            path: ["chatRoomId": chatRoomId],
            query: ["cursor": String(cursor), "size": String(size)]
        )
    }

    func sendMessage(chatRoomId: Int64, request: SendMessageRequestDto) async throws -> ChatMessageResponse {
        try await rest.call(ChatApiRoute.sendMessage.route, path: ["chatRoomId": chatRoomId], body: request)
    }

    func deleteMessage(chatRoomId: Int64, messageId: Int64) async throws {
        try await rest.callUnit(
            ChatApiRoute.deleteMessage.route,
            path: ["chatRoomId": chatRoomId, "messageId": messageId]
        )
    }

    func searchMessages(
        chatRoomId: Int64,
        keyword: String,
        cursor: Int64?,
        size: Int
    ) async throws -> ChatMessageSliceResponse {
        try await rest.call(
            ChatApiRoute.searchMessages.route,
            path: ["chatRoomId": chatRoomId],
            query: ["keyword": keyword, "cursor": cursor.map { String($0) }, "size": String(size)]
        )
    }

    func reportMessage(chatRoomId: Int64, request: ChatReportRequestDto) async throws {
        try await rest.callUnit(ChatApiRoute.reportMessage.route, path: ["chatRoomId": chatRoomId], body: request)
    }
}
