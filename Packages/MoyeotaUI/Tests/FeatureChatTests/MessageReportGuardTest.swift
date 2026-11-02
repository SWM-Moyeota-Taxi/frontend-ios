import MoyeotaDomain
import Testing
@testable import FeatureChat

/// 24 채팅방 메시지 신고에서 **화면이 미리 막아야 하는 것**과 **실패를 어떻게 읽는지**를 못 박는다.
///
/// 왜 화면이 미리 막는가: 서버가 거절하는 조건 넷(본인 메시지 · id 없음 · 「기타」인데 상세 없음 ·
/// 상세 500자 초과)은 **누르기 전부터 전부 알 수 있다.** 왕복해서 받으면 사용자는 사유를 고르고
/// 글까지 쓴 끝에 거절당하는데, 서버 문구는 「chatMessageId: 메시지 ID는 1 이상이어야 합니다」처럼
/// 보여 줄 수 없는 말이다(실측 2026-11-01, 로컬 :8080).
@Suite struct MessageReportGuardTest {

    private func peer(_ id: Int64) -> ChatUiMessage {
        ChatUiMessage(text: "본문", isMine: false, id: id)
    }

    // ─── 신고 길을 만들어도 되는가 ───

    /// 내 메시지에는 신고 길을 **만들지 않는다.**
    ///
    /// 안 막으면 서버 400 `CHAT_CANNOT_REPORT_SELF` 를 왕복해서 받는다. 그보다 나쁜 것은
    /// 「자기 자신을 신고하는 경로가 화면에 있다」는 사실 자체다 — 눌러 보고서야 안 된다는 걸 안다.
    @Test("내 메시지에는 신고 길을 만들지 않는다")
    func myMessageHasNoReportPath() {
        #expect(!ChatUiMessage(text: "내 말", isMine: true, id: 42).canReport())
        #expect(peer(42).canReport())
    }

    /// 서버 id 가 없는 말풍선도 신고할 수 없다.
    ///
    /// 전송 확인을 기다리는 내 메시지(`PendingMessage`)가 그렇다. 그 자리에 0 이
    /// 들어가는데, 0 을 보내면 서버가 400 `INVALID_REQUEST` 를 낸다 — 즉 화면의 하한
    /// (`ChatReportReason.MIN_MESSAGE_ID`)이 서버의 `@Positive` 와 **같은 기준**이다.
    @Test("서버 id 가 없는 말풍선은 신고할 수 없다")
    func noServerIdCannotReport() {
        #expect(!peer(NO_SERVER_MESSAGE_ID).canReport())
        #expect(!peer(-3).canReport(), "음수 id 가 통과한다")
        #expect(peer(ChatReportReason.MIN_MESSAGE_ID).canReport())
    }

    // ─── 사유 시트 ───

    /// 사유 줄은 **서버 enum 을 하나도 빠뜨리지 않는다.**
    ///
    /// 빠뜨리면 그 사유로는 신고할 길이 없어 사용자가 「그 밖의 이유예요」로 뭉개 적는다. 서버가
    /// `chat_report` 에 사유를 저장하고 피신고자 인덱스를 걸어 둔 건 분류로 조치하려는 설계인데,
    /// 전부 ETC 로 들어가면 그 설계가 무력해진다.
    @Test("사유 줄은 서버 enum 을 하나도 빠뜨리지 않는다")
    func reasonRowsCoverEnum() {
        #expect(ChatReportReason.allCases == chatReportReasonLabels.map(\.0))
        for (reason, label) in chatReportReasonLabels {
            #expect(!label.isBlank, "\(reason) 의 문구가 비었다")
        }
    }

    /// 사유를 고르기 전에는 보낼 수 없다 — 서버는 「신고 사유는 필수입니다」로 400 을 낸다.
    @Test("사유를 고르지 않으면 보낼 수 없다")
    func noReasonCannotSubmit() {
        #expect(!chatReportSubmitUi(reason: nil, description: "").submitEnabled)
    }

    /// 「기타」가 아닌 사유는 상세 없이 보낼 수 있다 — 생략해도 201 이다(실측).
    @Test("기타가 아닌 사유는 상세 없이 보낼 수 있다")
    func nonEtcSubmitsWithoutDescription() {
        for reason in ChatReportReason.allCases where !reason.requiresDescription {
            #expect(chatReportSubmitUi(reason: reason, description: "").submitEnabled, "\(reason) 가 상세 없이 잠겨 있다")
        }
    }

    /// 「기타」는 상세 내용 없이 보낼 수 없다. **공백만 적어도 마찬가지**다 —
    /// 서버가 `isBlank` 로 보고 400 `CHAT_REPORT_DESCRIPTION_REQUIRED` 를 낸다(실측).
    ///
    /// 공백을 허용하면 「썼는데 입력하라고 한다」가 된다. 잠그는 쪽이 설명 가능하다.
    @Test("기타 사유는 상세 내용 없이 전송할 수 없다")
    func etcRequiresDescription() {
        #expect(ChatReportReason.etc.requiresDescription)
        #expect(!chatReportSubmitUi(reason: .etc, description: "").submitEnabled)
        #expect(!chatReportSubmitUi(reason: .etc, description: "   \n\t ").submitEnabled)
        #expect(chatReportSubmitUi(reason: .etc, description: "같은 말을 반복해요").submitEnabled)
    }

