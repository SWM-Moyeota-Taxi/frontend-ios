// 백엔드 report 도메인 record 와 필드 1:1 대응
// (report/application/dto/ReportRequest.java, ReportResponse.java, CallResultRequest.java)

/// POST /api/v1/reports 요청 본문 (백엔드 ReportRequest — 세 필드 모두 박싱 타입이라 null 허용).
/// 신고자는 Bearer 토큰에서 나온다(@CurrentUser) — reporterId 를 싣지 않는다.
/// 사유(reason) 필드는 서버에 없다 — 임의로 추가하지 말 것.
public struct ReportRequestDto: Codable, Equatable, Sendable {
    public var partyId: Int64?
    public var latitude: Double?
    public var longitude: Double?

    public init(partyId: Int64? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.partyId = partyId
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// POST /api/v1/reports 응답 (백엔드 ReportResponse)
public struct ReportResponse: Decodable, Equatable, Sendable {
    public var reportId: Int64

    public init(reportId: Int64) {
        self.reportId = reportId
    }
}

/// PATCH /api/v1/reports/call-result 요청 본문 (백엔드 CallResultRequest — @NotNull). 응답은 204(본문 없음).
public struct CallResultRequestDto: Codable, Equatable, Sendable {
    public var called: Bool

    public init(called: Bool) {
        self.called = called
    }
}
