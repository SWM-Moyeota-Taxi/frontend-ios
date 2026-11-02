import Foundation
import NMapsGeometry

/// 네이버 안드로이드 SDK `LatLng` 의 자리.
///
/// iOS SDK 의 `NMGLatLng` 는 값 비교가 안 되고 `Sendable` 도 아닌 클래스라, `UiState`(`Equatable, Sendable`)에
/// 넣거나 `.task(id:)`·`onChange` 키로 쓸 수 없다. 원본은 값 동등성에 기대는 곳이 많아(`DisposableEffect(map, position)`
/// 등) 값 타입을 두고, SDK 를 부를 때만 `nmgLatLng` 로 바꾼다.
public struct LatLng: Hashable, Sendable {
    public static let MINIMUM_LATITUDE: Double = -90.0
    public static let MAXIMUM_LATITUDE: Double = 90.0
    public static let MINIMUM_LONGITUDE: Double = -180.0
    public static let MAXIMUM_LONGITUDE: Double = 180.0

    public var latitude: Double
    public var longitude: Double

    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(latitude: Double, longitude: Double) {
        self.init(latitude, longitude)
    }

    public init(_ latLng: NMGLatLng) {
        self.init(latLng.lat, latLng.lng)
    }

    public var nmgLatLng: NMGLatLng {
        NMGLatLng(lat: latitude, lng: longitude)
    }

    /// 다른 좌표까지의 거리(m). 안드로이드 SDK `LatLng.distanceTo` 와 같은 식(반지름 6378137m 하버사인)이다.
    public func distanceTo(_ other: LatLng) -> Double {
        if latitude == other.latitude && longitude == other.longitude { return 0 }
        let lat1 = latitude * .pi / 180
        let lng1 = longitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let lng2 = other.longitude * .pi / 180
        return 12_756_274.0 * asin(
            sqrt(
                pow(sin((lat1 - lat2) / 2), 2)
                    + cos(lat1) * cos(lat2) * pow(sin((lng1 - lng2) / 2), 2)
            )
        )
    }
}
