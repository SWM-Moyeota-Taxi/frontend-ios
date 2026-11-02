// GET /api/v1/dispatch/rides/{partyId}/{memberId}
// 백엔드 dispatch/application/dto/DriverLocationResponse(double longitude, double latitude)
// 원시 double 이라 항상 채워져 온다. 순서가 longitude 먼저인 점에 유의(이름 기반 역직렬화라 영향은 없다).
public struct DriverLocationResponse: Decodable, Equatable, Sendable {
    public var longitude: Double
    public var latitude: Double

    public init(longitude: Double = 0.0, latitude: Double = 0.0) {
        self.longitude = longitude
        self.latitude = latitude
    }

    private enum CodingKeys: String, CodingKey {
        case longitude, latitude
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        longitude = try c.decodeOrDefault(.longitude, default: 0.0)
        latitude = try c.decodeOrDefault(.latitude, default: 0.0)
    }
}
