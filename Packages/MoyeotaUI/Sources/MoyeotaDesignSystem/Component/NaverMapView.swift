@preconcurrency @_exported import NMapsMap
import SwiftUI
import UIKit

/// 부산 서면 — MVP1 기본 카메라 위치
public let MoyeotaDefaultCamera = LatLng(35.1578, 129.0594)

/// 지도가 뜰 수 없는 환경인가. SwiftUI 프리뷰에서는 네이티브 초기화를 하지 않고 대체 배경만 그린다.
private var isRunningInPreview: Bool {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}

/// 사용자가 보던 카메라를 뷰 수명 너머로 맡아 두는 곳 (원본 `rememberSaveable` 의 자리).
///
/// 같은 뷰가 살아 있는 동안에는 필요 없다 — `NavigationStack` 이 위에 화면을 덮어도 지도 뷰가 그대로 남아
/// 카메라도 그대로다. 탭을 `switch` 로 갈아 끼우는 호스트처럼 뷰가 없어졌다 다시 생기는 경로만 이것이 필요하다.
/// 탭 루트 하나에 하나를 두고 `.environment(\.mapCameraMemory, …)` 로 그 지도 **하나에만** 준다.
/// 로그아웃 때 `clear()` 한다(원본의 `clearBackStack` 자리).
///
/// 앱 전역 하나로 두지 않는 이유: 원본의 저장 값은 그 화면(백스택 항목)의 것이다. 전역이면 16 위치 조정을 취소하고
/// 다시 열었을 때 옮기다 만 카메라가 복원되고, 그 카메라 좌표가 곧 핀 좌표라 값이 틀어진다.
@MainActor
public final class MapCameraMemory {
    fileprivate(set) var camera: NMFCameraPosition?

    /// 첫 실위치로 카메라를 한 번 옮겼는가. 뷰가 다시 만들어져도 남아야 복원한 카메라를 첫 fix 가 덮어쓰지 않는다
    /// (17 탐색의 `ExploreCameraState.centeredOnMyLocation` 저장 값 자리).
    public var centeredOnMyLocation = false

    public init() {}

    public func clear() {
        camera = nil
        centeredOnMyLocation = false
    }
}

public extension EnvironmentValues {
    @Entry var mapCameraMemory: MapCameraMemory?
}

/// 줌 컨트롤(`NMFZoomControlView`)의 높이. 호출부가 컨트롤과 다른 UI 의 겹침을 계산할 때 쓴다.
public let NaverMapZoomControlHeight: CGFloat = 89

/// 네이버 지도 뷰 (공용 컴포넌트).
///
/// 네이버는 공식 SwiftUI API 를 제공하지 않아 `UIViewRepresentable` 로 `NMFMapView` 를 감싼다.
///
/// - Parameters:
///   - center: 카메라 중심. **변경 시 지도에 반영된다** (동적 좌표 화면 지원)
///   - zoom: 줌 레벨. center 와 동일하게 변경이 반영된다
///   - contentPadding: 지도 위에 겹쳐지는 UI(시트·바) 영역. 이 값을 빼고 남은
///     가시 영역을 기준으로 카메라 중심이 잡히므로, 마커가 시트에 가려지지 않는다
///   - zoomControlOffsetY: 줌 컨트롤을 콘텐츠 영역 가운데에서 옮기는 값(아래로 양수). 카메라 중심과 축척 바·로고는 그대로다.
///     원본에 없는 값으로, iPhone 상태바가 높아 생기는 차이를 메울 때만 쓴다(`docs/IOS-DIFFERENCES.md`)
///   - useTextureView: iOS 에는 렌더 방식 선택이 없어(Metal 하나) 영향이 없다. 호출부를 원본과 같게 두려고 받는다
///   - onMapReady: 지도 준비 완료 콜백. 마커·오버레이 추가는 여기서 한다
public struct NaverMapView: View {
    private let center: LatLng
    private let zoom: Double
    private let contentPadding: EdgeInsets
    private let zoomControlOffsetY: CGFloat
    private let onMapReady: (NMFMapView) -> Void

