// 경로 기준: report/interfaces/ReportController.java (@RequestMapping("/api/v1/reports")).
// 두 엔드포인트 모두 @CurrentUser — 신고자는 Bearer 토큰이 정한다(apiClient 로 생성해야 한다).
// call-result 는 백엔드가 {reportId} 경로를 오간 이력이 있다 — 현행 컨트롤러는 reportId 없이
// 토큰 주체의 최근 신고에 기록한다 (AuthenticatedPathContractTest 가 경로를 못 박는다).
public protocol ReportApi: Sendable {
    /// 긴급 신고 저장. 200 {reportId}
    func report(request: ReportRequestDto) async throws -> ReportResponse

    /// 112 통화 여부 저장. 204 No Content — 응답 본문 없음
    func confirmCallResult(request: CallResultRequestDto) async throws
}

enum ReportApiRoute: String, CaseIterable, ApiRouteSet {
    case report, confirmCallResult

    var route: ApiRoute {
        switch self {
        case .report: .POST("api/v1/reports")
        case .confirmCallResult: .PATCH("api/v1/reports/call-result")
        }
    }
}

struct RestReportApi: ReportApi {
    let rest: RestClient

    func report(request: ReportRequestDto) async throws -> ReportResponse {
        try await rest.call(ReportApiRoute.report.route, body: request)
    }

    func confirmCallResult(request: CallResultRequestDto) async throws {
        try await rest.callUnit(ReportApiRoute.confirmCallResult.route, body: request)
    }
}
