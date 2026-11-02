@preconcurrency import NMapsMap
import SwiftUI

/// Google Encoded Polyline(정밀도 1e5, lat→lng 순)을 좌표 목록으로 디코딩한다.
///
/// 서버 `Ride.routePolyline` 이 이 형식이라 그대로 넣으면 된다.
/// 형식이 깨진 문자열은 예외 대신 **거기까지 읽은 좌표만** 돌려준다 — 지도는 부가 정보라
/// 폴리라인 하나 때문에 화면이 죽으면 안 된다.
public func decodePolyline(encoded: String) -> [LatLng] {
    let units = Array(encoded.utf16)
    var points: [LatLng] = []
    var index = 0
    var lat: Int32 = 0
    var lng: Int32 = 0
    while index < units.count {
        guard let dLat = decodeChunk(units, index) else { break }
        index = dLat.next
        lat &+= dLat.delta
        guard let dLng = decodeChunk(units, index) else { break }
        index = dLng.next
        lng &+= dLng.delta
        points.append(LatLng(Double(lat) / 1e5, Double(lng) / 1e5))
    }
    return points
}

// 한 값(위도 또는 경도 델타)을 읽어 (델타, 다음 인덱스)를 돌려준다. 문자열이 중간에 끊기면 nil.
// 원본 Kotlin Int 처럼 32비트로 계산한다(시프트는 하위 5비트만 본다, 넘치면 감긴다).
private func decodeChunk(_ units: [UInt16], _ start: Int) -> (delta: Int32, next: Int)? {
    var index = start
    var shift: Int32 = 0
    var result: Int32 = 0
    var byte: Int32
    repeat {
        if index >= units.count { return nil }
        byte = Int32(units[index]) - 63
        index += 1
        result |= (byte & 0x1F) &<< shift
        shift &+= 5
    } while byte >= 0x20
    let delta = result & 1 != 0 ? ~(result >> 1) : result >> 1
    return (delta, index)
}

/// 지도에 그려도 되는 좌표일 때만 `LatLng` 를 만든다. 아니면 nil (호출부가 렌더를 건너뛴다).
///
/// 거르는 값: nil · NaN/Infinite · 위도 ±90 또는 경도 ±180 을 벗어난 값.
///
/// 범위 검사가 필요한 이유: 서버가 위경도를 **뒤바꿔** 내려보내는 결함이 있다(QA D-1 —
/// `{"longitude":37.56, "latitude":126.97}`). 이때 위도 126.97 은 지구상에 없는 값이다.
///
/// 좌표를 프론트에서 되돌려 끼우지(swap) 않는다 — 백엔드가 D-1 을 고치는 순간 다시 뒤집혀서
/// 같은 버그를 반대 방향으로 재현하게 된다. 범위 검증 + 렌더 스킵만이 수정 전후 모두 안전하다.
public func latLngOrNull(latitude: Double?, longitude: Double?) -> LatLng? {
    guard let latitude, let longitude else { return nil }
    if !latitude.isFinite || !longitude.isFinite { return nil }
    if !(LatLng.MINIMUM_LATITUDE...LatLng.MAXIMUM_LATITUDE).contains(latitude) { return nil }
    if !(LatLng.MINIMUM_LONGITUDE...LatLng.MAXIMUM_LONGITUDE).contains(longitude) { return nil }
    return LatLng(latitude, longitude)
}

/// 지도 객체를 효과 키로 쓰기 위한 값.
func mapKey(_ map: NMFMapView?) -> ObjectIdentifier? {
    map.map(ObjectIdentifier.init)
}

/// 경로 · 마커를 얹은 네이버 지도 (공용 컴포넌트).
///
/// `NaverMapView` 를 감싸 오버레이 생명주기만 관리한다. 오버레이는 `mapView` 프로퍼티로 붙고
/// 떨어지므로, 값이 바뀔 때마다 `DisposableEffect` 로 **떼었다 다시 붙인다**(누수·중복 방지).
///
/// 카메라 중심은 `center` 로 고정한다. 폴링으로 움직이는 `driverPosition` 을 중심으로 쓰면
/// 갱신마다 카메라가 튀어 사용자의 팬·줌을 덮어쓴다 — 마커만 움직이게 둔다.
///
/// - Parameters:
///   - routePath: 경로 좌표. `decodePolyline` 결과를 그대로 넣는다. 2점 미만이면 그리지 않는다
///   - driverPosition: 기사 현재 위치. 아직 못 받았으면 nil (마커 미표시)
///   - myPosition: 내 위치 파란 점. **nil 이면 SDK 의 locationOverlay 를 아예 건드리지 않는다** —
///     26 운행중처럼 화면이 오버레이를 직접 관리하는 경우와 충돌하지 않기 위해서다
///   - center: nil 이면 `originPosition ?? routePath.first ?? MoyeotaDefaultCamera`
///   - useTextureView: iOS 에서는 영향이 없다 — `NaverMapView` 설명 참고
///   - onMapReady: 지도 인스턴스가 필요할 때만 쓴다(카메라 이동 구독 등). 마커·경로는 이
///     뷰가 이미 관리하므로, 여기서 또 붙이면 생명주기가 이원화된다
public struct RouteMapView: View {
    private let routePath: [LatLng]
    private let driverPosition: LatLng?
    private let originPosition: LatLng?
    private let destinationPosition: LatLng?
    private let myPosition: LatLng?
    private let center: LatLng
    private let zoom: Double
    private let contentPadding: EdgeInsets
    private let useTextureView: Bool
    private let onMapReady: (NMFMapView) -> Void

