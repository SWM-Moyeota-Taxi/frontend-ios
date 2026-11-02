// 백엔드 matching 도메인 응답 record 와 필드 1:1 대응
// (feature/driver-report: matching/application/dto/*.java, matching/domain/RouteEstimate.java)
// 서버 record 필드가 전부 박싱 타입(Long/Integer/Double)이라 null 이 올 수 있는 자리는 기본값으로 방어한다.
// 다만 **「모른다」와 「0」이 다른 뜻인 자리는 기본값 대신 nullable 로 받는다** — 인원(currentMembers)이
// 그렇다. 디코더(`decodeOrDefault`)는 키 누락만 기본값으로 떨어뜨리고 명시적 null 에는 예외를 던지므로, non-null
// 기본값은 「조용히 0으로 접기」와 「응답 전체 파싱 실패」 두 실패 모드를 동시에 들여온다.
public struct PartyListResponse: Decodable, Equatable, Sendable {
    public var list: [PartyItem]

    public init(list: [PartyItem] = []) {
        self.list = list
    }

    private enum CodingKeys: String, CodingKey {
        case list
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        list = try c.decodeOrDefault(.list, default: [])
    }

    // PartyListResponse.PartyItem — 목록에는 요금/경로/도착 좌표가 없다.
    // 출발 좌표(departureLat/Lng)는 지도 범위 조회를 위해 서버 record 에 추가된 필드다.
    // 실서버(2026-09-01) 는 무파라미터 전체 목록에도 좌표를 실어주지만, 브랜치에 따라
    // 빠질 수 있으므로 nullable + null 기본값으로 방어한다.
    public struct PartyItem: Decodable, Equatable, Sendable {
        public var partyId: Int64
        public var departure: String
        public var destination: String
        /// 지금 합류한 인원. **`Int = 0` 으로 두면 안 된다.**
        ///
        /// 이 목록은 서버가 `status = ACTIVE` 로만 거른 방들이고(`findSummariesWithinBounds`),
        /// 그런 방에는 최소 방장 1명의 멤버 행이 있다 — 즉 **0 은 서버가 만들 수 없는 값**이다.
        /// 그런데 non-null 로 받으면 두 가지가 전부 0 으로 접힌다: ① 키가 아예 없는 응답(옛 배포)은
        /// 조용히 0 이 되고 ② 명시적 `null` 은 모르는 키 무시와 무관하게 **파싱 예외**를 던져
        /// (디코더는 non-null 필드의 명시적 null 을 기본값으로 떨어뜨리지 않는다) 방 한 건 때문에
        /// 지도 목록 전체가 날아간다. 그래서 「모른다」를 null 로 남기고, 매퍼가 빈 멤버 목록으로
        /// 옮긴다(`toRide`) — 실시간 추천 DTO
        /// (`MatchCandidateResponse.NearbyPartySummaryDto.currentMembers`)와 **같은 방식**이다.
        ///
        /// 서버 record 는 `Integer` 이고(`PartyListResponse.PartyItem`) 값은 JPQL `count(m)` 이라
        /// 운영에서는 늘 1 이상이 실린다 — 이 nullable 은 그 계약을 의심하는 게 아니라 **계약이 깨진
        /// 응답 하나가 목록을 통째로 지우지 못하게** 하는 것이다.
        public var currentMembers: Int?
        public var capacity: Int
        public var status: String
        public var departureLat: Double?
        public var departureLng: Double?

        public init(
            partyId: Int64,
            departure: String = "",
            destination: String = "",
            currentMembers: Int? = nil,
            capacity: Int = 0,
            status: String = "",
            departureLat: Double? = nil,
            departureLng: Double? = nil
        ) {
            self.partyId = partyId
            self.departure = departure
            self.destination = destination
            self.currentMembers = currentMembers
            self.capacity = capacity
            self.status = status
            self.departureLat = departureLat
            self.departureLng = departureLng
        }

        private enum CodingKeys: String, CodingKey {
            case partyId, departure, destination, currentMembers, capacity, status, departureLat, departureLng
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            partyId = try c.decode(Int64.self, forKey: .partyId)
            departure = try c.decodeOrDefault(.departure, default: "")
            destination = try c.decodeOrDefault(.destination, default: "")
            currentMembers = try c.decodeIfPresent(Int.self, forKey: .currentMembers)
            capacity = try c.decodeOrDefault(.capacity, default: 0)
            status = try c.decodeOrDefault(.status, default: "")
            departureLat = try c.decodeIfPresent(Double.self, forKey: .departureLat)
            departureLng = try c.decodeIfPresent(Double.self, forKey: .departureLng)
        }
    }
}

