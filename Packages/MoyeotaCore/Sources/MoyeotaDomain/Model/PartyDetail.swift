/// 방 상세 한 덩어리와 그것이 찍힌 시점의 **순번**(서버 `PartyDetailResult`).
///
/// 서버는 같은 모양을 두 경로로 준다 — SSE `connected` 프레임과 `GET /matching/rooms/{partyId}` 다.
/// `PartyEvent.snapshot` 이 앞의 것, 이 타입이 뒤의 것이고, 둘 다 `version` 을 싣는 이유는 같다:
/// **프레임 순서가 뒤집힐 수 있어서** 무엇이 더 최신인지 숫자로 가려야 한다. 규칙은 `PartyEvent` 참고.
///
/// `version` 이 null 이면 서버가 순번을 말하지 않았다(그 필드를 모르는 옛 배포). `0`(갓 만든 방)과
/// 구분해야 하므로 기본값 0 으로 뭉개면 안 된다 — 0 으로 읽으면 뒤따르는 모든 변경분이 "틈"으로
/// 보여 상세를 끝없이 다시 읽는다.
public struct PartyDetail: Hashable, Sendable {
    public var ride: Ride
    public var version: Int64?

    public init(ride: Ride, version: Int64?) {
        self.ride = ride
        self.version = version
    }
}
