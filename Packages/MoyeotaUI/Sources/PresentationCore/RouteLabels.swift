import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain

/// 지도 위 요약 칩 문구(「예상 12분 · 6.2km」). **잰 값만 쓴다.**
///
/// 소요 시간은 서버가 방에 박아 둔 `estimateTime`, 거리는 서버 경로 폴리라인에서 직접 잰 값이다.
/// 서버는 거리를 내려주지 않으므로 출발·도착 **직선거리로 대체하지 않는다** — 실제 주행 거리보다
/// 늘 짧아 요금과 어긋나 보인다. 둘 다 없으면 nil 이고, 호출부가 칩을 통째로 감춘다
/// (틀린 값보다 없는 편이 낫다 — 16 경로 미리보기 칩과 같은 규칙).
public func buildRouteChipLabel(estimatedMinutes: Int?, routeKm: Double?) -> String? {
    let time = estimatedMinutes.map { "예상 \($0)분" }
    let distance = routeKm.map { "\(formatOneDecimal($0))km" }
    let parts = [time, distance].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// 내 위치 → 탑승 위치 거리 표기. 1km 미만은 10m 단위 m, 그 이상은 소수 1자리 km.
///
/// 「약」을 붙이는 건 GPS 오차가 그만큼 있다는 뜻이다. **「도보 N분」은 쓰지 않는다** —
/// 보행 속도를 지어내야 하고, 거리와 달리 잰 값이 아니다.
public func pickupDistanceLabel(meters: Double) -> String {
    if meters < 1_000 {
        // 음의 무한대가 와도 죽지 않게 한다(원본 `toInt` 는 범위를 넘으면 포화한다).
        let tens = meters > -1e18 ? Int(meters / 10) : 0
        return "약 \(tens * 10)m"
    }
    return "약 \(formatOneDecimal(meters / 1000.0))km"
}

/// 내 위치 → 방의 탑승 위치 **직선거리**(m). 둘 중 하나라도 못 쓸 좌표면 nil.
///
/// 좌표 검증을 `latLngOrNull` 에 맡기는 이유는 지도와 같다 — 서버가 위경도를 뒤바꿔 주는 결함(QA D-1)이
/// 있어, 범위를 벗어난 값으로 거리를 재면 「약 9,000km」 같은 숫자가 화면에 나간다.
public func pickupDistanceMeters(ride: Ride, myLocation: UserCoordinates?) -> Double? {
    guard let pickup = latLngOrNull(latitude: ride.originLat, longitude: ride.originLng),
          let me = latLngOrNull(latitude: myLocation?.latitude, longitude: myLocation?.longitude)
    else { return nil }
    let distance = pickup.distanceTo(me)
    return distance.isFinite ? distance : nil
}

/// Kotlin `"%.1f".format(value)` 와 같은 표기.
///
/// `String(format:)` 를 쓰지 않는 이유: C 는 이진수 값 그대로 반올림해 1.15 를 `1.1` 로 쓰지만
/// (실제 값이 1.1499…), Java `Formatter` 는 **가장 짧은 십진 표기**(1.15)에서 반올림해 `1.2` 로 쓴다.
/// 같은 거리가 플랫폼마다 달라 보이지 않도록 Swift 의 `description`(같은 최단 표기)에서 반올림한다.
public func formatOneDecimal(_ value: Double) -> String {
    guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-Infinity" : "Infinity") }
    let rounded = NSDecimalNumber(string: value.description, locale: Locale(identifier: "en_US_POSIX"))
        .rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 1,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
    let text = rounded.description(withLocale: Locale(identifier: "en_US_POSIX"))
    let body = text.contains(".") ? text : text + ".0"
    // 원본은 -0.04 를 "-0.0" 으로 쓴다(십진 변환이 부호를 잃지 않는다).
    return value.sign == .minus && !body.hasPrefix("-") ? "-" + body : body
}