// PartyDetailResult — GET /matching/rooms/{partyId} 의 응답, 그리고 SSE `connected` 이벤트의 data.
//
// **합류(POST .../join)는 더 이상 이 모양을 주지 않는다**(Backend #213) — 상태·인원만 담은
// `PartyStatusResponse` 로 바뀌었다. 합류 직후 동승자 목록이 필요하면 상세를 따로 읽어야 한다.
//
// **`fingerprint` 필드는 없다** — 백엔드가 지웠다(`04f6be7`). 지문은 「상태 요약이 내가 그린 상세와
// 같은가」를 비교하려고 만든 값인데, 그 짝인 상태 조회 API 가 함께 사라졌다. 25·26 의 주기 조회가
// 이제 곧 이 상세이므로 「바뀌었나」는 도메인 Ride 끼리 `==` 로 본다.
//
// **방장은 멤버마다 실린다**(`MemberInfo.host`, Backend #240) — 방 수준 `hostId`(Long) 는 서버가
// **지웠다**: 내부 PK 를 밖으로 내보내지 않는다. 그래서 이 DTO 에 방 수준 방장 필드는 없고, 앱도
// 방장을 추정하지 않는다(PartyMappers 참고 — 입장 순서로 흉내 내던 추정이 지워진 자리다).
// Party 도메인에는 matchingStartedAt 필드가 추가됐지만 PartyDetailResult 가 노출하지 않으므로 DTO 에도 없다.
public struct PartyDetailResponse: Decodable, Equatable, Sendable {
    public var id: Int64
    public var departureLat: Double?
    public var departureLng: Double?
    public var destinationLat: Double?
    public var destinationLng: Double?
    public var departure: String
    public var destination: String
    public var capacity: Int
    /// 지금 합류한 인원. **앱은 이 값을 읽지 않는다** — 상세에는 `members` 가 함께 오고, 인원은 그
    /// 목록의 크기가 유일한 근거다(둘이 어긋나면 누가 들었는지 아는 쪽을 믿는다).
    ///
    /// 그래도 nullable 인 이유는 **명시적 `null` 하나가 방 화면을 못 열게 만들지 않기 위해서**다.
    /// 서버 `PartyDetailResult.currentMembers` 는 `party.getMembers().size()` 라 운영에서는 늘 실리지만,
    /// non-null 로 선언하면 null 이 오는 순간 파싱이 터져 상세가 **통째로** 실패한다 — 25·26 의 주기
    /// 조회가 이 상세 하나에 걸려 있어 그 실패는 배차·운행 전이를 영영 못 잡는 것으로 번진다.
    /// (같은 판단: `MemberInfo` 의 문자열 필드들, `version`.)
    public var currentMembers: Int?
    /// 서버가 방에 박아 둔 반경(m). **사용자가 고른 값이 아니다** — 요청에서 빠지고 서버 고정값
    /// (`Radius.DEFAULT` = 500m)이 됐다(Backend `a668aee`). 응답에는 남아 있어 서버 record 와 모양을
    /// 맞추려고 받아 두지만, **도메인 `Ride` 로는 옮기지 않는다.**
    ///
    /// 옮기지 않는 이유: 서버의 어떤 조회·판정도 이 값을 읽지 않는다 — 합류(`party.join`)에 거리 검사가
    /// 없고 목록은 지도 뷰포트만 본다. 화면에 띄우면 아무것도 걸러내지 않는 숫자를 「탐색 범위」로
    /// 약속하는 셈이고, 사용자가 바꿀 수도 없다. 경로 매칭이 실제로 이 값을 쓰기 시작하면 그때 태운다.
    public var departureRadius: Int
    public var destinationRadius: Int
    public var status: String
    public var createdAt: String?
    public var members: [MemberInfo]
    public var estimateFare: Int?
    public var estimateTime: Int?
    /// Google Encoded Polyline. 서버가 방 생성 시 네이버 경로 API 로 산출해 저장해 둔 값.
    public var route: String?
    public var taxiDriverId: Int64?
    /// 이 상세가 찍힌 시점의 방 순번(Backend V18, `Party.version`). 들고 남이 있을 때마다 1씩 오른다
    /// (서버에서 올리는 곳은 join·leave·finish·expire 네 군데뿐 — 배차·운행 전이는 올리지 않는다).
    ///
    /// **쓰는 이유는 하나다 — 프레임 순서가 뒤집히기 때문이다.** 서버는 구독을 레지스트리에 먼저
    /// 등록한 뒤 DB 를 읽어 `connected` 를 보내므로, 그 사이에 커밋된 변경분이 `connected` 보다
    /// **먼저** 도착할 수 있다(`PartySseController` 의 "연결 중에 방이 바뀌면 변경분이 connected 보다
    /// 먼저 올 수 있다"). 이 숫자가 없으면 낡은 `connected` 가 이미 반영한 변화를 되돌려 버린다.
    ///
    /// **null 은 「서버가 말하지 않았다」다**(version 을 모르는 옛 배포). `0`(갓 만든 방)과 반드시
    /// 구분해야 하므로 논-널 기본값 0 을 쓰면 안 된다 — 옛 서버를 보고 있을 때 0 으로 읽으면
    /// 뒤따르는 모든 변경분이 "틈"으로 보여 상세를 끝없이 다시 읽는다.
    public var version: Int64?

