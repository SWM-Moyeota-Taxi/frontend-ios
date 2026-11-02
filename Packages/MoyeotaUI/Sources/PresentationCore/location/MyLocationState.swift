import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit

/// 기기의 실제 좌표 1건.
///
/// 지도 SDK 타입(`NMGLatLng`)에 묶지 않는다 — 지도가 없는 화면
/// (15 목적지 입력의 출발지 기본값)도 같은 값을 쓰기 때문이다.
///
/// - Parameters:
///   - accuracyMeters: 수평 오차 반경(m, 68% 신뢰). 지도가 정확도 원을 그리는 데 쓴다.
///     **nil 이면 기기가 정확도를 보고하지 않은 fix** — 원을 그리지 않는다(없는 정확도를
///     0m 로 단정하면 실제보다 정확해 보인다)
///   - bearingDegrees: 진행 방향(도, 0 = 북). 정지 상태에서는 GPS bearing 이 잡음이라
///     nil 로 내려온다 — 방향 표시가 제자리에서 빙빙 도는 것을 막는다
public struct UserCoordinates: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Float?
    public var bearingDegrees: Float?

    public init(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Float? = nil,
        bearingDegrees: Float? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.bearingDegrees = bearingDegrees
    }
}

/// 위치 권한 + 현재 좌표 상태.
///
/// - Parameters:
///   - isGranted: 정밀·대략 중 **하나라도** 허용됐는지. 지도 중심을 잡는 용도라 대략 위치로 충분하다
///   - coordinates: 실제 좌표. **nil 이면 아직 못 받았거나 권한이 없다** — 호출부가 폴백 좌표를 쓴다
///   - onRequestPermission: 권한 재요청. 안내 UI 의 버튼에 연결한다
public struct MyLocationState: Equatable, Sendable {
    public var isGranted: Bool
    public var coordinates: UserCoordinates?
    public var onRequestPermission: @MainActor @Sendable () -> Void

    public init(
        isGranted: Bool,
        coordinates: UserCoordinates?,
        onRequestPermission: @escaping @MainActor @Sendable () -> Void
    ) {
        self.isGranted = isGranted
        self.coordinates = coordinates
        self.onRequestPermission = onRequestPermission
    }

    /// 콜백은 비교하지 않는다. `.task(id:)`·`.onChange` 의 키로 쓸 때 값이 바뀔 때만 다시 돌게 한다.
    public static func == (lhs: MyLocationState, rhs: MyLocationState) -> Bool {
        lhs.isGranted == rhs.isGranted && lhs.coordinates == rhs.coordinates
    }
}

/// 지도 화면용 갱신 주기 — **1초**.
///
/// 파란 점이 걸음 속도(≈1.4m/s)를 눈에 띄는 지연 없이 따라오려면 이 정도가 필요하다.
/// 10초 주기에서는 한 번 튈 때 10m 이상을 순간이동해 「위치가 안 맞는다」로 체감된다.
/// 구독은 화면이 보이는 동안에만 살아 있으므로 백그라운드 소모는 없다.
public let MapLocationIntervalMs: Int64 = 1_000

/// 지도가 없는 화면(15 목적지 입력)용 — 출발지 좌표 한 번이면 충분해 주기를 늦춘다
public let FormLocationIntervalMs: Int64 = 5_000

/// 마커 갱신에 쓸 수 있는 오차 반경 한계(m).
///
/// 이보다 나쁜 fix(주로 셀타워·와이파이 위치)는 파란 점을 수백 m 밖으로 끌고 가 「위치가
/// 틀렸다」는 인상을 만든다. 다만 좌표가 **하나도 없을 때**는 대략 위치라도 보여 주는 편이
/// 빈 지도보다 낫기 때문에 첫 fix 는 정확도와 무관하게 받는다.
private let AccuracyGateM: Float = 30

/// 이 시간 넘게 새 좌표를 못 받았으면 정확도가 나빠도 받아들인다.
///
/// 게이트만 두면 실내처럼 GPS 가 계속 나쁜 환경에서 파란 점이 옛 좌표에 영원히 얼어붙는다.
/// 오래된 정확한 점보다 방금 들어온 대략적인 점이 낫다.
private let StaleFixNanos: Int64 = 20_000_000_000 // 20초

/// bearing 을 신뢰할 최소 속도(m/s).
///
/// 정지 상태의 GPS bearing 은 잡음이라 그대로 반영하면 방향 표시가 제자리에서 회전한다.
/// 속도 정보가 아예 없는 fix 는 판단 근거가 없으므로 bearing 을 그대로 쓴다.
private let MinBearingSpeedMps: Float = 0.5

