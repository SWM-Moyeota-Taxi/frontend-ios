import Foundation
import MoyeotaDomain

// 서버 연동 전 더미 데이터. 와이어프레임 예시 값과 동일하게 유지한다.
public final class DummyRideRepository: RideRepository {

    private let me = User(id: "u0", nickname: "성윤", verifiedLabel: "성결대 인증", rating: 4.9, rideCount: 12)
    private let minji = User(id: "u1", nickname: "민지", verifiedLabel: "성결대 인증", rating: 4.8, rideCount: 21)
    private let junho = User(id: "u2", nickname: "준호", verifiedLabel: "성결대 인증", rating: 4.7, rideCount: 8)

    public init() {}

    public func getNearbyParties() -> [Ride] {
        [
            Ride(
                id: "r1",
                origin: "성결대 정문",
                destination: "안양역",
                departureLabel: "지금 출발",
                capacity: 3,
                members: [minji],
                farePerPerson: 3_200,
                totalFare: 9_600,
                status: .recruiting,
                originLat: 37.3789,
                originLng: 126.9268
            ),
            Ride(
                id: "r2",
                origin: "성결대 후문",
                destination: "범계역",
                departureLabel: "18:30",
                capacity: 4,
                members: [minji, junho],
                farePerPerson: 3_600,
                totalFare: 10_800,
                status: .recruiting,
                originLat: 37.3812,
                originLng: 126.9301
            ),
        ]
    }

    public func getParties() async throws -> [Ride] { getNearbyParties() }

    // 서버 없이도 지도 화면이 그럴듯하게 동작하도록 출발 좌표로 직접 걸러낸다.
    // `swLat...neLat` 로 쓰지 않는다 — Swift 범위는 하한이 상한보다 크면 트랩한다(Kotlin `..` 은 빈 범위다).
    public func getPartiesWithin(
        swLat: Double,
        swLng: Double,
        neLat: Double,
        neLng: Double
    ) async throws -> [Ride] {
        getNearbyParties().filter { ride in
            guard let lat = ride.originLat, let lng = ride.originLng else { return false }
            return lat >= swLat && lat <= neLat && lng >= swLng && lng <= neLng
        }
    }

    public func getPartyDetail(partyId: Int64) async throws -> Ride { getNearbyParties()[0] }

    // 더미는 순번을 모른다 — null 이면 옛 서버와 같은 완화 규칙으로 떨어지므로 프리뷰가 멀쩡히 돈다.
    public func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail {
        PartyDetail(ride: try await getPartyDetail(partyId: partyId), version: nil)
    }

    // 더미에는 도보 경로 엔진이 없다. **빈 목록이 정답이다** — 가짜 후보를 지어내면 프리뷰에서
    // 「걸어서 N분」이 실제로는 아무 근거 없는 숫자가 된다(도메인 더미를 지운 이유와 같다).
    public func findRealtimeCandidates(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> [MatchCandidate] {
        []
    }

    // 액션은 더미에서 성공한 척만 한다. 프리뷰/오프라인 확인용이다.
    public func createParty(request: NewParty) async throws -> Ride {
        Ride(
            id: "dummy-party",
            origin: request.departure,
            destination: request.destination,
            departureLabel: "지금 출발",
            capacity: request.capacity,
            members: [me],
            farePerPerson: 0,
            totalFare: 0,
            status: .recruiting,
            originLat: request.departureLat,
            originLng: request.departureLng,
            destinationLat: request.destinationLat,
            destinationLng: request.destinationLng
        )
    }

    // 서버와 같은 모양으로 합류 직후 상태만 돌려준다 — 동승자 목록은 상세 조회가 맡는다.
    public func joinParty(partyId: Int64) async throws -> PartyStatus {
        let joined = getNearbyParties()[0]
        return PartyStatus(
            status: .matched,
            currentMembers: joined.members.count
        )
    }

    public func leaveParty(partyId: Int64) async throws {}

    public func finishParty(partyId: Int64) async throws {}

    public func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver {
        AssignedDriver(seats: 4, plateNumber: "12가 3456", vehicleType: "쏘나타")
    }

    /// 직선거리 기준으로 요금·시간을 지어낸다(서울 택시 기본요금 4,800원 + km 당 1,300원,
    /// 평균 시속 22km + 승하차 3분). 경로는 출발·도착을 잇는 2점짜리 인코딩 폴리라인이라
    /// 지도에 직선이 그려진다 — 상수 빈 문자열보다 화면 확인에 쓸모 있다.
    public func previewRoute(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> RouteEstimate {
        let km = straightLineKm(departureLat, departureLng, destinationLat, destinationLng)
        return RouteEstimate(
            estimatedFare: try roundToInt(4_800 + km * 1_300),
            estimatedMinutes: try roundToInt(km / 22.0 * 60) + 3,
            encodedPath: try encodePolyline([(departureLat, departureLng), (destinationLat, destinationLng)])
        )
    }

    private func straightLineKm(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let earthRadiusKm = 6371.0
        let dLat = toRadians(lat2 - lat1)
        let dLng = toRadians(lng2 - lng1)
        let a = pow(sin(dLat / 2), 2) +
            cos(toRadians(lat1)) * cos(toRadians(lat2)) * pow(sin(dLng / 2), 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private func toRadians(_ degrees: Double) -> Double {
        degrees / 180.0 * .pi
    }

    // Google Encoded Polyline Algorithm Format (precision 5) — 서버 path/route 와 같은 형식.
    private func encodePolyline(_ points: [(Double, Double)]) throws -> String {
        var out = ""
        var prevLat = 0
        var prevLng = 0
        for (lat, lng) in points {
            let e5Lat = try roundToInt(lat * 1e5)
            let e5Lng = try roundToInt(lng * 1e5)
            encodeValue(e5Lat - prevLat, &out)
            encodeValue(e5Lng - prevLng, &out)
            prevLat = e5Lat
            prevLng = e5Lng
        }
        return out
    }

    private func encodeValue(_ value: Int, _ out: inout String) {
        var v = value < 0 ? ~(value << 1) : value << 1
        while v >= 0x20 {
            out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63)))
            v >>= 5
        }
        out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
    }

    // 신고도 성공한 척만 한다 — 프리뷰/오프라인에서 UI 흐름(다이얼→복귀 다이얼로그) 확인용.
    public func reportEmergency(partyId: Int64?) async throws -> Int64 { 1 }

    public func confirmEmergencyCall(called: Bool) async throws {}
}

/// Kotlin `Double.roundToInt()` — 정확히 .5 는 양의 무한대 쪽으로 올리고, 32비트 `Int` 범위를 넘으면
/// 그 끝에 붙인다. NaN 은 예외다(Swift `Int(_:)` 처럼 앱을 죽이지 않는다).
private func roundToInt(_ value: Double) throws -> Int {
    if value.isNaN { throw IllegalArgumentException("Cannot round NaN value.") }
    let floor = value.rounded(.down)
    let rounded = value - floor >= 0.5 ? floor + 1 : floor
    return Int(min(max(rounded, Double(Int32.min)), Double(Int32.max)))
}