    @State private var map: NMFMapView?

    public init(
        routePath: [LatLng] = [],
        driverPosition: LatLng? = nil,
        originPosition: LatLng? = nil,
        destinationPosition: LatLng? = nil,
        myPosition: LatLng? = nil,
        center: LatLng? = nil,
        zoom: Double = 14.0,
        contentPadding: EdgeInsets = EdgeInsets(),
        useTextureView: Bool = true,
        onMapReady: @escaping (NMFMapView) -> Void = { _ in }
    ) {
        self.routePath = routePath
        self.driverPosition = driverPosition
        self.originPosition = originPosition
        self.destinationPosition = destinationPosition
        self.myPosition = myPosition
        self.center = center ?? originPosition ?? routePath.first ?? MoyeotaDefaultCamera
        self.zoom = zoom
        self.contentPadding = contentPadding
        self.useTextureView = useTextureView
        self.onMapReady = onMapReady
    }

    private struct PathKey: Equatable {
        let map: ObjectIdentifier?
        let routePath: [LatLng]
    }

    private struct PositionKey: Equatable {
        let map: ObjectIdentifier?
        let position: LatLng?
    }

    public var body: some View {
        ZStack {
            NaverMapView(
                center: center,
                zoom: zoom,
                contentPadding: contentPadding,
                useTextureView: useTextureView,
                onMapReady: { ready in
                    map = ready
                    onMapReady(ready)
                }
            )

            DisposableEffect(key: PathKey(map: mapKey(map), routePath: routePath)) {
                guard let map, routePath.count >= 2,
                      let overlay = NMFPath(points: routePath.map(\.nmgLatLng))
                else { return nil }
                overlay.width = 5
                overlay.outlineWidth = 0
                overlay.color = MoyeotaColor.RouteShared.toUIColor()
                overlay.mapView = map
                return { overlay.mapView = nil }
            }

            // 반경 원(CircleOverlay)은 지웠다 — 21 매칭 대기의 「탐색 반경」이 유일한 사용처였고,
            // 서버가 반경을 고정값으로 정하면서(Backend `a668aee`) 매칭이 읽지 않는 값이 됐다.
            // 원은 「이 범위에서 찾는다」는 없는 약속이었다. 되살릴 때는 그 범위를 실제로 쓰는 매칭이
            // 생긴 뒤여야 한다(MapRadiusCircle·circleBoundsPoints 도 같은 커밋에서 함께 지웠다).

            // 내 위치 파란 점. locationOverlay 는 지도에 붙어 있는 **싱글턴**이라, 쓰지 않는 화면에서는
            // 손대지 않고(overlay = nil) 떠날 때만 숨긴다 — 남겨 두면 다음 화면에 낡은 점이 그대로 뜬다.
            DisposableEffect(key: PositionKey(map: mapKey(map), position: myPosition)) {
                guard let map, let myPosition else { return nil }
                let overlay = map.locationOverlay
                overlay.location = myPosition.nmgLatLng
                overlay.hidden = false
                return { overlay.hidden = true }
            }

            MapMarker(map: map, position: originPosition, tint: MoyeotaColor.MarkerOrigin, caption: "출발")
            MapMarker(map: map, position: destinationPosition, tint: MoyeotaColor.MarkerDestination, caption: "도착")
            MapMarker(map: map, position: driverPosition, tint: MoyeotaColor.InkPrimary, caption: "기사님")
        }
    }
}

/// 지도 위 핀 하나. 좌표가 nil 이면 그리지 않고, 화면을 떠날 때 지운다.
/// `RouteMapView` 바깥에서도 쓴다(26 운행 중의 동승자 마커) — 그래서 public 이다.
public struct MapMarker: View {
    private let map: NMFMapView?
    private let position: LatLng?
    private let tint: Color
    private let caption: String

    public init(map: NMFMapView?, position: LatLng?, tint: Color, caption: String) {
        self.map = map
        self.position = position
        self.tint = tint
        self.caption = caption
    }

    private struct Key: Equatable {
        let map: ObjectIdentifier?
        let position: LatLng?
        let tint: Color
        let caption: String
    }

    public var body: some View {
        DisposableEffect(key: Key(map: mapKey(map), position: position, tint: tint, caption: caption)) {
            guard let map, let position else { return nil }
            let marker = NMFMarker()
            marker.position = position.nmgLatLng
            marker.iconImage = NMF_MARKER_IMAGE_BLACK
            marker.iconTintColor = tint.toUIColor()
            marker.captionText = caption
            marker.mapView = map
            return { marker.mapView = nil }
        }
    }
}
