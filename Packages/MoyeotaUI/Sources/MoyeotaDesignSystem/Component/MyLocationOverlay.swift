@preconcurrency import NMapsMap
import SwiftUI
import UIKit

/// 새 좌표까지 미끄러져 가는 시간. 갱신 주기(1초)보다 짧아야 다음 fix 전에 도착한다
private let GlideMs = 800.0

/// 이 이상 튀면 보간하지 않고 순간이동한다 — 지도를 가로질러 기어가는 점이 더 이상하다
private let SnapDistanceM = 200.0

/// 이 이하의 미세 이동은 애니메이션 없이 반영한다 (GPS 지터로 계속 애니메이션이 걸리는 것 방지)
private let MinMoveM = 0.5

/// 오차 원이 화면을 통째로 덮어 렌더러를 괴롭히지 않도록 두는 상한(pt)
private let MaxAccuracyRadiusPx = 4000.0

/// 안드로이드 SDK 기본 원의 반경(dp). 원본 26 렌더에서 잰 값이다.
private let AndroidDefaultCircleRadius: CGFloat = 18

/// 안드로이드 SDK 기본 원의 색. 원본 26 렌더의 #F7F7F7 지도 위 #EEF1F7 에서 역산했다(#1666F0, 불투명도 약 4%).
private let androidDefaultCircleColor = UIColor(red: 22 / 255, green: 102 / 255, blue: 240 / 255, alpha: 10 / 255)

/// 내 위치 파란 점 — 네이버 SDK 내장 `NMFLocationOverlay`.
///
/// 지도를 쓰는 화면이 공유한다(14 홈 · 17~19 합승 · 26 운행 중). 일반 `NMFMarker` 를
/// 옮겨 찍는 것보다 네이버 지도 앱과 같은 인상을 주고, 오차 원·방향 화살표를 SDK 가 맡아 준다.
///
/// 세 가지를 이 뷰가 책임진다.
/// 1. **보간** — 1초 주기 좌표를 그대로 찍으면 점이 뚝뚝 끊겨 「위치가 튄다」로 읽힌다. 등속으로 미끄러뜨린다
///    (걷는 사람의 이동은 가감속이 없어 보이는 편이 자연스럽다). `SnapDistanceM` 이상 튀면 순간이동한다.
/// 2. **정리** — `locationOverlay` 는 지도에 붙어 있는 **싱글턴**이라 화면을 떠날 때 반드시 숨긴다.
///    남겨 두면 같은 지도를 쓰는 다음 화면에 낡은 점이 그대로 뜬다.
/// 3. **오차 원 환산** — 반경 단위가 pt 라 같은 오차(m)라도 줌에 따라 화면 크기가 달라진다.
///    카메라가 움직일 때마다 다시 환산해야 원이 지면에 붙어 있는 것처럼 보인다.
///
/// - Parameters:
///   - map: 준비된 지도. nil 이면(아직 onMapReady 전) 아무것도 하지 않는다
///   - position: 최신 fix 좌표. 호출부가 유효성을 검증해 넘긴다(`latLngOrNull`)
///   - accuracyMeters: 오차 반경(m). **nil 이면 원을 그리지 않는다** — 차량 이동처럼 반경이 정보가
///     되지 않는 화면에서는 넘기지 않는다
///   - bearingDegrees: 이동 방향. 모르는 fix 는 화살표를 띄우지 않는다 — 없는 방향을 북쪽이라고
///     그리면 사용자가 반대로 걸어간다
///   - sdkDefaultCircle: 26 전용. 원본 26 은 공용 오버레이 대신 축약판을 써서 원을 건드리지 않고, 안드로이드 SDK 기본 원이 남는다.
///     iOS SDK 기본은 원을 그리지 않아 같은 원을 직접 준다. `accuracyMeters` 보다 우선한다
public struct MyLocationOverlay: View {
    private let map: NMFMapView?
    private let position: LatLng
    private let accuracyMeters: Float?
    private let bearingDegrees: Float?
    private let sdkDefaultCircle: Bool