    @Environment(\.mapCameraMemory) private var cameraMemory

    public init(
        center: LatLng = MoyeotaDefaultCamera,
        zoom: Double = 14.0,
        contentPadding: EdgeInsets = EdgeInsets(),
        zoomControlOffsetY: CGFloat = 0,
        useTextureView: Bool = true,
        onMapReady: @escaping (NMFMapView) -> Void = { _ in }
    ) {
        self.center = center
        self.zoom = zoom
        self.contentPadding = contentPadding
        self.zoomControlOffsetY = zoomControlOffsetY
        self.onMapReady = onMapReady
    }

    public var body: some View {
        // SwiftUI 프리뷰에서는 지도가 네이티브 초기화를 하지 않으므로 대체 배경만 그린다
        if isRunningInPreview {
            MoyeotaColor.SurfaceSoft
        } else {
            NaverMapRepresentable(
                center: center,
                zoom: zoom,
                contentPadding: contentPadding,
                zoomControlOffsetY: zoomControlOffsetY,
                cameraMemory: cameraMemory,
                onMapReady: onMapReady
            )
        }
    }
}

private struct NaverMapRepresentable: UIViewRepresentable {
    let center: LatLng
    let zoom: Double
    let contentPadding: EdgeInsets
    let zoomControlOffsetY: CGFloat
    let cameraMemory: MapCameraMemory?
    let onMapReady: (NMFMapView) -> Void

    func makeCoordinator() -> NaverMapCoordinator {
        NaverMapCoordinator()
    }

    func makeUIView(context: Context) -> NaverMapContainerView {
        let container = NaverMapContainerView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.update(self)
        coordinator.container = container
        container.onLaidOut = { [weak coordinator] in
            coordinator?.containerDidLayout()
        }
        return container
    }

    func updateUIView(_ uiView: NaverMapContainerView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ uiView: NaverMapContainerView, coordinator: NaverMapCoordinator) {
        coordinator.detach()
    }
}

/// `NMFMapView` 와 그 위의 컨트롤.
///
/// 안드로이드 `MapView` 에는 줌 버튼·축척 바·나침반이 기본으로 있고 iOS `NMFMapView` 에는 없어 직접 얹는다.
/// `NMFNaverMapView` 를 쓰지 않는 이유: 그 컨트롤과 로고는 콘텐츠 패딩에 더해 **안전 영역만큼 또 안쪽으로** 놓인다.
/// 이 앱의 지도는 화면 가장자리까지 깔리고 시트·바의 높이를 이미 `contentPadding` 으로 알려 주므로, 그러면 축척 바와
/// 로고가 시트에서 인디케이터 높이(34pt)만큼 떠 보인다. 원본은 `contentPadding` 만으로 놓인다.
private final class NaverMapContainerView: UIView {
    let mapView: NMFMapView
    /// 지도 초기화는 크기가 정해진 뒤로 미룬다. 0x0 상태에서 패딩·카메라를 먼저 넣으면 가시 영역 계산이 어긋난다.
    var onLaidOut: (() -> Void)?

    private let scale = ScaleBarControl(frame: .zero)
    private var scaleAttached = false
    private var zoomTrailing: NSLayoutConstraint?
    private var zoomCenterY: NSLayoutConstraint?
    private var scaleTrailing: NSLayoutConstraint?
    private var scaleBottom: NSLayoutConstraint?
    private var compassTop: NSLayoutConstraint?
    private var compassLeading: NSLayoutConstraint?