/// 위치 제공자에서 받은 fix 1건. 원본 `android.location.Location` 의 자리이고, 판정을 기기 없이 테스트하려고 값으로 둔다.
struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var accuracy: Float?
    var bearing: Float?
    var speed: Float?
    var atNanos: Int64

    /// iOS 는 음수로 「없음」을 나타낸다. `horizontalAccuracy` 가 음수면 **좌표 자체가 무효**라 fix 로 치지 않는다.
    ///
    /// `atNanos` 는 단조 시계 기준이다(원본 `elapsedRealtimeNanos`). `CLLocation.timestamp` 는 벽시계라 그대로 쓰면
    /// 사용자가 시계를 되돌렸을 때 새 fix 가 전부 「시간을 거스르는 fix」로 보여 파란 점이 얼어붙는다.
    /// 그래서 지금으로부터 얼마나 지난 fix 인지만 벽시계로 재고, 단조 시계에서 그만큼 뺀다.
    init?(
        location: CLLocation,
        now: Date = Date(),
        monotonicNowNanos: UInt64 = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    ) {
        guard location.horizontalAccuracy >= 0 else { return nil }
        let ageNanos = Int64(now.timeIntervalSince(location.timestamp) * 1_000_000_000)
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: Float(location.horizontalAccuracy),
            bearing: location.course >= 0 ? Float(location.course) : nil,
            speed: location.speed >= 0 ? Float(location.speed) : nil,
            atNanos: Int64(monotonicNowNanos) - ageNanos
        )
    }

    init(
        latitude: Double,
        longitude: Double,
        accuracy: Float? = nil,
        bearing: Float? = nil,
        speed: Float? = nil,
        atNanos: Int64 = 0
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.bearing = bearing
        self.speed = speed
        self.atNanos = atNanos
    }

    /// 0,0(널섬)·NaN 같은 무의미한 fix 는 폴백보다 나쁘므로 버린다
    func toUserCoordinatesOrNull() -> UserCoordinates? {
        if !latitude.isFinite || !longitude.isFinite { return nil }
        if !(-90.0...90.0).contains(latitude) || !(-180.0...180.0).contains(longitude) { return nil }
        if latitude == 0.0 && longitude == 0.0 { return nil }
        // 서 있을 때의 bearing 은 잡음이라 버린다 (방향 표시가 제자리에서 도는 것 방지)
        let usableBearing: Float? = if let speed, speed < MinBearingSpeedMps { nil } else { bearing }
        return UserCoordinates(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracy.flatMap { $0 > 0 ? $0 : nil },
            bearingDegrees: usableBearing
        )
    }
}

/// 어떤 fix 를 화면에 반영할지 판단한다.
///
/// 위치 제공자는 정확도가 제각각인 fix 를 섞어 보낸다. 들어오는 대로 다 쓰면 GPS 로 5m 까지
/// 좁혀 놓은 파란 점이 다음 순간 500m 짜리 네트워크 fix 로 끌려가 눈에 띄게 튄다.
/// 반대로 게이트만 두면 나쁜 환경에서 점이 영영 얼어붙는다 — 그래서 「개선 / 오래됨」 예외를 둔다.
///
/// 컨트롤러와 함께 살아 있는 객체라 백그라운드 왕복으로 구독이 끊겼다 붙어도 기준이 유지된다.
final class FixGate {
    private var hasFix = false
    private var acceptedAccuracy: Float?
    private var acceptedAtNanos: Int64 = 0

    func reset() {
        hasFix = false
        acceptedAccuracy = nil
        acceptedAtNanos = 0
    }

    func accept(_ location: LocationFix) -> Bool {
        let atNanos = location.atNanos
        // 뒤늦게 도착하는 옛 fix — 시간을 거스르는 갱신은 하지 않는다
        if hasFix && atNanos < acceptedAtNanos { return false }

        let accuracy = location.accuracy
        let accepted: Bool
        if !hasFix {
            // 아직 아무것도 못 보여 주고 있다 — 대략 위치가 빈 지도보다 낫다
            accepted = true
        } else if let accuracy {
            if accuracy <= AccuracyGateM {
                accepted = true
            } else if let acceptedAccuracy, accuracy >= acceptedAccuracy {
                // 오래 굶었으면 정확도를 양보한다
                accepted = atNanos - acceptedAtNanos >= StaleFixNanos
            } else {
                // 게이트 밖이어도 지금 쓰는 값보다 정확하면 개선이다
                accepted = true
            }
        } else {
            // 정확도를 모르면 판단 근거가 없다. 새 fix 를 믿는다
            accepted = true
        }
        if accepted {
            hasFix = true
            acceptedAccuracy = accuracy
            acceptedAtNanos = atNanos
        }
        return accepted
    }
}

