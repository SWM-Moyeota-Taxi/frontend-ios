import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 메시지 신고가 내는 실패 **본문 전문**을 실측한 그대로 넣고, `ChatException` 의 플래그가 그걸
/// 제대로 읽는지 못 박는다. 전부 실측(2026-11-01, 로컬 :8080)에서 복사한 응답이다.
///
/// 플래그 하나가 비면 화면은 **아무 분기도 못 하고 서버 원문만 띄운다.** 신고에서 그게 특히
/// 나쁜 이유: 「이미 신고한 메시지입니다.」를 재시도 가능한 실패처럼 보여 주면 사용자가 사유를
/// 바꿔 가며 계속 눌러도 **영원히 같은 409** 가 온다(중복 판정이 「신고자 + 메시지」라 사유별로
/// 나뉘지 않는다 — 실측).
///
/// 테스트가 변환 함수(`toChatException`)를 거치게 한 것도 의도다. 플래그만 직접 만들어 보면
/// 「본문 파싱이 code 를 못 읽는」 경우를 한 건도 못 잡는다.
@Suite struct ChatReportErrorTest {

    private func chatError(_ status: Int, _ body: String) -> ChatException {
        HttpException(Response<Void>.error(status, body)).toChatException()
    }

    @Test("409 CHAT_ALREADY_REPORTED 는 중복 신고로 읽는다")
    func alreadyReported() {
        let error = chatError(409, #"{"code":"CHAT_ALREADY_REPORTED","message":"이미 신고한 메시지입니다."}"#)

        #expect(error.isAlreadyReported)
        #expect(error.httpStatus == 409)
        // 같은 409 인 「종료된 방」과 섞이면 「채팅방이 종료됐어요」가 뜬다 — 상태 코드만으로는 못 가린다.
        #expect(!error.isRoomClosed)
    }

    @Test("400 CHAT_CANNOT_REPORT_SELF 는 본인 신고로 읽는다")
    func cannotReportSelf() {
        let error = chatError(400, #"{"code":"CHAT_CANNOT_REPORT_SELF","message":"본인이 보낸 메시지는 신고할 수 없습니다."}"#)

        #expect(error.isCannotReportSelf)
        // 공통 검증 실패와 다른 것이다 — 이쪽은 채팅 도메인 코드다.
        #expect(!error.isInvalidRequest)
    }

    @Test("400 CHAT_REPORT_DESCRIPTION_REQUIRED 는 상세 누락으로 읽는다")
    func descriptionRequired() {
        let error = chatError(
            400,
            #"{"code":"CHAT_REPORT_DESCRIPTION_REQUIRED","message":"기타 사유는 상세 내용을 입력해야 합니다."}"#
        )

        #expect(error.isReportDescriptionRequired)
    }

    /// **이게 이 파일의 핵심이다.** 신고 대상 메시지가 없을 때 오는 404 는
    /// `ChatException.isRoomNotFound` 로 **안 잡힌다** — 그쪽은 `CHAT_ROOM_NOT_FOUND` 거나
    /// 「code 를 못 읽은 404」일 때만 참인데, 이 응답은 code 가 non-null 이고 값이 다르다.
    ///
    /// 전용 플래그 없이 「404 면 방이 없다」로 묶으면 지워진 메시지를 신고했을 때
    /// 「채팅방이 사라졌어요」가 뜨고, 화면이 방 목록에서 멀쩡한 방을 지우려 들 수 있다.
    @Test("404 CHAT_MESSAGE_NOT_FOUND 는 방 없음이 아니라 메시지 없음이다")
    func messageNotFound() {
        let error = chatError(404, #"{"code":"CHAT_MESSAGE_NOT_FOUND","message":"메시지가 존재하지 않습니다."}"#)

        #expect(error.isMessageNotFound)
        #expect(!error.isRoomNotFound, "메시지 없음을 방 없음으로 읽고 있다")
    }

    /// 없는 방에 신고하면 **404 가 아니라 403** 이다(실측) — 서버가 방 존재 여부보다 참여 여부를
    /// 먼저 본다. 그래서 기존 `ChatException.isNotParticipant` 로 그대로 잡힌다.
    @Test("없는 방 신고는 403 참여자 아님으로 온다")
    func missingRoomIsNotParticipant() {
        let error = chatError(403, #"{"code":"CHAT_NOT_PARTICIPANT","message":"채팅방 참여자가 아닙니다."}"#)

        #expect(error.isNotParticipant)
        #expect(!error.isRoomNotFound)
    }

    /// Bean Validation 실패만 공통 코드 `INVALID_REQUEST` 로 온다(`CHAT_` 접두사가 없다).
    ///
    /// 서버 message 가 **필드명을 그대로 담는다** — 「chatMessageId: 메시지 ID는 1 이상이어야
    /// 합니다」. 이걸 사용자에게 흘리지 않는 것이 화면 쪽 규칙이고, 그 분기의 근거가 이 플래그다.
    @Test("400 INVALID_REQUEST 는 공통 검증 실패로 읽는다")
    func invalidRequest() {
        let error = chatError(
            400,
            #"{"code":"INVALID_REQUEST","message":"chatMessageId: 메시지 ID는 1 이상이어야 합니다"}"#
        )

        #expect(error.isInvalidRequest)
        #expect(!error.isCannotReportSelf)
        #expect(!error.isReportDescriptionRequired)
    }

    /// 신고 쪽 플래그가 **다른 403 코드를 삼키지 않는지**도 본다. 위치 공유는 같은 「권한 없음」을
    /// `CHAT_NOT_PARTY_MEMBER`(파티 멤버 아님)로 내는데, 신고의 `CHAT_NOT_PARTICIPANT`(채팅방
    /// 참여자 아님)와 **기준이 다르다**: 신고는 종료된 파티의 방에서도 201 이고(실측) 위치 공유는
    /// 403 이다. 두 코드를 한 플래그로 묶으면 「방은 살아 있는데 참여자가 아니라고 한다」가 된다.
    @Test("CHAT_NOT_PARTY_MEMBER 는 채팅방 참여자 아님이 아니다")
    func notPartyMemberIsDifferent() {
        let error = chatError(403, #"{"code":"CHAT_NOT_PARTY_MEMBER","message":"파티 참여자가 아닙니다."}"#)

        #expect(error.code == "CHAT_NOT_PARTY_MEMBER")
        #expect(!error.isNotParticipant, "다른 뜻의 403 을 참여자 아님으로 읽고 있다")
    }
}