    @State private var rendered: LatLng

    public init(
        map: NMFMapView?,
        position: LatLng,
        accuracyMeters: Float? = nil,
        bearingDegrees: Float? = nil,
        sdkDefaultCircle: Bool = false
    ) {
        self.map = map
        self.position = position
        self.accuracyMeters = accuracyMeters
        self.bearingDegrees = bearingDegrees
        self.sdkDefaultCircle = sdkDefaultCircle
        _rendered = State(initialValue: position)
    }

    private struct ApplyKey: Equatable {
        let map: ObjectIdentifier?
        let rendered: LatLng
        let bearing: Float?
    }

    private struct RadiusKey: Equatable {
        let map: ObjectIdentifier?
        let accuracy: Float?
    }

    public var body: some View {
        ZStack {
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: position) {
                    await glide(to: position)
                }

            DisposableEffect(key: mapKey(map)) {
                guard let overlay = map?.locationOverlay else { return nil }
                overlay.hidden = false
                return { overlay.hidden = true }
            }

            DisposableEffect(key: ApplyKey(map: mapKey(map), rendered: rendered, bearing: bearingDegrees)) {
                guard let overlay = map?.locationOverlay else { return nil }
                overlay.location = rendered.nmgLatLng
                overlay.heading = CGFloat(bearingDegrees ?? 0)
                overlay.subIcon = bearingDegrees != nil ? locationOverlaySubIconArrow : nil
                overlay.subIconWidth = bearingDegrees != nil ? LocationArrowWidth : CGFloat(NMF_LOCATION_OVERLAY_SIZE_AUTO)
                overlay.subIconHeight = bearingDegrees != nil ? LocationArrowHeight : CGFloat(NMF_LOCATION_OVERLAY_SIZE_AUTO)
                return nil
            }

            DisposableEffect(key: RadiusKey(map: mapKey(map), accuracy: accuracyMeters)) {
                guard let map else { return nil }
                let accuracy = accuracyMeters
                let overlay = map.locationOverlay
                if sdkDefaultCircle {
                    overlay.circleRadius = AndroidDefaultCircleRadius
                    overlay.circleColor = androidDefaultCircleColor
                    return nil
                }
                let applyRadius = { overlay.circleRadius = accuracyRadius(map, accuracy) }
                applyRadius()
                let listener = MapCameraChangeListener(onChange: applyRadius)
                map.addCameraDelegate(delegate: listener)
                return { map.removeCameraDelegate(delegate: listener) }
            }
        }
    }

    private func glide(to target: LatLng) async {
        let from = rendered
        let moved = from.distanceTo(target)
        if moved < MinMoveM || moved > SnapDistanceM || !moved.isFinite {
            rendered = target
            return
        }
        // 다음 fix 가 오면 이 태스크가 취소되고 현재 위치에서 새 목표로 다시 출발한다
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled {
            let elapsed = start.duration(to: clock.now)
            let (seconds, attoseconds) = elapsed.components
            let millis = Double(seconds) * 1000 + Double(attoseconds) / 1e15
            let value = min(millis / GlideMs, 1)
            rendered = LatLng(
                from.latitude + (target.latitude - from.latitude) * value,
                from.longitude + (target.longitude - from.longitude) * value
            )
            if value >= 1 { return }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }
    }
}

@MainActor
private final class MapCameraChangeListener: NSObject, @preconcurrency NMFMapViewCameraDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func mapView(_ mapView: NMFMapView, cameraIsChangingByReason reason: Int) {
        onChange()
    }

    func mapView(_ mapView: NMFMapView, cameraDidChangeByReason reason: Int, animated: Bool) {
        onChange()
    }
}

