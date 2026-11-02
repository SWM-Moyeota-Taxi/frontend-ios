/// 채팅 메시지 신고 사유 — 서버 `ReportReasonType` 과 1:1.
///
/// 값이 틀리면 404 가 아니라 **400** 이다(소문자도 거절된다 — 실측). 그래서 enum 을 직렬화에
/// 맡기지 않고 매퍼가 `name` 을 그대로 문자열로 넣는다
/// (`ChatReportRequestDto` 주석). 화면 문구는 여기 적지 않는다 —
/// 서버 enum 의 뜻(주석)과 사용자에게 보여 줄 말은 길이도 말투도 다르다.
public enum ChatReportReason: String, CaseIterable, Sendable {
    /// 욕설, 비방, 혐오 표현
    case abuse = "ABUSE"

    /// 광고, 도배
    case spam = "SPAM"

    /// 사기, 금전 요구
    case fraud = "FRAUD"

    /// 성적 불쾌감
    case sexual = "SEXUAL"

    /// 기타 — 상세 내용이 **필수**다(`requiresDescription`)
    case etc = "ETC"

    /// Kotlin `enum.name` — 원본 상수 이름 그대로.
    public var name: String { rawValue }

    /// 상세 내용이 **반드시 있어야** 하는 사유인가. `etc` 만 참이다.
    ///
    /// 서버는 상세가 없거나 **공백만 있으면**(`isBlank`) 400 `CHAT_REPORT_DESCRIPTION_REQUIRED` 를
    /// 낸다 — 실측. 화면이 이 값으로 전송 버튼을 미리 잠가야 한다. 안 잠그면 사용자가 「신고하기」를
    /// 누르고 왕복을 기다린 끝에 거절당하는데, 그 이유는 **누르기 전부터 알 수 있던 것**이다.
    public var requiresDescription: Bool { self == .etc }

    /// 서버가 받는 상세 내용 최대 길이(`@Size(max = 500)`). 넘기면 400 `INVALID_REQUEST` 다.
    ///
    /// 화면은 입력을 **자르지 않고** 카운터로 알린다 — 잘라 버리면 넘겼다는 사실을 말해 줄
    /// 기회가 사라진다(채팅 입력창이 같은 판단을 한다: `COUNTER_VISIBLE_FROM` 주석).
    public static let MAX_DESCRIPTION_LENGTH = 500

    /// 신고할 수 있는 메시지 id 의 최솟값(서버 `@Positive`). 0 이면 400 `INVALID_REQUEST` 다.
    ///
    /// 화면 모델이 서버 id 를 아직 모르는 말풍선(전송 확인을 기다리는 내 메시지)을 0 으로
    /// 들고 있어서, 이 값이 「신고할 수 있는 메시지인가」의 하한이 된다.
    public static let MIN_MESSAGE_ID: Int64 = 1
}