    public init(
        id: Int64,
        departureLat: Double? = nil,
        departureLng: Double? = nil,
        destinationLat: Double? = nil,
        destinationLng: Double? = nil,
        departure: String = "",
        destination: String = "",
        capacity: Int = 0,
        currentMembers: Int? = nil,
        departureRadius: Int = 0,
        destinationRadius: Int = 0,
        status: String = "",
        createdAt: String? = nil,
        members: [MemberInfo] = [],
        estimateFare: Int? = nil,
        estimateTime: Int? = nil,
        route: String? = nil,
        taxiDriverId: Int64? = nil,
        version: Int64? = nil
    ) {
        self.id = id
        self.departureLat = departureLat
        self.departureLng = departureLng
        self.destinationLat = destinationLat
        self.destinationLng = destinationLng
        self.departure = departure
        self.destination = destination
        self.capacity = capacity
        self.currentMembers = currentMembers
        self.departureRadius = departureRadius
        self.destinationRadius = destinationRadius
        self.status = status
        self.createdAt = createdAt
        self.members = members
        self.estimateFare = estimateFare
        self.estimateTime = estimateTime
        self.route = route
        self.taxiDriverId = taxiDriverId
        self.version = version
    }

    /// 직렬화 계약(JSON 키 이름·순서). `PartyMappersTest` 가 이 목록으로 필드 부활을 잡는다.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, departureLat, departureLng, destinationLat, destinationLng, departure, destination, capacity
        case currentMembers, departureRadius, destinationRadius, status, createdAt, members
        case estimateFare, estimateTime, route, taxiDriverId, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        departureLat = try c.decodeIfPresent(Double.self, forKey: .departureLat)
        departureLng = try c.decodeIfPresent(Double.self, forKey: .departureLng)
        destinationLat = try c.decodeIfPresent(Double.self, forKey: .destinationLat)
        destinationLng = try c.decodeIfPresent(Double.self, forKey: .destinationLng)
        departure = try c.decodeOrDefault(.departure, default: "")
        destination = try c.decodeOrDefault(.destination, default: "")
        capacity = try c.decodeOrDefault(.capacity, default: 0)
        currentMembers = try c.decodeIfPresent(Int.self, forKey: .currentMembers)
        departureRadius = try c.decodeOrDefault(.departureRadius, default: 0)
        destinationRadius = try c.decodeOrDefault(.destinationRadius, default: 0)
        status = try c.decodeOrDefault(.status, default: "")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        members = try c.decodeOrDefault(.members, default: [])
        estimateFare = try c.decodeIfPresent(Int.self, forKey: .estimateFare)
        estimateTime = try c.decodeIfPresent(Int.self, forKey: .estimateTime)
        route = try c.decodeIfPresent(String.self, forKey: .route)
        taxiDriverId = try c.decodeIfPresent(Int64.self, forKey: .taxiDriverId)
        version = try c.decodeIfPresent(Int64.self, forKey: .version)
    }

    /// 서버 `PartyDetailResult.MemberInfo(UUID publicId, String nickname, String imageUrl,
    /// String badgeId, Integer rideCount, boolean host)`.
    ///
    /// **내부 PK 였던 `memberId` 는 사라졌다.** 식별자는 `publicId` 하나이며 JWT `sub` 와 같은 값이라
    /// "이 멤버가 나인가"를 앱이 직접 판정할 수 있다(`toRide` 의 currentUuid).
    ///
    /// **`joinedAt` 도 사라졌다**(Backend #218) — 서버 record 에 필드 자체가 없으니 입장 시각을
    /// 화면에 쓸 근거도 없다. 그 자리를 이제 `host` 가 대신한다(Backend #240): 예전에는 "최초 입장자
    /// = 방장" 을 앱이 `joinedAt` 으로 **추정해야** 했는데, 그 추정이 서버 판정과 어긋날 수 있었다
    /// (서버 방장은 `min(joinedAt, memberId)` 라 동시 입장의 tie-break 가 다르고, 멤버가 나가면
    /// 승계된다). 지금은 서버가 `Party.isHost(memberId)` 의 결과를 직접 실어 주므로 앱이 셈하지 않는다.
    /// **`joinedAt` 을 되살려 방장을 다시 추정하지 말 것** — 판별 창구는 `host` 하나다.
    ///
    /// **네 문자열 필드가 전부 nullable 인 건 방어가 아니라 서버 계약이다** — 서버가 유저 요약을
    /// 못 찾으면 `MemberInfo(null, null, null, null, rideCount)` 을 그대로 내려보낸다
    /// (방 상세 조회 자체는 깨지면 안 되므로). 논-널로 선언하면 그 순간 파싱이 터져 방 화면이 열리지 않는다.
    ///
    /// **그 경우를 「탈퇴」와 같다고 읽지 말 것 — 서버에서 둘은 다른 일이다**
    /// (`WithdrawnMemberNames` 에 표로 정리해 두었다):
    ///
    /// | 경우 | 이 응답의 모양 | 근거 |
    /// |---|---|---|
    /// | **요약 없음** | publicId·nickname·imageUrl 이 **전부 null** | 서버가 `MemberSummary` 를 못 만든 경우 |
    /// | **탈퇴(soft delete)** | `publicId` 는 **그대로 오고** `nickname` 만 `"탈퇴한 사용자"` | `User.getNickname()` 이 `isDeleted() ? DELETED_DISPLAY_NAME : nickname` 이다 — 행이 지워지지 않는다 |
    ///
    /// 즉 **탈퇴한 사용자는 식별자가 살아 있다.** 「요약 없음」만 보고 탈퇴를 판정하면(빈 publicId 검사)
    /// 탈퇴한 사용자를 멀쩡한 사람으로 읽어 **이름으로 부르는** 문구가 나간다.
    public struct MemberInfo: Decodable, Equatable, Sendable {
        /// UUID v7 문자열. 유저 요약이 없으면 null.
        public var publicId: String?
        public var nickname: String?
        public var imageUrl: String?
        /// 인증 배지. **서버가 아직 항상 null 을 넣는다**(`toMemberInfo` 의 TODO).
        /// 타입도 어긋나 있다 — `MemberSummary.badgeId` 는 Long 인데 여기서는 String 이다.
        /// 서버가 실제 값을 채우기 시작하면 이 필드 타입부터 다시 확인할 것.
        public var badgeId: String?
        /// 이 멤버가 끝낸(FINISHED) 파티 수. 서버가 없으면 0 을 채워 준다.
        public var rideCount: Int
        /// 이 멤버가 방장인가 — 서버 `Party.isHost(memberId)` 의 결과다(Backend #240).
        ///
        /// **JSON 키는 `isHost` 가 아니라 `host` 다** — 서버 record 컴포넌트 이름이 `host` 이고
        /// Jackson 이 그 이름 그대로 직렬화한다(운영 OpenAPI 에서 `MemberInfo.host: boolean` 확인).
        /// `isHost` 로 적으면 **조용히 늘 null** 이 된다(디코더가 모르는 키를 흘린다).
        ///
        /// **서버 record 는 원시 `boolean`** 이라 운영에서는 늘 true/false 가 실린다. 그런데도
        /// nullable 로 받는 건 "서버가 말하지 않았다"(필드 누락·옛 배포·`null`)를 false 와 **갈라야**
        /// 하기 때문이다. 둘을 접으면 옛 서버를 보는 앱이 "아무도 방장이 아니다" 로 읽어
        /// 방장조차 「합승 완료」를 못 보게 된다. 그 갈라진 경우의 처리는
        /// `toRide` 가 쓰는 `toUser` 매퍼에 근거와 함께 적어 두었다.
        public var host: Bool?

        public init(
            publicId: String? = nil,
            nickname: String? = nil,
            imageUrl: String? = nil,
            badgeId: String? = nil,
            rideCount: Int = 0,
            host: Bool? = nil
        ) {
            self.publicId = publicId
            self.nickname = nickname
            self.imageUrl = imageUrl
            self.badgeId = badgeId
            self.rideCount = rideCount
            self.host = host
        }

        /// 직렬화 계약(JSON 키 이름·순서). `PartyMappersTest` 가 키 이름이 `host` 임을 못 박는다.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case publicId, nickname, imageUrl, badgeId, rideCount, host
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            publicId = try c.decodeIfPresent(String.self, forKey: .publicId)
            nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
            imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
            badgeId = try c.decodeIfPresent(String.self, forKey: .badgeId)
            rideCount = try c.decodeOrDefault(.rideCount, default: 0)
            host = try c.decodeIfPresent(Bool.self, forKey: .host)
        }
    }
}