/// `setMinUpdateIntervalMillis(intervalMs / 2)` 의 자리.
///
/// `CLLocationManager` 에는 주기 설정이 없고 거리 필터 0 이면 약 1초마다 fix 가 온다. 주기의 절반을 하한으로 두어
/// 콜백이 무한정 몰아치지 않게 한다. 지도용 1초는 사실상 그대로 지나가고, 폼용 5초는 2.5초 하한이 걸린다.
struct FixThrottle {
    private let minIntervalNanos: Int64
    private var lastAtNanos: Int64?

    init(intervalMs: Int64) {
        minIntervalNanos = intervalMs / 2 * 1_000_000
    }

    mutating func allows(atNanos: Int64) -> Bool {
        // 시간을 거스르는 fix 는 여기서 거르지 않는다 — 판정은 `FixGate` 몫이다.
        if let lastAtNanos, atNanos >= lastAtNanos, atNanos - lastAtNanos < minIntervalNanos { return false }
        lastAtNanos = atNanos
        return true
    }
}

enum LocationPermissionAction: Equatable {
    case prompt
    case openSettings
}

/// 권한 버튼을 눌렀을 때 무엇을 할까.
///
/// 이미 한 번 물었고(`requested`) 시스템이 더 물어 주지 않는 상태 — 시스템이 다이얼로그 없이 아무 일도 하지 않는다.
/// 그대로 요청하면 버튼이 아무 반응 없는 것처럼 보이므로 설정 화면으로 보낸다.
/// 설정에서 허용하고 돌아오면 `MyLocationController.onHostStart` 의 재확인이 상태를 받아온다.
func locationPermissionAction(requested: Bool, canPrompt: Bool) -> LocationPermissionAction {
    requested && !canPrompt ? .openSettings : .prompt
}

/// 위치 제공자 경계. 권한·구독 규칙을 기기 없이 테스트하려고 둔다.
@MainActor
protocol LocationClient: AnyObject {
    /// 정밀·대략 중 하나라도 허용됐는가.
    var hasLocationPermission: Bool { get }
    /// 시스템이 아직 권한 다이얼로그를 띄워 줄지. iOS 는 첫 질문 한 번뿐이라 `.notDetermined` 일 때만 참이다.
    var canPromptForLocation: Bool { get }
    var onAuthorizationChange: (@MainActor () -> Void)? { get set }
    func requestPermission()
    func openAppSettings()
    func lastKnownFix() -> LocationFix?
    func startUpdates(onFix: @escaping @MainActor (LocationFix) -> Void)
    func stopUpdates()
}

/// 위치 권한을 요청하고 현재 좌표를 구독하는 공용 상태. 원본 `rememberMyLocationState` 본체의 자리다.
///
/// 화면에 있는 동안에만 구독한다(백그라운드 위치 없음). 권한이 없거나 좌표를
/// 한 번도 못 받으면 `coordinates` 가 nil 로 남고, 호출부가 각자 처리한다
/// (지도는 기본 카메라, 15 목적지 입력은 출발지 검색 유도) — **어느 경로에서도 예외를 던지지 않는다.**
///
/// 화면에서는 `@RememberMyLocationState` 와 `.myLocationEffect` 로 쓴다.
@MainActor
@Observable
public final class MyLocationController {
    public private(set) var isGranted: Bool
    public private(set) var coordinates: UserCoordinates?

    public var state: MyLocationState {
        MyLocationState(
            isGranted: isGranted,
            coordinates: coordinates,
            onRequestPermission: { [weak self] in self?.requestPermission() }
        )
    }

    @ObservationIgnored private let autoRequestPermission: Bool
    @ObservationIgnored private let updateIntervalMs: Int64
    @ObservationIgnored private let client: any LocationClient
    // 화면이 보이는 동안에만 구독한다 — 1초 주기를 백그라운드로 끌고 가지 않는다
    @ObservationIgnored private var visible = false
    // 어떤 fix 를 채택할지 판단하는 상태. 구독이 끊겼다 붙어도(백그라운드 왕복) 기준이 유지돼야 하므로 여기 둔다
    @ObservationIgnored private let gate = FixGate()
    // 다이얼로그가 다시 뜨지 않게 요청 사실을 보존한다
    @ObservationIgnored private var requested = false
    // 원본 `DisposableEffect(granted, visible, …)` 의 키. 같으면 다시 구독하지 않는다.
    @ObservationIgnored private var effectKey: (granted: Bool, visible: Bool)?
    @ObservationIgnored private var subscribed = false

