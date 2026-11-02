/// 서버 운영 설정. `AppConfigController` — permitAll 이라 **토큰 없는 클라이언트**로 부른다
/// (인증 클라이언트로 불러도 되지만, 만료 토큰이 붙으면 401 재발급이 끼어들어 앱 시작이 늦어진다).
public protocol ConfigApi: Sendable {
    func getConfig() async throws -> AppConfigResponse
}

enum ConfigApiRoute: String, CaseIterable, ApiRouteSet {
    case getConfig

    var route: ApiRoute {
        switch self {
        case .getConfig: .GET("api/v1/config")
        }
    }
}

struct RestConfigApi: ConfigApi {
    let rest: RestClient

    func getConfig() async throws -> AppConfigResponse {
        try await rest.call(ConfigApiRoute.getConfig.route)
    }
}