    override init(frame: CGRect) {
        mapView = EdgeToEdgeMapView(frame: frame)
        super.init(frame: frame)
        // 원본 로고 여백(콘텐츠 영역 끝에서 왼쪽·아래 12). iOS 로고 뷰는 그림 아래에 투명한 줄이 있어, 아래 값은 그림 끝이
        // 원본과 같은 자리(콘텐츠 끝에서 12.6)에 오도록 잰 값이다.
        mapView.logoMargin = UIEdgeInsets(top: 9, left: 12, bottom: 9.3, right: 12)
        addSubview(mapView)
        addControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func addControls() {
        let zoom = NMFZoomControlView(frame: .zero)
        zoom.mapView = mapView
        zoom.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoom)
        pinContent(of: zoom)
        let zoomTrailing = zoom.trailingAnchor.constraint(equalTo: trailingAnchor)
        let zoomCenterY = zoom.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            zoomTrailing, zoomCenterY,
            zoom.widthAnchor.constraint(equalToConstant: 46),
            zoom.heightAnchor.constraint(equalToConstant: NaverMapZoomControlHeight),
        ])
        self.zoomTrailing = zoomTrailing
        self.zoomCenterY = zoomCenterY

        scale.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scale)
        let scaleTrailing = scale.trailingAnchor.constraint(equalTo: trailingAnchor)
        let scaleBottom = scale.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            scaleTrailing, scaleBottom,
            scale.widthAnchor.constraint(equalToConstant: 140),
            scale.heightAnchor.constraint(equalToConstant: 30),
        ])
        self.scaleTrailing = scaleTrailing
        self.scaleBottom = scaleBottom

        let compass = NMFCompassView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        compass.mapView = mapView
        compass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(compass)
        let top = compass.topAnchor.constraint(equalTo: topAnchor)
        let leading = compass.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            top, leading,
            compass.widthAnchor.constraint(equalToConstant: 44),
            compass.heightAnchor.constraint(equalToConstant: 44),
        ])
        compassTop = top
        compassLeading = leading
    }

    /// 코드로 만든 컨트롤은 내용 뷰(nib 최상위)가 바깥 뷰에 묶여 있지 않아 크기가 어긋난다. 묶어 준다.
    private func pinContent(of control: UIView) {
        guard let content = control.subviews.first else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            content.topAnchor.constraint(equalTo: control.topAnchor),
            content.bottomAnchor.constraint(equalTo: control.bottomAnchor),
        ])
    }

    /// 컨트롤과 로고를 콘텐츠 영역(지도 − 패딩) 기준으로 놓는다. 여백은 원본 화면에서 잰 값이다.
    func layoutControls(padding: UIEdgeInsets, zoomOffsetY: CGFloat) {
        zoomTrailing?.constant = -(padding.right + 10)
        zoomCenterY?.constant = (padding.top - padding.bottom) / 2 + zoomOffsetY
        scaleTrailing?.constant = -(padding.right + 12)
        scaleBottom?.constant = -(padding.bottom + 11.3)
        compassTop?.constant = padding.top + 12
        compassLeading?.constant = padding.left + 12
    }

    func detachControls() {
        scale.detach()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        if bounds.width > 0, bounds.height > 0 {
            // 지도가 새 크기를 받아들인 뒤에 카메라를 넣어야 한다. 아니면 옛 크기(0x0) 기준으로 좌표가 어긋난다.
            mapView.layoutIfNeeded()
            if !scaleAttached {
                scaleAttached = true
                scale.attach(to: mapView)
            }
            onLaidOut?()
        }
    }
}

/// SDK 는 로고를 콘텐츠 패딩에 더해 안전 영역만큼 또 안쪽으로 놓는다. 음수 `logoMargin` 은 받지 않아 안전 영역을 없앤 것으로 알려 준다.
private final class EdgeToEdgeMapView: NMFMapView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

@MainActor
private final class NaverMapCoordinator: NSObject, @preconcurrency NMFMapViewCameraDelegate {
    private var center = MoyeotaDefaultCamera
    private var zoom = 14.0
    private var contentPadding = EdgeInsets()
    private var zoomControlOffsetY: CGFloat = 0
    private var cameraMemory: MapCameraMemory?
    private var onMapReady: (NMFMapView) -> Void = { _ in }

