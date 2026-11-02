import MoyeotaDomain

public final class RemoteDispatchRepository: DispatchRepository {
    private let api: any DispatchApi

    public init(api: any DispatchApi) {
        self.api = api
    }

    public func getDriverLocation(partyId: Int64) async throws -> DriverLocation {
        try await api.getDriverLocation(partyId: partyId).toDriverLocation()
    }
}
