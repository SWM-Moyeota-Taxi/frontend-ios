/// 방의 진행 단계.
///
/// `canceled` 는 `completed` 와 갈라 둔다 — 서버는 **기사 매칭 3분 타임아웃**에도 방을 CANCELED 로
/// 바꾸는데, 그걸 「완료」와 같은 값으로 접으면 앱이 「기사님을 찾지 못했어요」를 정상 종료와
/// 구분할 수 없다. 정상 종료는 FINISHED 뿐이다.
///
/// `dispatching` 은 서버의 MATCHING(기사 찾는 중)과 DRIVER_ASSIGNED(배정 완료)를 함께 담는다 —
/// 둘의 구분은 `Ride.driverId` 유무로 한다(배정되면 taxiDriverId 가 채워진다).
public enum RideStatus: String, CaseIterable, Sendable {
    case recruiting = "RECRUITING"
    case matched = "MATCHED"
    case dispatching = "DISPATCHING"
    case ongoing = "ONGOING"
    case completed = "COMPLETED"
    case canceled = "CANCELED"

    /// Kotlin `enum.name` — 원본 상수 이름 그대로.
    public var name: String { rawValue }
}

public struct Ride: Hashable, Sendable {
    public var id: String
    public var origin: String
    public var destination: String
    public var departureLabel: String // 예: "지금 출발", "18:30"
    public var capacity: Int
    public var members: [User]
    public var farePerPerson: Int
    public var totalFare: Int
    public var status: RideStatus
    // 아래는 서버 연동으로 채워지는 값. 더미/목록 응답에는 없어 기본값을 둔다.
    //
    // 방의 **방장 id** 필드는 없다 — 방장은 `members` 안에 `User.isHost` 로 표시된다
    // (서버 `MemberInfo.host`, Backend #240). 방 수준 필드로 올리지 않는 이유는 서버가 내부 PK 였던
    // `PartyDetailResult.hostId` 를 **지웠기** 때문이다: 밖으로 나가는 식별자는 publicId 뿐이고,
    // 그 publicId 는 이미 멤버 목록에 있다. 방 수준에 또 두면 「목록이 말하는 방장」과
    // 「방이 말하는 방장」이 어긋날 수 있는 두 번째 진실이 생긴다 —
    // 「내가 방장인가」는 `isHostedByMe` 하나로만 묻는다.
    public var originLat: Double?
    public var originLng: Double?
    public var destinationLat: Double?
    public var destinationLng: Double?
    // 서버가 방 생성 시점에 네이버 경로 API 로 산출해 방에 박아두는 값 (상세 응답에만 있음).
    /// 경로 전체 택시 요금(원). 서버 estimateFare.
    public var estimatedFare: Int?
    /// 예상 소요 시간(분). 서버 estimateTime.
    public var estimatedMinutes: Int?
    /// Google Encoded Polyline (정밀도 1e5, lat→lng 순). 서버 route. 지도 경로 그리기에 쓴다.
    public var routePolyline: String?
    /// 배정된 기사 id. 미배정이면 null. 서버 taxiDriverId.
    public var driverId: Int64?

    public init(
        id: String,
        origin: String,
        destination: String,
        departureLabel: String,
        capacity: Int,
        members: [User],
        farePerPerson: Int,
        totalFare: Int,
        status: RideStatus,
        originLat: Double? = nil,
        originLng: Double? = nil,
        destinationLat: Double? = nil,
        destinationLng: Double? = nil,
        estimatedFare: Int? = nil,
        estimatedMinutes: Int? = nil,
        routePolyline: String? = nil,
        driverId: Int64? = nil
    ) {
        self.id = id
        self.origin = origin
        self.destination = destination
        self.departureLabel = departureLabel
        self.capacity = capacity
        self.members = members
        self.farePerPerson = farePerPerson
        self.totalFare = totalFare
        self.status = status
        self.originLat = originLat
        self.originLng = originLng
        self.destinationLat = destinationLat
        self.destinationLng = destinationLng
        self.estimatedFare = estimatedFare
        self.estimatedMinutes = estimatedMinutes
        self.routePolyline = routePolyline
        self.driverId = driverId
    }
}

