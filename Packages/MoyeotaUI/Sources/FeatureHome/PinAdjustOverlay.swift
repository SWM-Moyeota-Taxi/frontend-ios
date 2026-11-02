import Foundation
import MoyeotaDesignSystem
@preconcurrency import NMapsMap
import PresentationCore
import SwiftUI

/// 핀 조정 대상. 한 화면에서 상단 토글로 전환한다.
public enum PinTarget: Hashable, Sendable {
    case origin, destination
}

// 조정 화면 줌 — 건물 단위가 구분되는 수준. 16 미리보기(15.0)보다 두 단계 당긴다
private let AdjustZoom = 17.0

private let PinWidth: CGFloat = 26
private let PinHeight: CGFloat = 34

// 카메라가 움직이는 동안 핀이 지면에서 떠오르는 높이 (카카오T 와 같은 「집어 든」 연출)
private let PinLift: CGFloat = 8

private let GrayMute = Color(argb: 0xFF8A93A0)
private let GrayAsh = Color(argb: 0xFF9AA1AC)
private let PanelShadow = Color(argb: 0x141B2A4A)

/// 진입점이 지정한 대상에 좌표가 없으면 반대쪽에서 시작한다.
func initialPinTarget(
    initialTarget: PinTarget,
    originPosition: LatLng?,
    destinationPosition: LatLng?
) -> PinTarget {
    if initialTarget == .origin && originPosition == nil { return .destination }
    if initialTarget == .destination && destinationPosition == nil { return .origin }
    return initialTarget
}

/// 핀 아래 좌표 문구. 원본 `"%.6f, %.6f".format` 처럼 기기 로케일을 따른다.
func pinCoordinateLabel(position: LatLng?, locale: Locale = .current) -> String {
    guard let position else { return "좌표 없음" }
    return String(format: "%.6f, %.6f", locale: locale, position.latitude, position.longitude)
}

/// 작업 중인 좌표. 카메라 이동 콜백이 **매 프레임** 쓰므로 화면 본문에서는 조정 중인 쪽을 읽지 않는다
/// (읽으면 팬 중에 전체가 다시 그려진다). 읽는 쪽은 좌표 표시·핀처럼 범위를 좁힌 하위 뷰뿐이다.
///
/// 조정 대상도 여기 둔다. 카메라 콜백이 등록될 때의 값이 아니라 **지금 값**을 봐야 해서다
/// (원본 `rememberUpdatedState(target)` 자리).
@MainActor
@Observable
final class PinAdjustWorkingState {
    var target: PinTarget
    var originWorking: LatLng?
    var destinationWorking: LatLng?
    var moving = false

    init(target: PinTarget, originWorking: LatLng?, destinationWorking: LatLng?) {
        self.target = target
        self.originWorking = originWorking
        self.destinationWorking = destinationWorking
    }

    var targetWorking: LatLng? {
        target == .origin ? originWorking : destinationWorking
    }

    /// 지금 조정 중인 쪽에 카메라 좌표를 쓴다
    func writeTarget(_ position: LatLng) {
        switch target {
        case .origin: originWorking = position
        case .destination: destinationWorking = position
        }
    }
}

/// 출발지 · 도착지 좌표 미세조정 (16 모달 내부 확장 상태).
///
/// **마커를 드래그하지 않는다.** 핀은 화면 정중앙에 고정되고 사용자가 지도를 팬·줌하면
/// 핀 아래 좌표(= `NMFMapView.cameraPosition.target`)가 바뀐다 — 카카오T·네이버지도와 같은
/// 방식. 손가락이 핀을 가리지 않고, 정밀한 조정을 확대로 해결할 수 있어서다.
///
/// 조정 **중에는** 이름을 건드리지 않는다 — 팬 한 번에 역지오코딩을 부르면 요청이 쏟아진다.
/// 이름 갱신은 「이 위치로 설정」 확정 뒤 호출부(16)가 한 번만 처리한다.
///
/// 신규 내비게이션 목적지를 만들지 않은 이유: 같은 화면의 최상단 레이어로 띄우는 편이
/// z-order·뒤로가기 모두 예측 가능하다.
///
/// - Parameters:
///   - originName: 하단 패널 라벨용 이름(`destinationName` 도 같다). 실주소가 들어올 수 있어 1줄 말줄임이다
///   - originPosition: 조정 시작 좌표(`destinationPosition` 도 같다). nil 이면 그 대상은 조정 불가
///   - initialTarget: 진입점이 지정한 최초 조정 대상
///   - onConfirm: (출발지, 도착지) 확정 좌표. 조정하지 않은 쪽은 들어온 값 그대로 돌려준다
public struct PinAdjustOverlay: View {
    private let originName: String
    private let destinationName: String
    private let originPosition: LatLng?
    private let destinationPosition: LatLng?
    private let onCancel: () -> Void
    private let onConfirm: (LatLng?, LatLng?) -> Void

