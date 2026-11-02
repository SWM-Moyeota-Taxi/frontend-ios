import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 서버 스펙 기준: `chat/report/presentation/ChatReportController.java` +
/// `chat/report/dto/ChatReportRequest.java`(`chatMessageId` `@NotNull @Positive` ·
/// `reason` `@NotNull` · `description` `@Size(max = 500)`).
///
/// 이 계층의 실수는 **컴파일러가 못 잡고 400 으로만 드러난다** — 필드명이 틀리면 서버가
/// 「요청 본문이 없거나 형식이 잘못되었습니다」를 내는데, 그 문구는 네트워크 문제처럼 읽힌다.
/// 실측(2026-11-01, 로컬 :8080)으로 확인한 계약을 값으로 고정한다.
@Suite struct ChatReportDtosTest {

    private func encode(_ dto: ChatReportRequestDto) throws -> [String: Any] {
        try parseJSONObject(try encodeJSON(dto))
    }

    /// 필드명 3개와 **사유가 대문자**인 것을 함께 못 박는다.
    ///
    /// 소문자 `abuse` 를 보내면 서버가 400 「요청 본문이 없거나 형식이 잘못되었습니다」로 거절한다
    /// (실측) — 즉 사유가 틀렸다는 말을 **한 마디도 해 주지 않는다.** 그래서 대문자 보장을 여기서
    /// 잡아야 하고, 그 보장은 `RemoteChatRepository` 가 `ChatReportReason.name` 을 명시적으로
    /// 넣는 데서 나온다.
    @Test("신고 요청을 서버 필드명 그대로 직렬화한다")
    func encodesRequest() throws {
        let obj = try encode(ChatReportRequestDto(chatMessageId: 4, reason: ChatReportReason.abuse.name))

        #expect((obj["chatMessageId"] as? NSNumber)?.int64Value == 4)
        #expect(obj["reason"] as? String == "ABUSE")
    }

    /// 사유 5개의 **문자열 값**을 서버 enum 이름과 1:1로 고정한다.
    ///
    /// 값이 하나라도 어긋나면 그 사유로 신고한 사용자만 400 을 받는데, 다섯 중 하나라 QA 에서
    /// 놓치기 쉽다. 전부 실측으로 201 을 확인한 값이다(ETC 는 상세를 함께 보내 201).
    @Test("사유 다섯 개가 서버 enum 이름과 같다")
    func reasonNames() {
        #expect(ChatReportReason.allCases.map(\.name) == ["ABUSE", "SPAM", "FRAUD", "SEXUAL", "ETC"])
    }

    /// 상세가 없으면 **키 자체가 본문에서 빠진다**(합성 `Encodable` 의 `encodeIfPresent`).
    ///
    /// 서버 엔티티에 `@Column(nullable = false)` 가 붙어 있어 「빈 문자열이라도 넣어야 통과한다」고
    /// 판단하기 쉬운 자리인데, 마이그레이션 쪽이 nullable 이라 **생략해도 201 이다**(실측).
    /// 반대로 빈 문자열을 넣으면 「기타」에서 서버 `isBlank` 검사에 걸려 400 이 된다 —
    /// 즉 생략이 맞는 선택이다.
    @Test("상세 내용이 없으면 요청 본문에서 제외된다")
    func omitsNilDescription() throws {
        let obj = try encode(ChatReportRequestDto(chatMessageId: 4, reason: "ABUSE", description: nil))

        #expect(obj["description"] == nil, "description 키가 본문에 남아 있다")
        #expect(obj["chatMessageId"] != nil)
        #expect(obj["reason"] != nil)
    }

    /// 상세를 적었으면 그대로 싣는다 — 「기타」 사유의 유일한 필수 입력이다.
    @Test("상세 내용이 있으면 그대로 싣는다")
    func keepsDescription() throws {
        let obj = try encode(
            ChatReportRequestDto(chatMessageId: 10, reason: "ETC", description: "기타 사유 설명")
        )

        #expect(obj["description"] as? String == "기타 사유 설명")
    }

    /// 서버 한도는 **500자**다(`@Size(max = 500)`). 501자를 보내면 400 `INVALID_REQUEST`
    /// 「상세 내용은 500자를 넘을 수 없습니다」(실측), 500자는 통과한다.
    ///
    /// 이 숫자가 도메인 상수와 어긋나면 화면 카운터가 거짓말을 한다 — 「499/500자」인데 서버가
    /// 거절하거나, 반대로 보낼 수 있는데 버튼이 잠긴다.
    @Test("상세 내용 한도는 서버와 같은 500 자다")
    func descriptionLimit() {
        #expect(ChatReportReason.MAX_DESCRIPTION_LENGTH == 500)
    }

    /// 서버가 `@Positive` 로 받는다 — 0 은 400 「메시지 ID는 1 이상이어야 합니다」(실측).
    @Test("신고할 수 있는 메시지 id 하한은 1 이다")
    func minMessageId() {
        #expect(ChatReportReason.MIN_MESSAGE_ID == 1)
    }
}