extension Ride {
    /// 내가 이 방의 방장인가 — 화면이 방장 전용 동작(「합승 완료」)을 가릴 때 보는 **단일 창구**다.
    ///
    /// 멤버 목록에서 나를 찾아 그 한 명의 `User.isHost` 만 본다. 목록 첫째 원소나 입장 순서로 흉내 내지
    /// 말 것 — 서버의 방장은 현재 멤버 중 `min(joinedAt, memberId)` 라는 **파생값**이라(`User.isHost`)
    /// 앱이 같은 식을 다시 세우면 동시 입장의 tie-break·자동 승계에서 서버와 어긋난다.
    ///
    /// 내가 목록에 없으면(식별자 없는 목록·생성 응답, 요약 없는 멤버) false 다. **false 를 "방장이 따로
    /// 있다"로 읽지 말 것** — "내가 방장이라고 말해 주는 근거가 없다" 가 전부다. 그리고 true 라도 서버가
    /// 최종 판정이다: 눌렀을 때의 403 `NOT_PARTY_HOST` 는 이 값과 무관하게 **남는다**(방장은 멤버가 들고
    /// 날 때마다 바뀌는데 그 사이 앱 상태가 낡을 수 있다).
    public var isHostedByMe: Bool {
        members.first { $0.isMe }?.isHost == true
    }
}

// 방의 **반경**(서버 `departureRadius`/`destinationRadius`) 필드는 없다 — 백엔드가 방 생성 요청에서
// 반경을 빼고 서버 고정값(500m)으로 바꿨다(Backend `a668aee`). 응답에는 아직 실려 오지만
// (`PartyDetailResponse`) 그건 **사용자가 정한 값이 아니고**, 서버의 어떤 조회·판정도 읽지 않는다 —
// 합류에 거리 검사가 없고 목록은 지도 뷰포트만 본다. 도메인에 태우면 21 대기 화면의 「탐색 반경」처럼
// 아무것도 걸러내지 않는 숫자를 사용자가 고른 조건으로 보여 주게 된다. 경로 매칭이 실제로 이 값을
// 쓰기 시작하면 그때 다시 태운다.
//
// 방의 **지문**(서버 `fingerprint`) 필드는 없다 — 백엔드가 지웠다(Backend `04f6be7`).
// 지문은 「가벼운 상태 요약이 내가 그린 상세와 같은가」를 비교하려고 만든 값이고, 그 비교 대상인
// 상태 조회 API(`GET /matching/rooms/{id}/status`)가 함께 사라지면서 비교할 짝을 잃었다.
// 지금은 주기 조회가 곧 상세(`RideRepository.getPartyDetail`)이므로
// 「바뀌었나」는 받은 Ride 와 들고 있던 Ride 의 `==` 로 직접 본다 — 요약으로는 못 잡던
// 「인원수 같은 멤버 교체」까지 잡히니 지문보다 오히려 정확하다. 되살리면 쓰이지 않는 필드가 된다.

/// 합류 직후의 방 상태(서버 `POST /matching/rooms/{partyId}/join` 응답 `PartyStatusResponse`).
///
/// 이름이 「상태」인 건 **합류 응답이 방 상세가 아니라 이 두 값뿐**이기 때문이다(Backend #213) —
/// 동승자 목록이 오지 않으므로, 필요하면 상세를 따로 읽거나 21 대기 화면의 SSE 첫 스냅샷에 맡긴다
/// (`RideRepository.joinParty`).
///
/// 쓰임은 **합류 응답 하나뿐**이다. 예전에는 폴링용 상태 조회(`/status`)도 같은 모양이었지만
/// 그 엔드포인트는 사라졌다(Backend `04f6be7`). 그래서 지문 필드도, 상세와 비교하던 `isSameAs` 도 없다.
public struct PartyStatus: Hashable, Sendable {
    /// 합류 **직후**의 상태. 내가 마지막 자리를 채웠으면 COMPLETED(기사 모드면 MATCHING)로 온다.
    public var status: RideStatus
    public var currentMembers: Int

    public init(status: RideStatus, currentMembers: Int) {
        self.status = status
        self.currentMembers = currentMembers
    }
}