    @State private var working: PinAdjustWorkingState

    // 카메라에 실제로 넣는 값. 대상 전환 시에만 바뀐다 — 팬 중에 이 값을 갱신하면
    // 지도가 카메라를 되돌려 손가락과 싸운다.
    @State private var anchor: LatLng

    @State private var map: NMFMapView?

    // GPS 파란 점 — 자기 위치 대비 조정에 쓴다. 권한을 새로 묻지 않는다(조정 흐름을 끊지 않게).
    // 지도 화면이지만 점 자체가 보조 정보라 1초 대신 5초 주기로 충분하다.
    @RememberMyLocationState(autoRequestPermission: false, updateIntervalMs: FormLocationIntervalMs)
    private var myLocation

    public init(
        originName: String,
        destinationName: String,
        originPosition: LatLng?,
        destinationPosition: LatLng?,
        initialTarget: PinTarget,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (LatLng?, LatLng?) -> Void
    ) {
        self.originName = originName
        self.destinationName = destinationName
        self.originPosition = originPosition
        self.destinationPosition = destinationPosition
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let target = initialPinTarget(
            initialTarget: initialTarget,
            originPosition: originPosition,
            destinationPosition: destinationPosition
        )
        _working = State(
            initialValue: PinAdjustWorkingState(
                target: target,
                originWorking: originPosition,
                destinationWorking: destinationPosition
            )
        )
        _anchor = State(
            initialValue: (target == .origin ? originPosition : destinationPosition)
                ?? originPosition ?? destinationPosition ?? MoyeotaDefaultCamera
        )
    }

    private struct LocationOverlayKey: Equatable {
        let map: ObjectIdentifier?
        let position: LatLng?
    }

    public var body: some View {
        // 조정 대상이 없으면 띄울 이유가 없다 (호출부가 이미 막지만 방어)
        if originPosition != nil || destinationPosition != nil {
            content
        }
    }