    /// - Parameters:
    ///   - autoRequestPermission: 진입 시 권한 다이얼로그를 자동으로 띄운다. 지도가 핵심인
    ///     합승 탭(17~19)은 true, 검색이 핵심이라 다이얼로그가 방해되는 15 목적지 입력은 false 로 쓴다
    ///   - updateIntervalMs: 갱신 주기. 지도에 파란 점을 그리는 화면은 기본값
    ///     `MapLocationIntervalMs`(1초), 좌표를 한 번만 쓰는 화면은 `FormLocationIntervalMs` 를 준다
    public convenience init(
        autoRequestPermission: Bool = true,
        updateIntervalMs: Int64 = MapLocationIntervalMs
    ) {
        self.init(
            autoRequestPermission: autoRequestPermission,
            updateIntervalMs: updateIntervalMs,
            client: CoreLocationClient()
        )
    }

    init(autoRequestPermission: Bool, updateIntervalMs: Int64, client: any LocationClient) {
        self.autoRequestPermission = autoRequestPermission
        self.updateIntervalMs = updateIntervalMs
        self.client = client
        isGranted = client.hasLocationPermission
        client.onAuthorizationChange = { [weak self] in self?.recheckPermission() }
    }

    /// 권한 재요청. 안내 UI 의 버튼이 `MyLocationState.onRequestPermission` 으로 부른다.
    public func requestPermission() {
        switch locationPermissionAction(requested: requested, canPrompt: client.canPromptForLocation) {
        case .openSettings:
            client.openAppSettings()
        case .prompt:
            requested = true
            client.requestPermission()
        }
    }

    /// 진입 시·권한 변화 시 자동 요청. `LaunchedEffect(autoRequestPermission, granted)` 의 몸통이다.
    func autoRequestIfNeeded() {
        if autoRequestPermission && !isGranted && !requested { requestPermission() }
    }

    /// 화면이 보이기 시작했다. 설정 화면에서 권한을 바꾸고 돌아오는 경로 — 복귀할 때마다 실제 상태를 다시 읽는다.
    func onHostStart() {
        visible = true
        let now = client.hasLocationPermission
        if now != isGranted { isGranted = now }
        syncSubscription()
    }

    /// 화면이 가려졌다. 마지막 좌표는 그대로 두어 복귀 시 빈 지도가 되지 않게 한다.
    func onHostStop() {
        visible = false
        syncSubscription()
    }

    private func recheckPermission() {
        // 정밀·대략 중 하나만 허용돼도 지도 중심은 잡힌다
        let now = client.hasLocationPermission
        if now != isGranted { isGranted = now }
        syncSubscription()
    }

    private func syncSubscription() {
        if let effectKey, effectKey.granted == isGranted, effectKey.visible == visible { return }
        effectKey = (isGranted, visible)

        if subscribed {
            client.stopUpdates()
            subscribed = false
        }
        guard isGranted else {
            // 권한이 회수되면 마지막 좌표를 계속 쓰지 않는다
            coordinates = nil
            gate.reset()
            return
        }
        // 화면 밖에서는 구독하지 않는다
        guard visible else { return }

        // 마지막으로 알려진 위치를 즉시 1회 흘려보낸다 — 첫 fix 를 기다리는 동안 지도가
        // 폴백 좌표에 머무르지 않게 한다. **캐시라 오래됐을 수 있다.**
        if let cached = client.lastKnownFix() { receive(cached) }

        // `startUpdatingLocation` 은 첫 fix 를 주기와 상관없이 바로 준다. 원본의 신규 측위 1회(`getCurrentLocation`)가
        // 맡던 일이다. `requestLocation` 을 따로 부르면 진행 중인 구독과 겹쳐 시스템이 어느 한쪽을 끊을 수 있어 부르지 않는다.
        subscribed = true
        var throttle = FixThrottle(intervalMs: updateIntervalMs)
        client.startUpdates { [weak self] fix in
            guard throttle.allows(atNanos: fix.atNanos) else { return }
            self?.receive(fix)
        }
    }

