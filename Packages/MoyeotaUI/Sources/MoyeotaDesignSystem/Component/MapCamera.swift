import Foundation

/// 마커 아이콘(`NMF_MARKER_IMAGE_BLACK`)이 좌표(꼭짓점)에서
/// **위로 솟는 높이 ≈ 49dp** + 여유 6dp.
///
/// 예전 코드의 「~34dp」는 오기였다. 잘리지 않은 마커를 스크린샷에서 실측하면
/// 129px / density 2.625 = 약 49dp 다(QA D-1). 34dp 를 믿고 사방을 같은 값으로 비우는 바람에
/// 최상단 마커의 머리가 늘 잘려 있었다.
public let MarkerTopInsetDp: Float = 55

/// 캡션(「출발」/「도착」)이 꼭짓점 아래로 내려가는 높이 ~14dp + 여유 6dp.
/// 위쪽과 같은 6dp 여유를 두되 아이콘보다 훨씬 낮아 크게 잡을 이유가 없다 —
/// 좁은 지도(160dp 스트립)에서 아래 여백을 아끼는 만큼 경로가 커진다.
public let MarkerBottomInsetDp: Float = 20

/// 아이콘 폭의 절반 + 캡션이 좌우로 삐져나오는 정도. 가로는 애초에 넉넉해 빡빡할 일이 없다.
public let MarkerSideInsetDp: Float = 24

/// `points` 가 모두 들어오는 카메라(중심·줌)를 구한다. 못 구하면 nil.
///
/// 네이버 지도에도 `cameraUpdateWithFitBounds` 가 있지만, 그건 `NMFMapView` 인스턴스를 직접 잡아
/// 명령형으로 호출해야 한다 — `RouteMapView` 는 center/zoom 을 선언형으로 받고 사용자의 카메라를
/// 보존하는 구조라, 거기에 명령형 이동을 섞으면 두 주인이 생긴다. 그래서 값만 계산해 넘긴다.
///
/// 웹 메르카토르 기준 계산: 줌 z 에서 세계 지도 폭이 `WORLD_TILE_DP`·2^z **dp** 이므로,
/// 필요한 폭(높이)을 뷰포트 dp 로 나눈 비율의 로그가 곧 줌이다. 가로·세로 중 더 빡빡한 쪽을 쓴다.
///
/// 여백은 **사방이 다르다**. 마커 아이콘이 좌표 꼭짓점에서 위로만 길게 솟기 때문이다 —
/// 사방을 같은 값으로 비우면 위쪽 마커는 잘리는데 아래·좌우는 쓰지도 않을 여백만 먹는다.
///
/// - Parameters:
///   - heightDp: **시트·바에 가리지 않고 실제로 보이는** 지도 높이. 뷰 전체 높이가 아니다
///   - insetTopDp: 위쪽 여백. 마커 아이콘 높이를 덮어야 한다 (`MarkerTopInsetDp`)
///   - insetBottomDp: 아래쪽 여백. 캡션 높이만 덮으면 된다
///   - insetSideDp: 좌우 여백
public func fitMapCamera(
    points: [LatLng],
    widthDp: Float,
    heightDp: Float,
    insetTopDp: Float = MarkerTopInsetDp,
    insetBottomDp: Float = MarkerBottomInsetDp,
    insetSideDp: Float = MarkerSideInsetDp
) -> (first: LatLng, second: Double)? {
    if points.count < 2 || widthDp <= 0 || heightDp <= 0 { return nil }

    let latitudes = points.map(\.latitude)
    let longitudes = points.map(\.longitude)
    let minLat = latitudes.min()!
    let maxLat = latitudes.max()!
    let minLng = longitudes.min()!
    let maxLng = longitudes.max()!

    let minY = mercatorY(minLat)
    let maxY = mercatorY(maxLat)

    // 두 점이 사실상 같은 좌표면(핀을 겹쳐 찍은 경우) 폭이 0 이라 줌이 발산한다
    let latFraction = (maxY - minY) / (2 * Double.pi)
    let lngFraction = (maxLng - minLng) / 360.0
    if latFraction <= 0.0 && lngFraction <= 0.0 { return nil }

    // 뷰포트가 아주 낮으면 세로 인셋 합이 높이를 다 먹어 경로가 들어갈 자리가 없어진다.
    // 그때만 위·아래를 같은 비율로 줄여 가용 높이를 최소 40% 는 남긴다(비율은 유지된다).
    let verticalInset = insetTopDp + insetBottomDp
    let shrink: Float = verticalInset > heightDp * 0.6 ? (heightDp * 0.6) / verticalInset : 1
    let topDp = insetTopDp * shrink
    let bottomDp = insetBottomDp * shrink

    let usableHeight = max(heightDp - topDp - bottomDp, 1)
    let usableWidth = max(widthDp - 2 * insetSideDp, 1)

    let zoomForLat = latFraction > 0.0
        ? log2(Double(usableHeight) / WORLD_TILE_DP / latFraction)
        : Double.greatestFiniteMagnitude
    let zoomForLng = lngFraction > 0.0
        ? log2(Double(usableWidth) / WORLD_TILE_DP / lngFraction)
        : Double.greatestFiniteMagnitude
    let zoom = min(max(min(zoomForLat, zoomForLng), MIN_FIT_ZOOM), MAX_FIT_ZOOM)

    // 카메라 타깃은 **가시 영역의 정중앙**에 놓인다. 위 여백이 아래보다 크면 좌표 묶음의 중심은
    // 화면 중앙보다 (top − bottom)/2 dp 만큼 **아래**에 있어야 하므로, 타깃을 그만큼 북쪽으로 올린다.
    // (단순 평균이 아니라 메르카토르 y 로 계산해야 화면에서 위아래로 치우치지 않는다.)
    let offsetDp = Double(topDp - bottomDp) / 2.0
    let mercatorPerDp = 2 * Double.pi / (WORLD_TILE_DP * pow(2.0, zoom))
    let centerY = (minY + maxY) / 2.0 + offsetDp * mercatorPerDp
    return (first: LatLng(inverseMercatorY(centerY), (minLng + maxLng) / 2.0), second: zoom)
}

