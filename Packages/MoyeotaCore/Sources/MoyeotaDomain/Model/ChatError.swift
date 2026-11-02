import Foundation

/// 채팅 API 실패를 화면이 다룰 수 있는 형태로 좁힌 예외.
///
/// 채팅은 다른 도메인과 에러 본문 형식이 다르다 — `ChatExceptionHandler` 가
/// `ErrorResponse(code, message)` 를 내려주며 `code` 는 서버 `ChatErrorCode` 의 **enum 이름**이다
/// (`CHAT_NOT_PARTICIPANT` 처럼. 인증 쪽 `USER102` 같은 번호 코드가 아니다).
/// 검증 실패만 `INVALID_REQUEST` 로 온다.
///
/// 화면이 분기해야 하는 것은 `isNotParticipant`·`isRoomClosed` 처럼 **뜻을 가진 플래그**로만
/// 노출한다 — 문자열 비교가 화면으로 새어 나가면 서버가 코드 이름을 바꿀 때 조용히 어긋난다.
public struct ChatException: Throwable {
    /// 서버 `ChatErrorCode` 이름. 응답 본문이 없거나 파싱 실패면 null(그때는 `httpStatus` 만 근거).
    public let code: String?
    /// 서버가 준 한국어 원문 message. 없으면 null.
    public let serverMessage: String?
    /// HTTP 상태 코드. 네트워크 실패 등 응답 자체가 없으면 null.
    public let httpStatus: Int?
    /// 응답을 받지 못한 실패(연결 거부·타임아웃·DNS). 사용자에게는 재시도를 안내한다.
    public let isNetwork: Bool
    public let cause: (any Error)?

    public init(
        code: String?,
        serverMessage: String?,
        httpStatus: Int? = nil,
        isNetwork: Bool = false,
        cause: (any Error)? = nil
    ) {
        self.code = code
        self.serverMessage = serverMessage
        self.httpStatus = httpStatus
        self.isNetwork = isNetwork
        self.cause = cause
    }

    public var message: String? { serverMessage ?? code ?? "채팅 요청에 실패했습니다." }

    /// 403 `CHAT_NOT_PARTICIPANT` — 그 방의 참여자가 아니다(합류 전이거나 이미 나갔다).
    public var isNotParticipant: Bool {
        code == "CHAT_NOT_PARTICIPANT" || (code == nil && httpStatus == 403)
    }

    /// 409 `CHAT_ROOM_CLOSED` — 종료된 방이라 더 이상 읽기/쓰기가 안 된다.
    public var isRoomClosed: Bool {
        code == "CHAT_ROOM_CLOSED"
    }

    /// 404 `CHAT_ROOM_NOT_FOUND` — 방이 사라졌다(목록에서 제외해야 한다).
    public var isRoomNotFound: Bool {
        code == "CHAT_ROOM_NOT_FOUND" || (code == nil && httpStatus == 404)
    }

    /// 403 `CHAT_NOT_MESSAGE_OWNER` — 남의 메시지는 삭제할 수 없다.
    public var isNotMessageOwner: Bool {
        code == "CHAT_NOT_MESSAGE_OWNER"
    }

    /// 401 — 토큰이 없거나 만료됐다. 재발급까지 실패한 뒤에만 여기까지 올라온다.
    public var isUnauthorized: Bool {
        code == "CHAT_UNAUTHORIZED" || httpStatus == 401
    }

    // ─── 메시지 신고(POST /chat-rooms/{id}/reports) ───

    /// 409 `CHAT_ALREADY_REPORTED` — 같은 메시지를 이미 신고했다.
    ///
    /// **사유를 바꿔 다시 보내도 같은 409 다**(실측) — 중복 판정이 「신고자 + 메시지」 단위라
    /// 사유별로 따로 쌓이지 않는다. 그래서 화면은 이걸 **재시도할 수 있는 실패로 보여선 안 된다**:
    /// 사유를 다시 고르게 해 봐야 영원히 같은 답이 온다. 시트를 닫고 사실만 알린다.
    public var isAlreadyReported: Bool {
        code == "CHAT_ALREADY_REPORTED"
    }

    /// 400 `CHAT_CANNOT_REPORT_SELF` — 내가 보낸 메시지는 신고할 수 없다.
    ///
    /// UI 가 **내 말풍선에 신고 길을 아예 만들지 않는 것**이 1차 방어선이다
    /// (`ChatUiMessage.canReport`). 이 플래그는 그 방어선이 뚫렸을 때 원인을 말해 주기 위한 것이다
    /// — 없으면 서버 원문만 뜨고 왜 막혔는지가 화면 코드에서 사라진다.
    public var isCannotReportSelf: Bool {
        code == "CHAT_CANNOT_REPORT_SELF"
    }

    /// 400 `CHAT_REPORT_DESCRIPTION_REQUIRED` — 「기타」 사유인데 상세 내용이 비었다.
    /// 서버는 **공백만 있어도**(`isBlank`) 여기로 떨어뜨린다(실측).
    ///
    /// 이것도 UI 가 전송 버튼을 잠가 미리 막는다
    /// (`ChatReportReason.requiresDescription`).
    public var isReportDescriptionRequired: Bool {
        code == "CHAT_REPORT_DESCRIPTION_REQUIRED"
    }

    /// 404 `CHAT_MESSAGE_NOT_FOUND` — 신고 대상 메시지가 없다(지워졌거나 id 가 틀렸다).
    ///
    /// **`isRoomNotFound` 로는 안 잡힌다.** 그쪽은 `code == "CHAT_ROOM_NOT_FOUND"` 거나
    /// 「code 를 못 읽은 404」일 때만 참인데, 이 응답은 code 가 non-null 이고 값이 다르다 —
    /// 둘째 항도 안 걸려 **false** 가 된다. 플래그를 따로 두지 않으면 화면이 분기를 못 하고
    /// 서버 원문(「메시지가 존재하지 않습니다.」)만 띄운다.
    public var isMessageNotFound: Bool {
        code == "CHAT_MESSAGE_NOT_FOUND"
    }

    /// 400 `INVALID_REQUEST` — Bean Validation 실패. 채팅 도메인 코드가 아니라 **공통 코드**다
    /// (`CHAT_` 접두사가 없다).
    ///
    /// 서버 message 가 필드명을 그대로 담으므로(「chatMessageId: 메시지 ID는 1 이상이어야 합니다」)
    /// **사용자에게 그대로 보여 주면 안 된다** — 화면이 자기 문구로 갈아 끼운다.
    public var isInvalidRequest: Bool {
        code == "INVALID_REQUEST"
    }
}
