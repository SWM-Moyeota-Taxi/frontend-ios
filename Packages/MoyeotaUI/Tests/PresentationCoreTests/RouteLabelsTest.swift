import MoyeotaDomain
import Testing
@testable import PresentationCore

@Suite struct RouteLabelsTest {
    @Test("요약 칩 - 있는 값만 잇고 둘 다 없으면 nil 이다")
    func chipLabel() {
        #expect(buildRouteChipLabel(estimatedMinutes: 12, routeKm: 6.2) == "예상 12분 · 6.2km")
        #expect(buildRouteChipLabel(estimatedMinutes: 12, routeKm: nil) == "예상 12분")
        #expect(buildRouteChipLabel(estimatedMinutes: nil, routeKm: 6.2) == "6.2km")
        #expect(buildRouteChipLabel(estimatedMinutes: nil, routeKm: nil) == nil)
    }

    @Test("탑승 거리 - 1km 미만은 10m 단위로 내리고 이상은 소수 1자리다")
    func pickupLabel() {
        #expect(pickupDistanceLabel(meters: 0) == "약 0m")
        #expect(pickupDistanceLabel(meters: 87) == "약 80m")
        #expect(pickupDistanceLabel(meters: 999.9) == "약 990m")
        #expect(pickupDistanceLabel(meters: 1_000) == "약 1.0km")
        #expect(pickupDistanceLabel(meters: 2_345) == "약 2.3km")
    }

    /// Java `Formatter` 는 최단 십진 표기에서 HALF_UP 으로 반올림한다. C 의 `%.1f` 라면 1.1 이 되는 값이다.
    @Test("소수 1자리 표기는 Java Formatter 와 같게 반올림한다")
    func oneDecimalMatchesJava() {
        #expect(formatOneDecimal(1.15) == "1.2")
        #expect(formatOneDecimal(0.25) == "0.3")
        #expect(formatOneDecimal(6.2) == "6.2")
        #expect(formatOneDecimal(6.0) == "6.0")
        #expect(formatOneDecimal(0) == "0.0")
        #expect(formatOneDecimal(-0.04) == "-0.0")
        #expect(formatOneDecimal(1234.56) == "1234.6")
    }

    @Test("탑승 거리 - 못 쓸 좌표면 nil 이다")
    func pickupMeters() throws {
        var ride = Ride(
            id: "1", origin: "a", destination: "b", departureLabel: "c",
            capacity: 2, members: [], farePerPerson: 0, totalFare: 0, status: .recruiting,
            originLat: 37.5, originLng: 127.0
        )
        let near = UserCoordinates(latitude: 37.5, longitude: 127.0)
        #expect(pickupDistanceMeters(ride: ride, myLocation: near) == 0)
        #expect(pickupDistanceMeters(ride: ride, myLocation: nil) == nil)
        // 서버가 위경도를 뒤바꿔 준 결함(QA D-1) — 위도 127 은 지구상에 없다.
        ride.originLat = 127.0
        ride.originLng = 37.5
        #expect(pickupDistanceMeters(ride: ride, myLocation: near) == nil)
    }
}
