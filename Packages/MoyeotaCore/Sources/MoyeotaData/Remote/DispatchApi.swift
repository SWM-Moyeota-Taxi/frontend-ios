// 경로 기준: feature/driver-report dispatch/interfaces/RideController.java
// (@RequestMapping("/api/v1/dispatch"))
//
// 승객 앱이 쓰는 건 위치 조회 하나뿐이다. arrive/board/complete 와 콜 수락·거절, 기사 위치 보고는
// 기사 앱 전용이라 선언하지 않는다.
public protocol DispatchApi: Sendable {
    /// 조회 주체는 Bearer 토큰에서 나온다
    /// (`RideController.getLocation(@PathVariable Long partyId, @CurrentUser Long memberId)`).
    /// 토큰 없이 호출하면 401 `{"code":"USER005","message":"로그인이 필요합니다."}`.
    func getDriverLocation(partyId: Int64) async throws -> DriverLocationResponse
}

enum DispatchApiRoute: String, CaseIterable, ApiRouteSet {
    case getDriverLocation

    var route: ApiRoute {
        switch self {
        case .getDriverLocation: .GET("api/v1/dispatch/rides/{partyId}")
        }
    }
}

struct RestDispatchApi: DispatchApi {
    let rest: RestClient

    func getDriverLocation(partyId: Int64) async throws -> DriverLocationResponse {
        try await rest.call(DispatchApiRoute.getDriverLocation.route, path: ["partyId": partyId])
    }
}