    private func receive(_ fix: LocationFix) {
        // 좌표 자체가 무의미하면(널섬·NaN) 게이트 기준까지 오염되므로 먼저 거른다
        guard let coordinates = fix.toUserCoordinatesOrNull() else { return }
        // 정확도 게이트를 통과한 fix 만 마커를 옮긴다 (수백 m 튀는 셀타워 위치 차단)
        if gate.accept(fix) { self.coordinates = coordinates }
    }
}

/// `val myLocation = rememberMyLocationState(…)` 의 자리. 뷰가 다시 만들어져도 상태는 처음 한 번만 만들어진다.
///
/// ```
/// @RememberMyLocationState(autoRequestPermission: false) private var myLocation
///
/// var body: some View {
///     Screen(coordinates: myLocation.coordinates, onRequestPermission: myLocation.onRequestPermission)
///         .myLocationEffect($myLocation) // 빠뜨리면 구독이 시작되지 않는다
/// }
/// ```
/// 인자는 원본처럼 화면마다 고정값이다. 뷰가 살아 있는 동안 바꿔도 처음 값을 쓴다.
@MainActor
@propertyWrapper
public struct RememberMyLocationState: DynamicProperty {
    @StateObject private var holder: ViewModelHolder<MyLocationController>

    public init(autoRequestPermission: Bool = true, updateIntervalMs: Int64 = MapLocationIntervalMs) {
        _holder = StateObject(
            wrappedValue: ViewModelHolder(
                MyLocationController(autoRequestPermission: autoRequestPermission, updateIntervalMs: updateIntervalMs)
            )
        )
    }

    public var wrappedValue: MyLocationState { holder.viewModel.state }

    public var projectedValue: MyLocationController { holder.viewModel }
}

private struct MyLocationEffectModifier: ViewModifier {
    let controller: MyLocationController

    func body(content: Content) -> some View {
        content
            // 같은 효과가 화면 가시성(구독 on/off)과 복귀 시 권한 재확인을 함께 맡는다.
            .lifecycleEffect(
                onStart: { controller.onHostStart() },
                onStop: { controller.onHostStop() }
            )
            .task(id: controller.isGranted) {
                controller.autoRequestIfNeeded()
            }
    }
}

public extension View {
    /// `rememberMyLocationState` 가 안에서 걸던 효과들. 화면이 보이고 앱이 전면인 동안만 위치를 구독한다.
    func myLocationEffect(_ controller: MyLocationController) -> some View {
        modifier(MyLocationEffectModifier(controller: controller))
    }
}

/// `CLLocationManager` 구독. 원본의 Fused Provider + 프레임워크 폴백 자리다(iOS 는 제공자가 하나다).
///
/// 어느 단계도 예외를 밖으로 던지지 않는다 — 실패하면 콜백이 호출되지 않을 뿐이다.
@MainActor
final class CoreLocationClient: NSObject, LocationClient, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var onFix: (@MainActor (LocationFix) -> Void)?
    var onAuthorizationChange: (@MainActor () -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // kCLLocationAccuracyBest = GPS 하드웨어를 켠다. 택시 픽업 지점으로 쓰기엔 네트워크 위치의 오차가 크다.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // 이동 거리 필터를 걸지 않는다(0m).
        //
        // 필터를 걸면 제자리에서 정확도만 개선되는 fix 가 통째로 버려져, 처음 잡힌 부정확한 좌표에
        // 그대로 고착된다. 갱신 빈도는 주기(interval)로 이미 제한된다.
        manager.distanceFilter = kCLDistanceFilterNone
        // 멈춰 서서 방을 기다리는 동안 시스템이 구독을 끊으면 안 된다.
        manager.pausesLocationUpdatesAutomatically = false
    }

    var hasLocationPermission: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }

    var canPromptForLocation: Bool {
        manager.authorizationStatus == .notDetermined
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func lastKnownFix() -> LocationFix? {
        manager.location.flatMap { LocationFix(location: $0) }
    }

    func startUpdates(onFix: @escaping @MainActor (LocationFix) -> Void) {
        self.onFix = onFix
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
        onFix = nil
    }

    // 델리게이트는 매니저를 만든 스레드(메인)의 런루프로 온다.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            onAuthorizationChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last.flatMap({ LocationFix(location: $0) }) else { return }
        MainActor.assumeIsolated {
            onFix?(fix)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // 일시 실패는 다음 fix 를 기다린다. 권한 거부는 locationManagerDidChangeAuthorization 으로 따로 온다.
    }
}
