/// 매칭방 생성 요청.
/// 서버 검증 규칙(위반 시 400): capacity 1~3, 좌표는 한국 범위 내.
///
/// 방장 id 필드는 없다. 서버가 자동 기사 매칭으로 전환하며 방장 개념을 없앴고,
/// 방 생성자는 Bearer 토큰 주체로만 기록된다(`OpenPartyRequest.creatorId` 는 구버전 호환용으로
/// 받기만 하고 버려진다). 앱이 실어 보낼 값이 아예 없다.
///
/// **반경 필드도 없다**(Backend `a668aee`). 서버가 `OpenPartyRequest` 에서 `departureRadius`·
/// `destinationRadius` 를 빼고 고정값(500m)을 쓴다 — 사용자가 고를 값이 아니라는 결정이다.
/// 앱도 16 도착지 확인에서 반경 칩을 내렸다. 되살리면 서버가 버리는 값을 사용자에게 고르게 하는
/// 상태로 돌아간다(그전에도 어떤 조회·판정도 그 값을 읽지 않았다).
public struct NewParty: Hashable, Sendable {
    public var departureLat: Double
    public var departureLng: Double
    public var destinationLat: Double
    public var destinationLng: Double
    public var departure: String
    public var destination: String
    public var capacity: Int

    public init(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double,
        departure: String,
        destination: String,
        capacity: Int
    ) {
        self.departureLat = departureLat
        self.departureLng = departureLng
        self.destinationLat = destinationLat
        self.destinationLng = destinationLng
        self.departure = departure
        self.destination = destination
        self.capacity = capacity
    }
}
