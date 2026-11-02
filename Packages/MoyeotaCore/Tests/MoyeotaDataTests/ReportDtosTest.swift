import Foundation
import Testing
@testable import MoyeotaData

// 서버 스펙 기준: report/interfaces/ReportController.java + application/dto/*.java
// (ReportRequest{partyId,latitude,longitude} / ReportResponse{reportId} / CallResultRequest{called})
@Suite struct ReportDtosTest {

    @Test("신고 요청을 서버 필드명 그대로 직렬화한다")
    func encodesReportRequest() throws {
        let encoded = try encodeJSON(ReportRequestDto(partyId: 7, latitude: 37.5665, longitude: 126.9780))

        let obj = try parseJSONObject(encoded)
        #expect((obj["partyId"] as? NSNumber)?.int64Value == 7)
        #expect(isClose(37.5665, (obj["latitude"] as? NSNumber)?.doubleValue, 0.0001))
        #expect(isClose(126.9780, (obj["longitude"] as? NSNumber)?.doubleValue, 0.0001))
    }

    // partyId 는 화면에서 알 수 없으면 null — 기본값이라 본문에서 아예 빠진다.
    // 서버 ReportRequest 는 세 필드 모두 박싱 타입이라 누락을 그대로 받는다.
    @Test("partyId 가 null 이면 요청 본문에서 제외된다")
    func omitsNilPartyId() throws {
        let encoded = try encodeJSON(ReportRequestDto(partyId: nil, latitude: 37.5665, longitude: 126.9780))

        let obj = try parseJSONObject(encoded)
        #expect(obj["partyId"] == nil)
        #expect(obj["latitude"] != nil)
        #expect(obj["longitude"] != nil)
    }

    @Test("신고 응답 JSON 을 실제 서버 shape 그대로 역직렬화한다")
    func decodesReportResponse() throws {
        // 실서버 응답 기준 (2026-09-06 드라이버 세션 검증: 200 {"reportId":...})
        let decoded = try decodeJSON(ReportResponse.self, #"{"reportId":42}"#)

        #expect(decoded.reportId == 42)
    }

    @Test("통화 결과 요청을 서버 필드명 그대로 직렬화한다")
    func encodesCallResult() throws {
        let encodedTrue = try encodeJSON(CallResultRequestDto(called: true))
        let encodedFalse = try encodeJSON(CallResultRequestDto(called: false))

        #expect(try parseJSONObject(encodedTrue)["called"] as? Bool == true)
        // called=false 는 @NotNull 검증 대상이라 기본값 생략 없이 반드시 본문에 실려야 한다.
        #expect(try parseJSONObject(encodedFalse)["called"] as? Bool == false)
    }
}