/// SSE `member-joined` 이벤트의 data — 백엔드 `MemberJoined(PartyDetailResult.MemberInfo member, String status)`.
///
/// `member` 가 방 상세의 멤버와 **같은 record** 라 DTO 도 같은 타입을 그대로 쓴다 — 같은 모양을 두 번
/// 선언하면 한쪽만 서버 변경을 따라가다 어긋난다. 변환도 상세와 같은 매퍼(`toUser`)를 재사용한다.
///
/// `member` 에 기본값을 준 건 서버가 비워 보낼 수 있다고 보기 때문이 아니라, 키가 빠진 프레임 하나가
/// 스트림을 죽이지 않게 하려는 것이다 — 그때는 요약 없는 멤버("탈퇴한 회원")로 떨어진다.
///
/// **본문 모양은 Backend #240 에서도 바뀌지 않았다**(승계 필드가 붙은 건 `member-left` 쪽뿐이다).
/// 다만 `member` 가 `MemberInfo` 라서 거기에 `host` 는 **실려 온다** — 확인함:
/// `PartyService.join` 이 `MemberInfo.of(summary, rideCount, saved.isHost(memberId))` 로 만든다.
/// 합류자는 가장 늦게 들어온 사람이라 그 값은 사실상 늘 false 지만, 앱이 false 를 가정하지 않고
/// 상세와 **같은 매퍼**로 그대로 옮긴다 — 서버가 판정의 단일 창구다.
public struct MemberJoinedPayload: Decodable, Equatable, Sendable {
    public var member: PartyDetailResponse.MemberInfo
    /// 들어온 **뒤**의 방 상태(서버 `PartyStatus` enum 이름). 정원이 차면 여기서 전이가 보인다.
    public var status: String
    /// 이 변경분을 반영한 **뒤**의 방 순번. 들고 있는 값 +1 이면 그대로 얹고, 그보다 크면 중간 프레임을
    /// 놓친 것이므로 상세를 다시 읽는다. 같거나 작으면 이미 반영한 것이라 버린다.
    /// null 이면 옛 서버다 — 순서를 알 수 없으므로 예전 방식(publicId 중복 여부)으로 떨어진다.
    /// 자세한 규칙은 `PartyDetailResponse.version`.
    public var version: Int64?