// 반경 원의 외접 사각형을 구하던 circleBoundsPoints 는 지웠다 — 21 매칭 대기의 탐색 반경 원이
// 유일한 사용처였고, 그 원은 서버가 반경을 고정값으로 정하면서(Backend `a668aee`) 아무것도
// 걸러내지 않는 범위를 그리는 일이 됐다. 원을 되살릴 이유가 생기면 환산도 함께 다시 쓰면 된다.

/// 네이버 지도의 줌 1 단계당 세계 지도 폭 (dp).
///
/// 구글·OSM 계열의 통상값인 256px 이 **아니다** — 네이버는 타일이 두 배 크고 dp 기준이라,
/// 같은 축척을 구글 줌 z+1 로 표현한다. 256 으로 계산하면 두 배 넘게 당겨진 화면이 나온다.
/// 실측 근거: 16 화면에서 `contentBounds` 를 찍어보면 줌 12.11 · 뷰포트 411dp 폭이
/// 경도 0.065° 를 덮는다 → 세계 폭 = 411 / (0.065/360) / 2^12.11 ≈ 512dp.
private let WORLD_TILE_DP = 512.0
private let MIN_FIT_ZOOM = 6.0
private let MAX_FIT_ZOOM = 16.0

private func mercatorY(_ latitude: Double) -> Double {
    let s = min(max(sin(latitude * Double.pi / 180.0), -0.9999), 0.9999)
    return log((1 + s) / (1 - s)) / 2.0
}

private func inverseMercatorY(_ y: Double) -> Double {
    (2 * atan(exp(y)) - Double.pi / 2) * 180.0 / Double.pi
}

/// 폴리라인의 실제 이동 거리(m). 이웃한 점 사이 거리를 그대로 더한다.
///
/// 서버는 방에 **거리를 내려주지 않는다**(요금·소요시간만 준다). 20 합류 확인 등에서 「N.Nkm」 를
/// 보여 주려면 앱이 서버가 준 경로선에서 재는 수밖에 없다 — 출발·도착 **직선거리로 대체하지 않는다**.
/// 직선거리는 실제 주행 거리보다 늘 짧아 요금과 어긋나 보인다.
///
/// 점이 2개 미만이면 0.0 — 호출부가 거리 표기를 생략한다.
public func polylineDistanceMeters(points: [LatLng]) -> Double {
    if points.count < 2 { return 0.0 }
    var total = 0.0
    for i in 1..<points.count {
        let step = points[i - 1].distanceTo(points[i])
        if step.isFinite { total += step }
    }
    return total
}
