import CoreLocation
import Foundation
import SwiftUI
import Testing
@testable import PresentationCore

/// 원본에 없는 테스트다(원본은 컴포저블 안의 규칙이라 단위 테스트가 없었다). 값은 원본 상수를 따른다.
@Suite struct LocationRulesTest {
    private func fix(
        accuracy: Float? = 5,
        bearing: Float? = nil,
        speed: Float? = nil,
        atSeconds: Int64 = 0
    ) -> LocationFix {
        LocationFix(
            latitude: 37.5,
            longitude: 127,
            accuracy: accuracy,
            bearing: bearing,
            speed: speed,
            atNanos: atSeconds * 1_000_000_000
        )
    }

    @Test("권한·좌표 주기 상수가 원본과 같다")
    func intervals() {
        #expect(MapLocationIntervalMs == 1_000)
        #expect(FormLocationIntervalMs == 5_000)
    }

    @Test("첫 fix 는 정확도가 나빠도 받는다")
    func firstFixAccepted() {
        #expect(FixGate().accept(fix(accuracy: 500)))
    }

    @Test("게이트 안(30m 이하)이면 받는다")
    func insideGate() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 5, atSeconds: 0))
        #expect(gate.accept(fix(accuracy: 30, atSeconds: 1)))
    }

    @Test("게이트 밖이고 지금보다 나쁘면 버린다")
    func worseOutsideGateRejected() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 5, atSeconds: 0))
        #expect(!gate.accept(fix(accuracy: 500, atSeconds: 1)))
    }

    @Test("게이트 밖이어도 지금 값보다 정확하면 개선이다")
    func betterOutsideGateAccepted() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 500, atSeconds: 0))
        #expect(gate.accept(fix(accuracy: 100, atSeconds: 1)))
    }

    @Test("20초 넘게 굶었으면 정확도를 양보한다")
    func staleAccepted() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 5, atSeconds: 0))
        #expect(!gate.accept(fix(accuracy: 500, atSeconds: 19)))
        #expect(gate.accept(fix(accuracy: 500, atSeconds: 20)))
    }

    @Test("시간을 거스르는 fix 는 받지 않는다")
    func olderFixRejected() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 5, atSeconds: 10))
        #expect(!gate.accept(fix(accuracy: 1, atSeconds: 9)))
    }

    @Test("정확도를 모르면 새 fix 를 믿는다")
    func unknownAccuracyAccepted() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 5, atSeconds: 0))
        #expect(gate.accept(fix(accuracy: nil, atSeconds: 1)))
    }

    @Test("초기화하면 다시 첫 fix 로 친다")
    func resetForgets() {
        let gate = FixGate()
        _ = gate.accept(fix(accuracy: 5, atSeconds: 10))
        gate.reset()
        #expect(gate.accept(fix(accuracy: 500, atSeconds: 1)))
    }

    @Test("널섬·NaN·범위 밖 좌표는 버린다")
    func meaninglessCoordinates() {
        #expect(LocationFix(latitude: 0, longitude: 0).toUserCoordinatesOrNull() == nil)
        #expect(LocationFix(latitude: .nan, longitude: 127).toUserCoordinatesOrNull() == nil)
        #expect(LocationFix(latitude: 127, longitude: 37).toUserCoordinatesOrNull() == nil)
        #expect(LocationFix(latitude: 37, longitude: 181).toUserCoordinatesOrNull() == nil)
        #expect(LocationFix(latitude: 37, longitude: 127).toUserCoordinatesOrNull() != nil)
    }

    @Test("정확도 0 은 없는 정확도다")
    func zeroAccuracyDropped() {
        #expect(fix(accuracy: 0).toUserCoordinatesOrNull()?.accuracyMeters == nil)
        #expect(fix(accuracy: 12).toUserCoordinatesOrNull()?.accuracyMeters == 12)
    }

    @Test("서 있을 때의 방향은 버리고 속도를 모르면 그대로 쓴다")
    func bearingNeedsSpeed() {
        #expect(fix(bearing: 90, speed: 0.4).toUserCoordinatesOrNull()?.bearingDegrees == nil)
        #expect(fix(bearing: 90, speed: 0.5).toUserCoordinatesOrNull()?.bearingDegrees == 90)
        #expect(fix(bearing: 90, speed: nil).toUserCoordinatesOrNull()?.bearingDegrees == 90)
        #expect(fix(bearing: nil, speed: 3).toUserCoordinatesOrNull()?.bearingDegrees == nil)
    }

    @Test("CLLocation 의 음수는 없음이고 정확도가 음수면 좌표가 무효다")
    func coreLocationMapping() throws {
        let invalid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: 127),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
        )
        #expect(LocationFix(location: invalid) == nil)

        let noCourse = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: 127),
            altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 1, course: -1, speed: -1, timestamp: Date()
        )
        let mapped = try #require(LocationFix(location: noCourse))
        #expect(mapped.accuracy == 8)
        #expect(mapped.bearing == nil)
        #expect(mapped.speed == nil)
    }

    /// 벽시계를 되돌려도 새 fix 가 옛 fix 로 보이면 안 된다 — 시각은 단조 시계에서 나이만큼 뺀 값이다.
    @Test("fix 시각은 벽시계가 아니라 단조 시계 기준이다")
    func fixTimeIsMonotonic() throws {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: 127),
            altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 1, timestamp: stamp
        )
        let mapped = try #require(
            LocationFix(location: location, now: stamp.addingTimeInterval(3), monotonicNowNanos: 10_000_000_000)
        )
        #expect(mapped.atNanos == 7_000_000_000)
    }

    @Test("주기의 절반 안에 몰려 오는 fix 는 거른다")
    func throttle() {
        var throttle = FixThrottle(intervalMs: 5_000)
        let results = [0, 2_499_000_000, 2_500_000_000].map { throttle.allows(atNanos: $0) }
        #expect(results == [true, false, true])

        var map = FixThrottle(intervalMs: MapLocationIntervalMs)
        let mapResults = [0, 980_000_000].map { map.allows(atNanos: $0) }
        #expect(mapResults == [true, true], "1초 주기는 시스템이 주는 약 1초 간격을 깎으면 안 된다")
    }

    @Test("이미 물었고 시스템이 더 묻지 않으면 설정으로 보낸다")
    func permissionAction() {
        #expect(locationPermissionAction(requested: true, canPrompt: false) == .openSettings)
        #expect(locationPermissionAction(requested: true, canPrompt: true) == .prompt)
        #expect(locationPermissionAction(requested: false, canPrompt: true) == .prompt)
        // 진입 시 자동 요청이 곧바로 설정 앱으로 튀어 나가면 안 된다.
        #expect(locationPermissionAction(requested: false, canPrompt: false) == .prompt)
    }
}