    public init(
        member: PartyDetailResponse.MemberInfo = PartyDetailResponse.MemberInfo(),
        status: String = "",
        version: Int64? = nil
    ) {
        self.member = member
        self.status = status
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case member, status, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        member = try c.decodeOrDefault(.member, default: PartyDetailResponse.MemberInfo())
        status = try c.decodeOrDefault(.status, default: "")
        version = try c.decodeIfPresent(Int64.self, forKey: .version)
    }
}

/// SSE `member-left` 이벤트의 data — 백엔드 `MemberLeft(UUID publicId, String status, UUID hostPublicId)`.
///
/// `publicId` 는 **null 일 수 있다** — 서버가 `userAccess.findMemberSummaries` 로 요약을 못 찾으면
/// (탈퇴 등) null 을 그대로 싣고도 신호는 보낸다(`PartyService.leave`). 받는 쪽은 "누가 나갔는지 모름"으로
/// 다뤄야 한다. 논-널로 선언하면 그 프레임에서 파싱이 터진다.
public struct MemberLeftPayload: Decodable, Equatable, Sendable {
    public var publicId: String?
    /// 나간 **뒤**의 방 상태. 마지막 멤버가 나가면 방은 닫히고 `member-left` 대신 `closed` 가 온다.
    public var status: String
    /// **승계 후**의 방장 publicId — 서버가 `party.leave()` 를 반영한 **뒤** `party.hostId()` 를 읽어
    /// 싣는다(Backend #240). 방장이 나가면 다음으로 이른 멤버가 자동 승계되고, 그 사실을 앱에
    /// 알려 주는 **유일한 신호**가 이것이다(서버는 다시 보내지 않는다).
    ///
    /// null 인 경우는 둘이다 — 승계된 멤버의 유저 요약을 서버가 못 찾았거나(`hostSummary == null`),
    /// 아직 이 필드를 모르는 옛 서버를 보고 있거나. 둘 다 "새 방장을 특정할 수 없다" 로 같게 다룬다.
    ///
    /// 방이 닫히는 이탈(마지막 멤버)에는 이 프레임 자체가 오지 않는다 — 서버가 `closed` 를 보낸다.
    public var hostPublicId: String?
    /// 이 변경분을 반영한 **뒤**의 방 순번. 규칙은 `MemberJoinedPayload.version` 과 같다.
    public var version: Int64?

    public init(publicId: String? = nil, status: String = "", hostPublicId: String? = nil, version: Int64? = nil) {
        self.publicId = publicId
        self.status = status
        self.hostPublicId = hostPublicId
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case publicId, status, hostPublicId, version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicId = try c.decodeIfPresent(String.self, forKey: .publicId)
        status = try c.decodeOrDefault(.status, default: "")
        hostPublicId = try c.decodeIfPresent(String.self, forKey: .hostPublicId)
        version = try c.decodeIfPresent(Int64.self, forKey: .version)
    }
}

