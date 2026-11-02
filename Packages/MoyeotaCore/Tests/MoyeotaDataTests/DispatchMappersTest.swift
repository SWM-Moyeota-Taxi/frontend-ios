import Testing
@testable import MoyeotaData

@Suite struct DispatchMappersTest {

    @Test("서버가 longitude 를 먼저 주지만 도메인은 위도 경도를 이름으로 구분한다")
    func decodesByName() throws {
        // DriverLocationResponse(double longitude, double latitude) — 순서가 뒤바뀐 함정.
        let decoded = try decodeJSON(
            DriverLocationResponse.self,
            #"{"longitude":126.9780,"latitude":37.5665}"#
        )

        let location = decoded.toDriverLocation()

        #expect(isClose(37.5665, location.latitude, 0.000001))
        #expect(isClose(126.9780, location.longitude, 0.000001))
    }

    @Test("Repository 가 API 응답을 그대로 도메인 위치로 넘긴다")
    func repositoryPassesLocation() async throws {
        let api = FakeDispatchApi(DriverLocationResponse(longitude: 127.0276, latitude: 37.4979))

        let location = try await RemoteDispatchRepository(api: api).getDriverLocation(partyId: 7)

        #expect(isClose(37.4979, location.latitude, 0.000001))
        #expect(isClose(127.0276, location.longitude, 0.000001))
        // memberId 는 더 이상 넘기지 않는다 — 서버가 Bearer 토큰에서 뽑는다(@LoginUser).
        #expect(api.lastPartyId.value == 7)
    }

    private final class FakeDispatchApi: DispatchApi {
        private let response: DriverLocationResponse
        let lastPartyId = Locked<Int64?>(nil)

        init(_ response: DriverLocationResponse) {
            self.response = response
        }

        func getDriverLocation(partyId: Int64) async throws -> DriverLocationResponse {
            lastPartyId.value = partyId
            return response
        }
    }
}