    weak var container: NaverMapContainerView?
    private var map: NMFMapView?
    // 각각 마지막으로 지도에 넣은 값. updateUIView 는 무관한 상태 변화에도 불리므로, 값이 달라졌을 때만
    // 넣어야 사용자가 움직인 카메라를 덮어쓰지 않는다(원본 LaunchedEffect 의 키 자리).
    private var appliedPadding: EdgeInsets?
    private var appliedZoomControlOffsetY: CGFloat?
    private var appliedCenter: LatLng?
    private var appliedZoom: Double?
    /// 보존된 카메라 복원은 최초 1회만. 이후 center/zoom 변경은 그대로 반영돼야 한다
    private var cameraInitialized = false

    func update(_ view: NaverMapRepresentable) {
        center = view.center
        zoom = view.zoom
        contentPadding = view.contentPadding
        zoomControlOffsetY = view.zoomControlOffsetY
        cameraMemory = view.cameraMemory
        // 콜백은 최신 참조만 갈아 끼운다 — 람다가 새로 만들어졌다고 다시 부르지 않는다
        onMapReady = view.onMapReady
        guard map != nil else { return }
        applyPadding()
        applyCamera()
    }

    func containerDidLayout() {
        guard map == nil, let mapView = container?.mapView else { return }
        map = mapView

        // 안드로이드 기본 아이콘에는 없는 후광이 iOS 기본 아이콘에 그려져 있어 지도마다 갈아 끼운다.
        mapView.locationOverlay.icon = locationOverlayIcon

        // 오버레이에 가려지는 영역을 먼저 알린다. 카메라 적용보다 먼저 반영돼야 중심 계산이 어긋나지 않는다.
        applyPadding()
        applyCamera()

        // 사용자가 움직인 카메라를 이동이 멈출 때마다 기록한다.
        // **초기 카메라를 적용한 뒤에** 등록해야 한다 — SDK 가 준비 직후 자체 기본 카메라(서울)로 idle 을 쏘면
        // 복원해야 할 값을 덮어써서 카메라 보존이 통째로 무력화된다.
        mapView.addCameraDelegate(delegate: self)

        // 호출부가 이 콜백에서 @State 를 바꾸므로 레이아웃 패스가 끝난 다음 차례로 넘긴다.
        Task { @MainActor [weak self] in
            guard let self, self.map === mapView else { return }
            self.onMapReady(mapView)
        }
    }

    func detach() {
        map?.removeCameraDelegate(delegate: self)
        container?.detachControls()
        map = nil
    }

    private func applyPadding() {
        guard let map, appliedPadding != contentPadding || appliedZoomControlOffsetY != zoomControlOffsetY else { return }
        appliedZoomControlOffsetY = zoomControlOffsetY
        let insets = UIEdgeInsets(
            top: contentPadding.top,
            left: contentPadding.leading,
            bottom: contentPadding.bottom,
            right: contentPadding.trailing
        )
        if appliedPadding != contentPadding {
            appliedPadding = contentPadding
            map.contentInset = insets
        }
        container?.layoutControls(padding: insets, zoomOffsetY: zoomControlOffsetY)
    }

    private func applyCamera() {
        guard let map, appliedCenter != center || appliedZoom != zoom else { return }
        appliedCenter = center
        appliedZoom = zoom
        let restored = cameraInitialized ? nil : cameraMemory?.camera
        let position = restored ?? NMFCameraPosition(center.nmgLatLng, zoom: zoom)
        map.moveCamera(NMFCameraUpdate(position: position))
        cameraInitialized = true
        // 처음 적용한 카메라는 idle 이 오기 전(아래 대리자 등록 전)에 지나간다. 여기서 적어 두지 않으면 사용자가 지도를 건드리지 않은 채
        // 탭을 다녀올 때 맡긴 값이 없어, 첫 실위치 플래그만 남은 지도가 기본 카메라(부산)로 돌아간다.
        cameraMemory?.camera = map.cameraPosition
    }

    func mapViewCameraIdle(_ mapView: NMFMapView) {
        cameraMemory?.camera = mapView.cameraPosition
    }
}