    /// 상세는 500자까지다. **자르지 않고 카운터로 알린다** — 이 화면의 입력창이 세운 규칙과 같다
    /// (잘라 버리면 넘겼다는 사실을 말해 줄 기회가 사라진다). 넘긴 상태에서는 잠긴다.
    @Test("상세 내용은 500자를 넘길 수 없다")
    func descriptionLimit() {
        let atLimit = String(repeating: "가", count: ChatReportReason.MAX_DESCRIPTION_LENGTH)
        let over = atLimit + "가"

        #expect(chatReportSubmitUi(reason: .etc, description: atLimit).submitEnabled)
        let ui = chatReportSubmitUi(reason: .etc, description: over)
        #expect(ui.overLimit)
        #expect(!ui.submitEnabled)
        #expect((ui.counter ?? "").contains("줄여야"), "넘긴 이유를 말하지 않는다")
    }

    /// **카운터는 잠김보다 먼저 뜬다.** 한도에서야 나타나면 ① 경고가 아니라 사후 통보가 되고
    /// ② 카운터 줄이 생기면서 버튼이 움직이는 그 프레임에 버튼이 잠긴다. 입력창 쪽
    /// `COUNTER_VISIBLE_FROM` 과 같은 근거다.
    @Test("카운터는 잠기기 전에 먼저 나타난다")
    func counterPrecedesLock() {
        #expect(REPORT_COUNTER_VISIBLE_FROM < ChatReportReason.MAX_DESCRIPTION_LENGTH)

        // 평상시(짧게 적는 중)에는 줄을 그리지 않는다 — 의미 없는 숫자가 시트 높이를 빼앗는다.
        #expect(chatReportSubmitUi(reason: .etc, description: "짧게").counter == nil)
        // 한도에 가까워지면 뜨고, 아직 잠기지는 않는다.
        let ui = chatReportSubmitUi(
            reason: .etc,
            description: String(repeating: "가", count: REPORT_COUNTER_VISIBLE_FROM)
        )
        #expect(!ui.overLimit)
        #expect(ui.submitEnabled)
        #expect(!(ui.counter ?? "").isBlank)
    }

    /// 보내는 중에는 다시 누를 수 없다 — 같은 신고를 두 번 보내면 둘째는 409 다.
    @Test("보내는 중에는 다시 누를 수 없다")
    func lockedWhileSubmitting() {
        #expect(!chatReportSubmitUi(reason: .abuse, description: "", submitting: true).submitEnabled)
    }

    // ─── 실패를 어떻게 읽는가 ───

    private func chat(_ code: String, _ status: Int, network: Bool = false) -> ChatException {
        ChatException(
            code: code.isEmpty ? nil : code,
            serverMessage: nil,
            httpStatus: status,
            isNetwork: network
        )
    }

    /// 「이미 신고한 메시지」는 **재시도로 열어 두지 않는다.**
    ///
    /// 사유를 바꿔 보내도 같은 409 다(중복 판정이 「신고자 + 메시지」 단위 — 실측). 시트를 열어
    /// 두면 사용자가 다섯 사유를 돌아가며 눌러도 전부 거절되는 곳에 갇힌다.
    @Test("이미 신고한 메시지는 재시도하지 않는다")
    func alreadyReportedIsNotRetryable() {
        let outcome = chat("CHAT_ALREADY_REPORTED", 409).toChatReportOutcome()

        #expect(!outcome.accepted)
        #expect(!outcome.retryable, "시트를 열어 두고 재시도를 유도한다")
        #expect(outcome.message.contains("이미 신고"))
    }

    /// 연결 실패**만** 시트를 열어 둔다 — 적어 둔 상세 수백 자를 한 번 끊긴 연결 때문에 버리게
    /// 하지 않는다. 반대로 「대상이 틀렸다」류(참여자 아님·메시지 없음·본인)는 다시 눌러도 같은
    /// 답이라 닫는다.
    @Test("연결 실패만 시트를 열어 둔다")
    func onlyNetworkFailureKeepsSheet() {
        // 저장소가 응답을 못 받은 실패를 이 모양으로 올려 준다(ChatMappers.toChatException).
        let offline = ChatException(code: nil, serverMessage: nil, isNetwork: true)
        #expect(offline.toChatReportOutcome().retryable)

        for error in [
            chat("CHAT_NOT_PARTICIPANT", 403),
            chat("CHAT_MESSAGE_NOT_FOUND", 404),
            chat("CHAT_CANNOT_REPORT_SELF", 400),
        ] {
            let outcome = error.toChatReportOutcome()
            #expect(!outcome.retryable, "\(error.code ?? "") 를 재시도로 읽고 있다")
            #expect(!outcome.accepted)
        }
    }

    /// 서버 원문을 **그대로 보여 주지 않는다.** `INVALID_REQUEST` 의 message 는 필드명을 담고
    /// 있어(「chatMessageId: 메시지 ID는 1 이상이어야 합니다」) 사용자에게 흘리면 안 된다.
    @Test("검증 실패 문구에 서버 필드명을 흘리지 않는다")
    func validationFailureHidesFieldName() {
        let error = ChatException(
            code: "INVALID_REQUEST",
            serverMessage: "chatMessageId: 메시지 ID는 1 이상이어야 합니다",
            httpStatus: 400
        )

        let outcome = error.toChatReportOutcome()
        #expect(!outcome.message.contains("chatMessageId"))
        #expect(!outcome.accepted)
    }

    /// 매핑에 없는 실패(5xx·401 등)는 다음에 될 수 있는 것으로 본다 — 입력을 버리지 않는다.
    @Test("모르는 실패는 다시 시도할 수 있는 것으로 둔다")
    func unknownFailureIsRetryable() {
        let outcome = chat("", 500).toChatReportOutcome()

        #expect(outcome.retryable)
        #expect(!outcome.accepted)
    }
}