/// **POST /api/v1/matching/rooms/{partyId}/join 응답** — 백엔드 `PartyStatusResponse(String status,
/// Integer currentMembers)`. 합류 응답에 동승자 목록이 없으므로(Backend #213), 목록이 필요하면
/// 상세(`PartyDetailResponse`)를 따로 읽거나 21 대기 화면의 SSE 첫 스냅샷에 맡긴다.
///
/// **쓰임은 합류 응답 하나뿐이다.** 예전에는 폴링용 상태 조회 `GET /rooms/{partyId}/status` 도 같은
/// 모양이었지만 그 엔드포인트는 백엔드에서 삭제됐다(`04f6be7`) — 매칭방 변화가 SSE 전용이 되면서
/// 폴링용으로 만든 조회와 지문이 쓰이지 않게 됐다. 25·26 의 주기 조회는 상세를 읽는다.
///
/// **`fingerprint` 필드도 같은 커밋에서 빠졌다.** 되살리면 비교할 짝(상세의 지문)이 없는 죽은 필드가
/// 된다. 서버가 아직 옛 버전이라 지문을 실어 보내도 디코더가 모르는 키로 흘린다.
///
/// 두 필드 모두 서버 record 가 박싱 타입(String/Integer)이라 기본값으로 방어한다.
public struct PartyStatusResponse: Decodable, Equatable, Sendable {
    /// 서버 `PartyStatus` enum 이름(ACTIVE/COMPLETED/MATCHING/DRIVER_ASSIGNED/IN_RIDE/FINISHED/CANCELED).
    public var status: String
    /// 합류 **직후**의 인원. 서버 record 가 `Integer` 이고 값은 `party.getMembers().size()` 라 운영에서는
    /// 늘 1 이상이 실린다. 그래도 non-null 로 두지 않는 이유는 **여기서의 파싱 실패 대가가 가장 크기**
    /// 때문이다: 합류는 서버가 멤버 추가를 먼저 커밋하고 응답을 만들므로, 응답을 못 읽으면 앱은 실패로
    /// 보는데 서버에는 내가 들어가 있어 그 계정이 30분 스윕 전까지 **어떤 방에도 못 들어간다**
    /// (PartyMappersTest 「합류 응답 JSON 을 …」 참고). 명시적 null 하나로 그 상태를 만들지 않는다.
    public var currentMembers: Int?

    public init(status: String = "", currentMembers: Int? = nil) {
        self.status = status
        self.currentMembers = currentMembers
    }

    /// 직렬화 계약(JSON 키 이름·순서). `PartyMappersTest` 가 필드가 딱 둘임을 못 박는다.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case status, currentMembers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeOrDefault(.status, default: "")
        currentMembers = try c.decodeIfPresent(Int.self, forKey: .currentMembers)
    }
}

/// POST /api/v1/matching/rooms 요청 본문 (백엔드 `OpenPartyRequest`).
///
/// **생성자 id 필드는 없다.** 서버 record 에 `creatorId` 가 구버전 호환으로 남아 있지만
/// `toCommand()` 가 그 값을 버리고 `@CurrentUser` 로 받은 토큰 주체를 쓴다 — 보내 봐야 무시되는
/// 값이라 아예 싣지 않는다. 되살리면 "앱이 보낸 생성자"가 유효하다는 착각을 부른다.
///
/// **반경 필드도 없다**(Backend `a668aee`). `departureRadius`·`destinationRadius` 가 서버 record 에서
/// 빠지고 서버가 고정값(`Radius.DEFAULT` = 500m)을 쓴다. 계속 보내도 서버는 모르는 키로 흘려 버리므로
/// (Jackson 기본 동작) 되살리면 **사용자가 고른 값이 조용히 버려지는** 상태로 돌아간다.
/// 응답에는 반경이 남아 있지만 그건 서버가 정한 값이다(`PartyDetailResponse.departureRadius`).
public struct OpenPartyRequestDto: Codable, Equatable, Sendable {
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

// POST /api/v1/matching/rooms 응답 (백엔드 OpenPartyResponse — members 목록이 없다)
public struct OpenPartyResponse: Decodable, Equatable, Sendable {
    public var id: Int64
    public var departureLat: Double?
    public var departureLng: Double?
    public var destinationLat: Double?
    public var destinationLng: Double?
    public var departure: String
    public var destination: String
    public var capacity: Int
    /// 방을 만든 **직후**의 인원이라 서버에서는 늘 1(생성자 본인)이다. 그래도 non-null 로 두지 않는 건
    /// 목록·상세와 같은 이유다(`PartyListResponse.PartyItem.currentMembers`): 0 은 서버가 만들 수 없는
    /// 값이고, 명시적 null 은 파싱을 터뜨린다 — 방은 이미 만들어졌는데 앱만 실패로 보는 상태가 된다.
    /// 모르면 매퍼가 멤버를 **지어내지 않고** 빈 목록으로 남긴다(`toRide`).
    public var currentMembers: Int?
    /// 서버 고정값(500m). 요청에 없는 값이고 도메인으로도 옮기지 않는다 — `PartyDetailResponse.departureRadius` 참고.
    public var departureRadius: Int
    public var destinationRadius: Int
    public var status: String
    public var createdAt: String?
    public var estimateFare: Int?
    public var estimateTime: Int?
    public var route: String?
    public var taxiDriverId: Int64?