@MainActor
private final class FakeLocationClient: LocationClient {
    var hasLocationPermission: Bool
    var canPromptForLocation: Bool
    var onAuthorizationChange: (@MainActor () -> Void)?
    var requestCount = 0
    var settingsCount = 0
    var startCount = 0
    var stopCount = 0
    var cached: LocationFix?
    private var onFix: (@MainActor (LocationFix) -> Void)?

    init(granted: Bool, canPrompt: Bool = true) {
        hasLocationPermission = granted
        canPromptForLocation = canPrompt
    }

    func requestPermission() { requestCount += 1 }
    func openAppSettings() { settingsCount += 1 }
    func lastKnownFix() -> LocationFix? { cached }

    func startUpdates(onFix: @escaping @MainActor (LocationFix) -> Void) {
        startCount += 1
        self.onFix = onFix
    }

    func stopUpdates() {
        stopCount += 1
        onFix = nil
    }

    var isSubscribed: Bool { onFix != nil }

    func deliver(_ fix: LocationFix) { onFix?(fix) }

    func setGranted(_ granted: Bool) {
        hasLocationPermission = granted
        canPromptForLocation = false
        onAuthorizationChange?()
    }
}

@MainActor
@Suite struct MyLocationControllerTest {
    private func fix(latitude: Double = 37.5, accuracy: Float = 5, atSeconds: Int64 = 0) -> LocationFix {
        LocationFix(latitude: latitude, longitude: 127, accuracy: accuracy, atNanos: atSeconds * 1_000_000_000)
    }

    private func controller(_ client: FakeLocationClient, auto: Bool = true) -> MyLocationController {
        MyLocationController(
            autoRequestPermission: auto,
            updateIntervalMs: MapLocationIntervalMs,
            client: client
        )
    }

    @Test("보이는 동안에만 구독하고 가려지면 멈춘다")
    func subscribesWhileVisible() {
        let client = FakeLocationClient(granted: true)
        let sut = controller(client)
        #expect(client.startCount == 0, "화면이 뜨기 전에 구독했다")

        sut.onHostStart()
        #expect(client.isSubscribed)

        sut.onHostStop()
        #expect(!client.isSubscribed)
        #expect(client.stopCount == 1)

        sut.onHostStart()
        #expect(client.startCount == 2)
    }

    @Test("같은 상태로 다시 시작해도 구독을 겹치지 않는다")
    func noDuplicateSubscription() {
        let client = FakeLocationClient(granted: true)
        let sut = controller(client)
        sut.onHostStart()
        sut.onHostStart()
        #expect(client.startCount == 1)
    }