    private var content: some View {
        let target = working.target
        let targetColor = target == .origin ? MoyeotaColor.MarkerOrigin : MoyeotaColor.MarkerDestination
        let targetName = target == .origin ? originName : destinationName
        let myPosition = latLngOrNull(
            latitude: myLocation.coordinates?.latitude,
            longitude: myLocation.coordinates?.longitude
        )

        return VStack(spacing: 0) {
            // 헤더 + 대상 토글
            VStack(spacing: 0) {
                // 16 모달 위에 덮이므로 안전 영역 안이다(16 헤더와 같다).
                StatusBarSpacer(startsCollapsed: true)
                HStack(alignment: .center, spacing: 0) {
                    Button(action: onCancel) {
                        // 머티리얼 `IconButton` 의 레이아웃 크기는 최소 터치 영역인 48dp 다.
                        BackArrowIcon()
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressFeedbackStyle())
                    Text("위치 조정")
                        .moyeotaText(inlineType(18, .bold), color: MoyeotaColor.InkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 56)
                .padding(.leading, 12)
                .padding(.trailing, 16)

                HStack(spacing: 8) {
                    // 좌표가 없는 대상은 조정할 것이 없으므로 칩 자체를 내지 않는다
                    if originPosition != nil {
                        ConditionChip(
                            text: "출발지",
                            selected: target == .origin,
                            onClick: { working.target = .origin },
                            wide: true
                        )
                    }
                    if destinationPosition != nil {
                        ConditionChip(
                            text: "도착지",
                            selected: target == .destination,
                            onClick: { working.target = .destination },
                            wide: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

                Spacer().frame(height: 8)
            }
            .frame(maxWidth: .infinity)
            // 상태바 띠는 16 과 같이 어둡게 남는다. `ShapeStyle` 배경은 기본값이 안전 영역까지 번진다.
            .background(MoyeotaColor.SurfaceCanvas, ignoresSafeAreaEdges: [])

            // 지도 + 중앙 고정 핀
            ZStack {
                RouteMapView(
                    // 조정 중인 쪽은 중앙 핀이 대신하므로 마커를 띄우지 않는다(핀과 겹쳐 보인다).
                    // 반대쪽 마커는 남겨 둬야 두 지점 관계를 보면서 조정할 수 있다.
                    originPosition: target == .origin ? nil : working.originWorking,
                    destinationPosition: target == .destination ? nil : working.destinationWorking,
                    center: anchor,
                    zoom: AdjustZoom,
                    onMapReady: { map = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 핀이 가리키는 지점. 핀이 떠 있는 동안에도 이 점은 제자리에 남아 기준이 된다
                Circle()
                    .fill(targetColor.copy(alpha: 0.25))
                    .frame(width: 8, height: 8)
                    .allowsHitTesting(false)

                // 핀 끝이 지도 중심(= 카메라 target)에 오도록 자기 높이의 절반만큼 올린다
                CenterPin(color: targetColor, lifted: { working.moving })
                    .offset(y: -PinHeight / 2)
                    .allowsHitTesting(false)

                cameraEffect
                locationOverlayEffect(myPosition: myPosition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 하단 확정 패널
            confirmPanel(targetColor: targetColor, targetName: targetName)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 아래(16 모달)로 탭이 새지 않게 흡수한다
        .background(MoyeotaColor.SurfaceCanvas.onTapGesture {})
        .myLocationEffect($myLocation)
        .moyeotaBackHandler(action: onCancel)
        .onChange(of: target) { _, _ in
            if let next = working.targetWorking { anchor = next }
        }
    }

    // 지도가 멈춰 있을 때만 이벤트가 오므로, change 는 이동 중 실시간 좌표 · idle 은 확정 좌표.
    private var cameraEffect: some View {
        DisposableEffect(key: map.map(ObjectIdentifier.init)) {
            guard let map else { return nil }
            let working = self.working
            let listener = PinCameraListener(
                onChange: { moving, byUser in
                    if moving { working.moving = true }
                    if byUser { working.writeTarget(LatLng(map.cameraPosition.target)) }
                },
                onIdle: { byUser in
                    working.moving = false
                    if byUser { working.writeTarget(LatLng(map.cameraPosition.target)) }
                }
            )
            map.addCameraDelegate(delegate: listener)
            return { map.removeCameraDelegate(delegate: listener) }
        }
    }

    private func locationOverlayEffect(myPosition: LatLng?) -> some View {
        DisposableEffect(key: LocationOverlayKey(map: map.map(ObjectIdentifier.init), position: myPosition)) {
            guard let overlay = map?.locationOverlay else { return nil }
            if let myPosition {
                overlay.location = myPosition.nmgLatLng
                overlay.hidden = false
            }
            // locationOverlay 는 지도당 하나뿐인 싱글턴이라 떼지 않고 hidden 으로 끈다
            return { overlay.hidden = true }
        }
    }

    private func confirmPanel(targetColor: Color, targetName: String) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .circular)
        let working = self.working
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Circle()
                    .fill(targetColor)
                    .frame(width: 11, height: 11)
                Spacer().frame(width: 10)
                Text(targetName)
                    .moyeotaText(inlineType(16, .bold), color: MoyeotaColor.InkPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer().frame(height: 4)
            CoordinateLabel(position: { working.targetWorking })
            Spacer().frame(height: 12)
            // 1줄에 맞춘 길이 — 「…갱신돼 / 요」처럼 마지막 글자만 떨어지면 지저분하다
            Text("지도를 움직여 핀을 맞춰 주세요 · 설정하면 주소가 갱신돼요")
                .moyeotaText(inlineType(12, .medium), color: GrayAsh)
            Spacer().frame(height: 12)
            PrimaryCtaButton(
                text: "이 위치로 설정",
                onClick: { onConfirm(working.originWorking, working.destinationWorking) }
            )
            NavigationBarSpacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoyeotaColor.SurfaceCanvas, in: shape)
        .moyeotaShadow(elevation: 14, shape: shape, spotColor: PanelShadow)
    }
}

/// 카메라 이동 구독. 안드로이드 `OnCameraChangeListener` 는 움직임의 모든 단계에 불리지만 iOS 는 시작·진행·끝으로
/// 나뉜다. 「끝」은 idle 과 순서가 보장되지 않아 떠오름 표시를 다시 켜지 않는다 — 켜면 핀이 뜬 채로 남을 수 있다.
///
/// 원본은 코드로 옮긴 카메라도 좌표에 다시 쓰지만 들어온 값과 같아 눈에 띄지 않는다. iOS SDK 는 콘텐츠 중심이 물리 픽셀의 절반에
/// 걸리면 카메라를 약 0.15m 옮겨 놓아(37.3948 → 37.39480142, 실측) 그대로 쓰면 움직이지 않은 쪽의 좌표가 달라진다.
/// 그래서 `byUser` 일 때만 쓴다. 조정하지 않은 쪽은 들어온 값 그대로 돌아온다.
@MainActor
private final class PinCameraListener: NSObject, @preconcurrency NMFMapViewCameraDelegate {
    private let onChange: @MainActor (_ moving: Bool, _ byUser: Bool) -> Void
    private let onIdle: @MainActor (_ byUser: Bool) -> Void
    private var movedByUser = false

    init(
        onChange: @escaping @MainActor (_ moving: Bool, _ byUser: Bool) -> Void,
        onIdle: @escaping @MainActor (_ byUser: Bool) -> Void
    ) {
        self.onChange = onChange
        self.onIdle = onIdle
    }

    private func note(reason: Int) {
        movedByUser = reason == NMFMapChangedByGesture || reason == NMFMapChangedByControl
    }

    func mapView(_ mapView: NMFMapView, cameraWillChangeByReason reason: Int, animated: Bool) {
        note(reason: reason)
        onChange(true, movedByUser)
    }

    func mapView(_ mapView: NMFMapView, cameraIsChangingByReason reason: Int) {
        note(reason: reason)
        onChange(true, movedByUser)
    }

    func mapView(_ mapView: NMFMapView, cameraDidChangeByReason reason: Int, animated: Bool) {
        note(reason: reason)
        onChange(false, movedByUser)
    }

    func mapViewCameraIdle(_ mapView: NMFMapView) {
        onIdle(movedByUser)
        movedByUser = false
    }
}

/// 화면 중앙 고정 핀. `lifted` 는 **지연 읽기** — 카메라 이동 상태를 이 뷰 안에서만
/// 구독해 팬 중에 상위 화면이 다시 그려지지 않게 한다.
private struct CenterPin: View {
    let color: Color
    let lifted: @MainActor () -> Bool

    var body: some View {
        let isLifted = lifted()
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let headRadius = w / 2
            let headCenter = CGPoint(x: w / 2, y: headRadius)
            // 물방울 꼬리 — 머리 원 아래를 삼각형으로 이어 끝점이 정확히 (중앙, 바닥)
            var tail = Path()
            tail.move(to: CGPoint(x: w / 2 - headRadius * 0.62, y: headRadius + headRadius * 0.62))
            tail.addLine(to: CGPoint(x: w / 2, y: h))
            tail.addLine(to: CGPoint(x: w / 2 + headRadius * 0.62, y: headRadius + headRadius * 0.62))
            tail.closeSubpath()
            context.fill(tail, with: .color(color))
            context.fill(circlePath(center: headCenter, radius: headRadius), with: .color(color))
            context.fill(circlePath(center: headCenter, radius: headRadius * 0.38), with: .color(.white))
        }
        .frame(width: PinWidth, height: PinHeight)
        .offset(y: isLifted ? -PinLift : 0)
        // 원본 `animateDpAsState` 기본 스프링(감쇠비 1, 강성 1500)
        .animation(.interpolatingSpring(mass: 1, stiffness: 1500, damping: 2 * 1500.0.squareRoot()), value: isLifted)
    }
}

private func circlePath(center: CGPoint, radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

/// 핀 아래 좌표. `position` 도 지연 읽기라 팬 중에는 이 텍스트만 다시 그려진다.
private struct CoordinateLabel: View {
    let position: @MainActor () -> LatLng?

    var body: some View {
        Text(pinCoordinateLabel(position: position()))
            .moyeotaText(inlineType(13, .medium), color: GrayMute)
    }
}
