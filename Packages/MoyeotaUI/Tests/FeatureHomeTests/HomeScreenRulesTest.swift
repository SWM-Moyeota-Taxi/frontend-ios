import MoyeotaDomain
import PresentationCore
import Testing
@testable import FeatureHome

/// 원본에는 없는 테스트. 원본이 `@Preview` 로만 확인하던 HomeRoute·HomeScreen 의 순수 규칙을 못 박는다.
@Suite struct HomeScreenRulesTest {

    private func place(name: String = "집", roadName: String = "도로명", latitude: Double, longitude: Double) -> FavoritePlace {
        FavoritePlace(id: 1, name: name, roadName: roadName, latitude: latitude, longitude: longitude, sequence: 1)
    }

    @Test("이름이 없으면 인사말에서 이름 자리를 뺀다")
    func greeting() {
        #expect(homeGreeting(userName: "민준") == "민준님, 반가워요")
        #expect(homeGreeting(userName: nil) == "반가워요")
    }

    @Test("도로명이 비면 장소 이름으로 검색한다")
    func queryFallsBackToName() {
        let spot = { (road: String) in FavoritePlace(id: 1, name: "부산대역", roadName: road, latitude: 35, longitude: 129, sequence: 1) }
        #expect(favoritePlaceQuery(spot("부산 금정구 부산대학로 63번길 2")) == "부산 금정구 부산대학로 63번길 2")
        #expect(favoritePlaceQuery(spot("")) == "부산대역")
        #expect(favoritePlaceQuery(spot("  ")) == "부산대역")
    }

    /// 기대값은 원본 `Location.distanceBetween` 의 계산식(WGS84 Vincenty)을 그대로 돌려 얻었다: 8518.85m, 480.41m.
    @Test("거리 라벨은 원본 계산과 같은 값을 낸다")
    func distanceMatchesAndroid() {
        let me = UserCoordinates(latitude: 35.2316, longitude: 129.0846)
        #expect(distanceLabel(from: me, place: place(latitude: 35.1577, longitude: 129.0592)) == "8.5km")
        #expect(distanceLabel(from: me, place: place(latitude: 35.2334, longitude: 129.0798)) == "480m")
    }

    @Test("실위치가 없거나 좌표가 유한하지 않으면 거리를 생략한다")
    func distanceOmitted() {
        let me = UserCoordinates(latitude: 35.2316, longitude: 129.0846)
        let target = place(latitude: 35.1577, longitude: 129.0592)
        #expect(distanceLabel(from: nil, place: target) == nil)
        #expect(distanceLabel(from: UserCoordinates(latitude: .nan, longitude: 129), place: target) == nil)
        #expect(distanceLabel(from: UserCoordinates(latitude: 35, longitude: .infinity), place: target) == nil)
        #expect(distanceLabel(from: me, place: place(latitude: .nan, longitude: 129)) == nil)
        #expect(distanceLabel(from: me, place: place(latitude: 35, longitude: .infinity)) == nil)
    }

    @Test("1km 미만은 반올림한 m, 이상은 소수 첫째 자리 km 이고 반은 올린다")
    func distanceFormat() {
        #expect(distanceLabel(meters: 0) == "0m")
        #expect(distanceLabel(meters: 849.5) == "850m")
        // 1000 미만이면 m 분기다. 올림되어 1000m 로 보이는 것까지 원본과 같다.
        #expect(distanceLabel(meters: 999.6) == "1000m")
        #expect(distanceLabel(meters: 1000) == "1.0km")
        #expect(distanceLabel(meters: 6200) == "6.2km")
        // printf 는 짝수로 보내 1.2km·2.8km 가 되는 정확한 반. 원본 Formatter 는 HALF_UP 이다.
        #expect(distanceLabel(meters: 1250) == "1.3km")
        #expect(distanceLabel(meters: 2750) == "2.8km")
        #expect(distanceLabel(meters: 1240) == "1.2km")
    }
}
