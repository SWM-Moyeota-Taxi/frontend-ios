import MoyeotaDomain

public final class RemoteAppConfigRepository: AppConfigRepository {
    private let api: any ConfigApi

    public init(api: any ConfigApi) {
        self.api = api
    }

    public func getConfig() async throws -> AppConfig {
        try await api.getConfig().toAppConfig()
    }
}