    public init(
        id: Int64,
        departureLat: Double? = nil,
        departureLng: Double? = nil,
        destinationLat: Double? = nil,
        destinationLng: Double? = nil,
        departure: String = "",
        destination: String = "",
        capacity: Int = 0,
        currentMembers: Int? = nil,
        departureRadius: Int = 0,
        destinationRadius: Int = 0,
        status: String = "",
        createdAt: String? = nil,
        estimateFare: Int? = nil,
        estimateTime: Int? = nil,
        route: String? = nil,
        taxiDriverId: Int64? = nil
    ) {
        self.id = id
        self.departureLat = departureLat
        self.departureLng = departureLng
        self.destinationLat = destinationLat
        self.destinationLng = destinationLng
        self.departure = departure
        self.destination = destination
        self.capacity = capacity
        self.currentMembers = currentMembers
        self.departureRadius = departureRadius
        self.destinationRadius = destinationRadius
        self.status = status
        self.createdAt = createdAt
        self.estimateFare = estimateFare
        self.estimateTime = estimateTime
        self.route = route
        self.taxiDriverId = taxiDriverId
    }

    private enum CodingKeys: String, CodingKey {
        case id, departureLat, departureLng, destinationLat, destinationLng, departure, destination, capacity
        case currentMembers, departureRadius, destinationRadius, status, createdAt
        case estimateFare, estimateTime, route, taxiDriverId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        departureLat = try c.decodeIfPresent(Double.self, forKey: .departureLat)
        departureLng = try c.decodeIfPresent(Double.self, forKey: .departureLng)
        destinationLat = try c.decodeIfPresent(Double.self, forKey: .destinationLat)
        destinationLng = try c.decodeIfPresent(Double.self, forKey: .destinationLng)
        departure = try c.decodeOrDefault(.departure, default: "")
        destination = try c.decodeOrDefault(.destination, default: "")
        capacity = try c.decodeOrDefault(.capacity, default: 0)
        currentMembers = try c.decodeIfPresent(Int.self, forKey: .currentMembers)
        departureRadius = try c.decodeOrDefault(.departureRadius, default: 0)
        destinationRadius = try c.decodeOrDefault(.destinationRadius, default: 0)
        status = try c.decodeOrDefault(.status, default: "")
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        estimateFare = try c.decodeIfPresent(Int.self, forKey: .estimateFare)
        estimateTime = try c.decodeIfPresent(Int.self, forKey: .estimateTime)
        route = try c.decodeIfPresent(String.self, forKey: .route)
        taxiDriverId = try c.decodeIfPresent(Int64.self, forKey: .taxiDriverId)
    }
}

// GET /api/v1/matching/rooms/{partyId}/driver — 백엔드 driver/api/DriverSummary
// 기사 이름·별점 필드는 서버에 없다.
public struct DriverSummaryResponse: Decodable, Equatable, Sendable {
    public var seats: Int?
    public var plateNumber: String
    /// 차종. 서버 필드명이 type 이다.
    public var type: String

    public init(seats: Int? = nil, plateNumber: String = "", type: String = "") {
        self.seats = seats
        self.plateNumber = plateNumber
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case seats, plateNumber, type
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seats = try c.decodeIfPresent(Int.self, forKey: .seats)
        plateNumber = try c.decodeOrDefault(.plateNumber, default: "")
        type = try c.decodeOrDefault(.type, default: "")
    }
}

// POST /api/v1/matching/routes — 백엔드 RouteRequest / RouteEstimate
// 컨트롤러가 도메인 record RouteEstimate 를 그대로 반환한다(RoutePreviewResponse 와 필드명 동일).
// Integer 필드라 null 이 올 수 있어 셋 다 nullable + 기본값으로 방어한다.
public struct RouteRequestDto: Codable, Equatable, Sendable {
    public var departureLat: Double
    public var departureLng: Double
    public var destinationLat: Double
    public var destinationLng: Double

    public init(departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double) {
        self.departureLat = departureLat
        self.departureLng = departureLng
        self.destinationLat = destinationLat
        self.destinationLng = destinationLng
    }
}

public struct RouteEstimateResponse: Decodable, Equatable, Sendable {
    public var estimateFare: Int?
    public var estimateTime: Int?
    /// Google Encoded Polyline. 서버 필드명이 path 다(방 상세의 route 와 같은 형식).
    public var path: String?

    public init(estimateFare: Int? = nil, estimateTime: Int? = nil, path: String? = nil) {
        self.estimateFare = estimateFare
        self.estimateTime = estimateTime
        self.path = path
    }
}

// POST /api/v1/matching/rooms/realtime — 백엔드 RealTimeMatchingRequest / List<MatchCandidate>
//
// **요청과 응답의 좌표 필드명이 다르다.** 요청은 destLat/destLng, 응답은 destinationLat/destinationLng.
// 서버 record 필드명을 그대로 쓴 결과이고, 여기서 RouteRequestDto 를 복사해 쓰면 destinationLat 이
// 그대로 남아 서버에 0.0 이 가고 **400 OUT_OF_SERVICE_AREA** 가 떨어진다(전부 primitive double 이라
// 누락이 0.0 이 되고, (0,0) 은 서비스 지역 밖이다). 그 400 을 받으면 사용자 위치 문제가 아니라
// 이 DTO 의 필드명을 먼저 의심해야 한다.
public struct RealTimeMatchingRequestDto: Codable, Equatable, Sendable {
    public var departureLat: Double
    public var departureLng: Double
    /// 서버 record 필드명 그대로. **destinationLat 이 아니다.**
    public var destLat: Double
    /// 서버 record 필드명 그대로. **destinationLng 이 아니다.**
    public var destLng: Double

