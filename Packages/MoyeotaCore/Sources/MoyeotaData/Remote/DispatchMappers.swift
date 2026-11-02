import MoyeotaDomain

// 서버는 (longitude, latitude) 순서로 정의돼 있다. 도메인 모델은 지도 SDK 관례대로 위도를 앞에 둔다.
extension DriverLocationResponse {
    public func toDriverLocation() -> DriverLocation {
        DriverLocation(latitude: latitude, longitude: longitude)
    }
}