/// 오차(m) → 화면 크기(pt). 환산할 수 없으면 SDK 자동값에 맡긴다(원을 그리지 않는 것과 같다)
@MainActor
private func accuracyRadius(_ map: NMFMapView, _ accuracyMeters: Float?) -> CGFloat {
    let auto = CGFloat(NMF_LOCATION_OVERLAY_SIZE_AUTO)
    guard let accuracyMeters, accuracyMeters > 0 else { return auto }
    let metersPerPixel = map.projection.metersPerPixel()
    // 지도가 아직 레이아웃되지 않으면 0·NaN 이 나온다 — 다음 카메라 변화 때 다시 계산된다
    guard metersPerPixel.isFinite, metersPerPixel > 0 else { return auto }
    return accuracyRadiusValue(accuracyMeters: accuracyMeters, metersPerPixel: metersPerPixel)
}

func accuracyRadiusValue(accuracyMeters: Float, metersPerPixel: Double) -> CGFloat {
    let radius = Double(accuracyMeters) / metersPerPixel
    if radius.isNaN { return 0 }
    return CGFloat(min(max(radius.rounded(.towardZero), 0), MaxAccuracyRadiusPx))
}

/// iOS SDK 기본 아이콘에는 반경 18pt 까지 옅은 파란 후광(불투명도 10%)이 그림으로 들어 있다. 안드로이드 기본 아이콘에는 없다.
/// `circleRadius` 를 0 으로 줘도 그대로 남아(실측), 그림에서 그 불투명도만큼을 빼서 쓴다. 점과 흰 테두리, 그림자는 그대로다.
@MainActor
let locationOverlayIcon: NMFOverlayImage = {
    let base = NMFLocationOverlay.defaultIconImage()
    return NMFOverlayImage(image: removingFlatHalo(from: base.image) ?? base.image)
}()

/// 후광의 불투명도는 점에서 충분히 떨어진 자리(중심에서 15pt)의 값으로 읽는다. 후광이 없는 그림이면 원본을 돌려준다.
func removingFlatHalo(from image: UIImage) -> UIImage? {
    guard let source = image.cgImage else { return nil }
    let width = source.width
    let height = source.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = context.data else { return nil }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    let probeX = width / 2 + Int(15 * image.scale)
    guard probeX < width else { return image }
    let halo = Double(pixels[(height / 2 * width + probeX) * 4 + 3]) / 255
    guard halo > 0, halo < 1 else { return image }

    for offset in stride(from: 0, to: width * height * 4, by: 4) {
        let alpha = Double(pixels[offset + 3]) / 255
        guard alpha > 0, alpha < 1 else { continue }
        // 후광 위에 얹힌 반투명 그림자까지 고르게 빼서, 후광이 끝나는 자리에 경계가 남지 않게 한다.
        let reduced = max(alpha - halo, 0) / (1 - halo)
        for channel in 0 ..< 3 {
            let straight = Double(pixels[offset + channel]) / alpha
            pixels[offset + channel] = UInt8(min(straight * reduced, 255).rounded())
        }
        pixels[offset + 3] = UInt8((reduced * 255).rounded())
    }
    guard let result = context.makeImage() else { return nil }
    return UIImage(cgImage: result, scale: image.scale, orientation: .up)
}

// iOS SDK 에는 안드로이드의 `DEFAULT_SUB_ICON_ARROW` 공개 상수가 없다. 안드로이드 SDK 의 같은 그림
// (8×17dp, 위쪽 절반에 아래가 오목한 삼각형, #1666F0)을 그려서 쓴다.
private let LocationArrowWidth: CGFloat = 8
private let LocationArrowHeight: CGFloat = 17

@MainActor
private let locationOverlaySubIconArrow: NMFOverlayImage = {
    let size = CGSize(width: LocationArrowWidth, height: LocationArrowHeight)
    let image = UIGraphicsImageRenderer(size: size).image { context in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 4, y: 0.8))
        path.addLine(to: CGPoint(x: 7.5, y: 6.9))
        path.addQuadCurve(to: CGPoint(x: 0.5, y: 6.9), controlPoint: CGPoint(x: 4, y: 5.5))
        path.close()
        UIColor(red: 0x16 / 255.0, green: 0x66 / 255.0, blue: 0xF0 / 255.0, alpha: 1).setFill()
        path.fill()
    }
    return NMFOverlayImage(image: image)
}()
