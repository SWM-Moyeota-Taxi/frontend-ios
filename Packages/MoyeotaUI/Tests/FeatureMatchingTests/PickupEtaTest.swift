@testable import FeatureMatching
import Testing

/// 25c 「약 N분 뒤 탑승 위치 도착 예정」의 어림 계산.
///
/// 서버에 기사→탑승지 ETA API 가 없어 앱이 직선거리로 어림한다. 그 어림이 **말이 되는 범위**에
/// 머무는지만 본다 — 정확도가 아니라 「0분」·「9,000분」 같은 값이 화면에 나가지 않는 것이 요점이다.
struct PickupEtaTest {
    @Test("좌표가 없으면 시간을 만들지 않는다")
    func noCoordinates() {
        #expect(pickupEtaMinutes(distanceMeters: nil) == nil)
    }

    @Test("음수 거리는 계산하지 않는다")
    func negative() {
        #expect(pickupEtaMinutes(distanceMeters: -10.0) == nil)
    }

    @Test("NaN·무한대는 계산하지 않는다")
    func notFinite() {
        #expect(pickupEtaMinutes(distanceMeters: Double.nan) == nil)
        #expect(pickupEtaMinutes(distanceMeters: Double.infinity) == nil)
    }

    @Test("코앞이어도 0분이라고 하지 않는다")
    func atLeastOneMinute() {
        // 「약 0분 뒤 도착」은 정보가 아니라 오류처럼 읽힌다 — 최소 1분
        #expect(pickupEtaMinutes(distanceMeters: 0.0) == 1)
        #expect(pickupEtaMinutes(distanceMeters: 50.0) == 1)
    }

    @Test("시속 25km 기준으로 분을 어림한다")
    func estimate() {
        // 25km/h = 분당 약 416m
        #expect(pickupEtaMinutes(distanceMeters: 833.0) == 2)
        #expect(pickupEtaMinutes(distanceMeters: 2_083.0) == 5)
        #expect(pickupEtaMinutes(distanceMeters: 5_000.0) == 12)
    }

    /// iOS 에서 추가한 검사 — 원본 `roundToInt` 는 범위를 넘으면 포화하지만 Swift `Int(_:)` 는 앱을 죽인다.
    @Test("엄청나게 먼 거리여도 죽지 않고 원본처럼 포화한다")
    func saturates() {
        #expect(pickupEtaMinutes(distanceMeters: Double.greatestFiniteMagnitude) == Int(Int32.max))
    }
}
