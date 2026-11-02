import CoreLocation

/// 긴급 신고에 싣는 실측 좌표 1건 (`RemoteRideRepository.currentLocation` 주입용).
///
/// 신고는 위치보다 빨라야 한다 — 그래서:
/// - 위치 권한이 없으면 즉시 nil (권한 요청 UI 를 띄우지 않는다 — 지도 화면이 이미 요청한다)
/// - 신선한 fix 는 `CURRENT_FIX_TIMEOUT_MS` 안에만 기다리고, 실패하면 캐시(`CLLocationManager.location`)로 폴백
/// - 그래도 없으면 nil — 서버 ReportRequest 가 좌표 null 을 허용하므로 가짜 좌표를 지어내지 않는다
///
/// `CLLocationManager` 는 만든 스레드의 런루프로 콜백을 주므로 메인 액터에서 만든다.
@MainActor
final class ReportLocationProvider {
    private static let CURRENT_FIX_TIMEOUT_MS = 3_000

    func current() async throws -> (Double, Double)? {
        if !hasLocationPermission() { return nil }
        let fix = await freshFix() ?? cachedFix()
        // 원본 `withTimeoutOrNull` 은 바깥 취소를 그대로 던진다. 타임아웃만 nil 이다.
        try Task.checkCancellation()
        return fix.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
    }

    /// 정밀·대략 중 하나면 충분하다 — 신고에는 대략 위치도 없는 것보다 낫다.
    /// iOS 에서 대략 위치는 권한 상태가 아니라 `accuracyAuthorization` 이라 이 판정에 함께 들어온다.
    private func hasLocationPermission() -> Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    private func freshFix() async -> CLLocation? {
        await OneShotLocationRequest(timeoutMs: Self.CURRENT_FIX_TIMEOUT_MS).run()
    }

    /// 원본 `lastLocation` 은 비동기라 1초 한도가 있었다. `location` 은 동기라 기다릴 것이 없다.
    private func cachedFix() -> CLLocation? {
        CLLocationManager().location
    }
}

/// 위치 1건을 기다린다. 실패·취소·타임아웃은 오류 대신 nil — 위치는 어떤 경우에도 신고를 막으면 안 된다.
@MainActor
private final class OneShotLocationRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let timeoutMs: Int
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Task<Void, Never>?

    init(timeoutMs: Int) {
        self.timeoutMs = timeoutMs
    }

    func run() async -> CLLocation? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                manager.delegate = self
                // 원본 `PRIORITY_BALANCED_POWER_ACCURACY` 자리. 문서상 그 정밀도가 100m 안팎이다.
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.requestLocation()
                timeout = Task { [weak self, timeoutMs] in
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                    if Task.isCancelled { return }
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [self] in finish(nil) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        finish(nil)
    }

    private func finish(_ location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        manager.stopUpdatingLocation() // 타임아웃/취소 시 측위 요청도 함께 끊는다
        continuation.resume(returning: location)
    }
}