    @Test("가려져도 마지막 좌표를 남겨 복귀 시 빈 지도가 되지 않는다")
    func keepsCoordinatesWhenHidden() {
        let client = FakeLocationClient(granted: true)
        let sut = controller(client)
        sut.onHostStart()
        client.deliver(fix())
        #expect(sut.coordinates?.latitude == 37.5)

        sut.onHostStop()
        #expect(sut.coordinates?.latitude == 37.5)
    }

    @Test("권한이 회수되면 마지막 좌표를 버리고 구독을 멈춘다")
    func revokedPermissionClears() {
        let client = FakeLocationClient(granted: true)
        let sut = controller(client)
        sut.onHostStart()
        client.deliver(fix())

        client.setGranted(false)

        #expect(!sut.isGranted)
        #expect(sut.coordinates == nil)
        #expect(!client.isSubscribed)
    }

    @Test("권한을 받으면 그 자리에서 구독을 시작한다")
    func grantStartsSubscription() {
        let client = FakeLocationClient(granted: false)
        let sut = controller(client)
        sut.onHostStart()
        #expect(!client.isSubscribed)

        client.setGranted(true)

        #expect(sut.isGranted)
        #expect(client.isSubscribed)
    }

    @Test("설정에서 바꾸고 돌아오면 복귀 때 다시 읽는다")
    func rechecksOnReturn() {
        let client = FakeLocationClient(granted: false)
        let sut = controller(client)
        sut.onHostStart()
        sut.onHostStop()

        client.hasLocationPermission = true // 델리게이트 콜백 없이 바뀐 경우
        sut.onHostStart()

        #expect(sut.isGranted)
        #expect(client.isSubscribed)
    }

    @Test("마지막으로 알려진 위치를 시작하자마자 흘려보낸다")
    func cachedFixFirst() {
        let client = FakeLocationClient(granted: true)
        client.cached = fix(latitude: 35, accuracy: 300)
        let sut = controller(client)

        sut.onHostStart()

        #expect(sut.coordinates?.latitude == 35)
    }

    @Test("게이트에 걸린 fix 는 좌표를 옮기지 않고 무의미한 좌표는 기준을 오염시키지 않는다")
    func gateAppliedToUpdates() {
        let client = FakeLocationClient(granted: true)
        let sut = controller(client)
        sut.onHostStart()
        client.deliver(fix(latitude: 37.5, accuracy: 5, atSeconds: 1))
        client.deliver(fix(latitude: 40, accuracy: 500, atSeconds: 2))
        #expect(sut.coordinates?.latitude == 37.5)

        // 널섬은 시각이 미래여도 게이트 기준을 건드리지 않는다.
        client.deliver(LocationFix(latitude: 0, longitude: 0, accuracy: 5, atNanos: 100_000_000_000))
        client.deliver(fix(latitude: 37.6, accuracy: 5, atSeconds: 3))
        #expect(sut.coordinates?.latitude == 37.6)
    }

    @Test("자동 요청은 처음 한 번만 다이얼로그를 띄운다")
    func autoRequestOnce() {
        let client = FakeLocationClient(granted: false)
        let sut = controller(client, auto: true)

        sut.autoRequestIfNeeded()
        sut.autoRequestIfNeeded()

        #expect(client.requestCount == 1)
        #expect(client.settingsCount == 0)
    }

    @Test("자동 요청을 끈 화면은 묻지 않는다")
    func noAutoRequest() {
        let client = FakeLocationClient(granted: false)
        let sut = controller(client, auto: false)

        sut.autoRequestIfNeeded()

        #expect(client.requestCount == 0)
    }

    @Test("거부된 뒤 자동 요청은 설정 앱으로 튀지 않고 버튼만 설정으로 보낸다")
    func deniedGoesToSettingsOnTap() {
        let client = FakeLocationClient(granted: false, canPrompt: false)
        let sut = controller(client, auto: true)

        sut.autoRequestIfNeeded()
        #expect(client.settingsCount == 0)

        sut.state.onRequestPermission()
        #expect(client.settingsCount == 1)
    }

    @Test("상태 값은 콜백을 빼고 비교한다")
    func stateEquality() {
        let a = MyLocationState(isGranted: true, coordinates: nil, onRequestPermission: {})
        let b = MyLocationState(isGranted: true, coordinates: nil, onRequestPermission: {})
        #expect(a == b)
    }

    /// 화면이 쓸 모양이 컴파일되는지 본다.
    private struct UsageSample: View {
        @RememberMyLocationState private var map
        @RememberMyLocationState(autoRequestPermission: false, updateIntervalMs: FormLocationIntervalMs) private var form

        var body: some View {
            Text(map.isGranted && form.coordinates == nil ? "a" : "b")
                .myLocationEffect($map)
                .myLocationEffect($form)
        }
    }

    @Test("프로퍼티 래퍼 사용 모양")
    func wrapperCompiles() {
        _ = UsageSample()
    }
}