    public init(departureLat: Double, departureLng: Double, destLat: Double, destLng: Double) {
        self.departureLat = departureLat
        self.departureLng = departureLng
        self.destLat = destLat
        self.destLng = destLng
    }
}

/// 실시간 매칭 후보 하나. **응답 최상위가 이 타입의 배열**이라 `{"list":[...]}` 래퍼가 없다.
///
/// 서버가 출발지·도착지 각각 300m 반경(AND)으로 거른 뒤 OSRM 도보 시간 합으로 정렬해 **0~5개**를 준다.
/// 빈 배열은 **정상**이다 — 양쪽 300m 를 동시에 만족해야 해서 초기에는 그게 기본 상태다.
public struct MatchCandidateResponse: Decodable, Equatable, Sendable {
    public var summary: NearbyPartySummaryDto?
    /// 도보 시간 **합**(초) = 내 출발지→방 출발지 + 방 도착지→내 목적지.
    /// **차 타는 시간은 안 들어 있다** — 도메인에서 이름을 walkSeconds 로 바꿔 오독을 막는다.
    public var totalSeconds: Int

    public init(summary: NearbyPartySummaryDto? = nil, totalSeconds: Int = 0) {
        self.summary = summary
        self.totalSeconds = totalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case summary, totalSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(NearbyPartySummaryDto.self, forKey: .summary)
        totalSeconds = try c.decodeOrDefault(.totalSeconds, default: 0)
    }

    /// 서버 `NearbyPartySummary`. 전부 박스 타입이라 이론상 null 이 올 수 있어 기본값으로 방어한다.
    ///
    /// **요금·경로는 여전히 없다.** 요금은 합류 화면(19)이 방 상세를 읽어 채운다. 상태는 서버 쿼리가
    /// `status = 'ACTIVE'` 로 못 박혀 있어 모집 중으로 단정할 수 있다.
    public struct NearbyPartySummaryDto: Decodable, Equatable, Sendable {
        /// 방 id. **기존 목록의 `partyId` 와 이름이 다르다.**
        public var id: Int64
        public var departureLat: Double?
        public var departureLng: Double?
        public var destinationLat: Double?
        public var destinationLng: Double?
        public var departure: String
        public var destination: String
        public var capacity: Int
        /// 지금 합류한 인원(Backend #260). **옛 배포에는 이 필드가 없어 null 이 온다.**
        ///
        /// `Int = 0` 으로 두면 안 된다. 후보는 `status = 'ACTIVE'` 인 방만 오고 그런 방에는 최소
        /// 방장 1명이 있으므로 **0 은 나올 수 없는 값**이다. 0 으로 접으면 화면이 「0/3명」이라는
        /// 없는 상태를 그리게 되므로, 모른다는 뜻의 null 과 구별해 둔다.
        public var currentMembers: Int?

        public init(
            id: Int64 = 0,
            departureLat: Double? = nil,
            departureLng: Double? = nil,
            destinationLat: Double? = nil,
            destinationLng: Double? = nil,
            departure: String = "",
            destination: String = "",
            capacity: Int = 0,
            currentMembers: Int? = nil
        ) {
            self.id = id
            self.departureLat = departureLat
            self.departureLng = departureLng
            self.destinationLat = destinationLat
            self.destinationLng = destinationLng
            self.departure = departure
            self.destination = destination
            self.capacity = capacity
            self.currentMembers = currentMembers
        }

        private enum CodingKeys: String, CodingKey {
            case id, departureLat, departureLng, destinationLat, destinationLng
            case departure, destination, capacity, currentMembers
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeOrDefault(.id, default: 0)
            departureLat = try c.decodeIfPresent(Double.self, forKey: .departureLat)
            departureLng = try c.decodeIfPresent(Double.self, forKey: .departureLng)
            destinationLat = try c.decodeIfPresent(Double.self, forKey: .destinationLat)
            destinationLng = try c.decodeIfPresent(Double.self, forKey: .destinationLng)
            departure = try c.decodeOrDefault(.departure, default: "")
            destination = try c.decodeOrDefault(.destination, default: "")
            capacity = try c.decodeOrDefault(.capacity, default: 0)
            currentMembers = try c.decodeIfPresent(Int.self, forKey: .currentMembers)
        }
    }
}
