/// 탑승 기록 한 페이지. 커서 페이징의 결과다.
///
/// `ChatMessagePage` 와 **같은 모양으로 맞춰 두었다**(목록 · nextCursor · hasNext) — 이 앱에서
/// 커서 페이징은 그 하나가 선례이고, 모양이 다르면 화면마다 「더 불러올 것이 있는가」를 다른 식으로
/// 판정하게 된다.
///
/// `nextCursor` 는 `hasNext` 가 true 일 때만 값이 있다. **`hasNext` 만 보고 다음 페이지를 불러라**
/// — false 인데 부르면 커서 없이 첫 페이지를 다시 받아 목록이 무한히 중복된다.
public struct RideRecordPage: Hashable, Sendable {
    public var records: [RideRecord]
    public var nextCursor: Int64?
    public var hasNext: Bool

    public init(records: [RideRecord], nextCursor: Int64?, hasNext: Bool) {
        self.records = records
        self.nextCursor = nextCursor
        self.hasNext = hasNext
    }
}

/// 끝난 탑승 한 건. 서버 `GET /api/v1/users/me/parties` 의 한 항목.
///
/// ### 상태가 없다
/// 이 목록에는 **하차까지 끝난 탑승만** 들어온다(서버가 `dropoffTime is not null` 로 거른다).
/// 그래서 `RideStatus` 를 붙이지 마라 — 전부 같은 값이 되어 화면이 뜻 없는 칩을 그린다.
/// 진행 중인 방은 여기 **절대** 나오지 않는다(실측 2026-11-01, 로컬 `:8080`: `status=MATCHING`
/// 방을 가진 계정이 불러도 빈 배열). 「지금 내가 타고 있는 방」은
/// `ActivePartyRepository` 의 몫이고 둘은 서로를 대체하지 않는다.
///
/// ### 요금이 null 인 것은 결함이 아니다
/// `totalFare`·`farePerPerson`·`pickupTime` 이 null 인 기록은 **1차 모드**다(기사 없이 방장이
/// 합승 종료). 화면은 그때 요금 줄을 **그리지 않는다** — 0원으로 보여 주면 「공짜로 탔다」는
/// 거짓말이 된다. 이 저장소가 거짓 문구를 들어낸 이력이 있어 더더욱 그렇다.
///
/// ### 시각은 문자열이다
/// 서버가 주는 ISO-8601 문자열을 그대로 들고 있는다 — `ChatMessage.createdAt` 과 같은 방식이다.
/// 도메인에서 `Date` 로 바꾸면 이 앱에 시각 변환이 두 벌 생긴다(화면이 이미 기기 시간대로
/// 바꿔 쓰는 함수를 갖고 있다). 파싱 실패는 화면이 「날짜 칸을 비운다」로 처리한다.
public struct RideRecord: Hashable, Sendable {
    public var partyId: Int64
    /// 출발지 이름. 서버가 주지 않으면 빈 문자열(매퍼가 접는다) — 화면이 null 을 또 확인하지 않게.
    public var departure: String
    public var destination: String
    /// 기사가 탑승 처리한 시각(ISO-8601). 1차 모드 기록은 null.
    public var pickupTime: String?
    /// 하차 시각(ISO-8601). 목록에 들어오는 조건이라 사실상 항상 있다. 서버 정렬 기준(최신순).
    public var dropoffTime: String?
    /// 실제로 낸 총 요금. null 이면 1차 모드 기록 — 요금을 **그리지 않는다**.
    public var totalFare: Int?
    /// 서버가 계산한 1인 부담(`totalFare / memberCount` 내림). **앱이 다시 나누지 않는다** —
    /// 앱의 예상 요금 계산은 10원 단위로 맞추므로 끌어다 쓰면 실제 결제액과 어긋난다.
    public var farePerPerson: Int?
    /// 나를 포함해 함께 탄 인원. **정원이 아니다** — 서버가 정원을 주지 않아 「2/3명」은 못 만든다.
    public var memberCount: Int
    public var members: [RideRecordMember]

    public init(
        partyId: Int64,
        departure: String,
        destination: String,
        pickupTime: String?,
        dropoffTime: String?,
        totalFare: Int?,
        farePerPerson: Int?,
        memberCount: Int,
        members: [RideRecordMember]
    ) {
        self.partyId = partyId
        self.departure = departure
        self.destination = destination
        self.pickupTime = pickupTime
        self.dropoffTime = dropoffTime
        self.totalFare = totalFare
        self.farePerPerson = farePerPerson
        self.memberCount = memberCount
        self.members = members
    }
}

/// 함께 탄 사람.
///
/// `User` 를 재사용하지 않는다 — 서버가 `host`·`rideCount`·`badgeId` 를 주지 않아 `User` 의 그
/// 필드들이 전부 거짓값(false·0·빈 문자열)이 되고, 화면이 그걸 진짜 값으로 읽어 「첫 탑승」·
/// 「인증 정보 없음」 같은 문구를 **없는 근거로** 그린다.
public struct RideRecordMember: Hashable, Sendable {
    /// 서버 `publicId`. 사용자 요약이 없으면 빈 문자열 — 그때는 프로필로 넘어갈 대상이 없다
    /// (`MemberDisplay` 의 `isWithdrawn` 과 같은 규칙).
    public var id: String
    /// 표시 이름. 서버가 탈퇴한 사용자의 이름 자리에 `"탈퇴한 사용자"` 를 직접 넣어 보내므로
    /// 앱이 따로 치환하지 않는다(`WithdrawnMemberNames.SERVER_DELETED`).
    public var nickname: String
    public var imageUrl: String?
    /// 이 사람이 나인가. 서버가 `isMe` 를 주지 않아 `publicId == UserSession.currentUserUuid` 로
    /// 앱이 만든다 — 액세스 토큰 `sub` 가 publicId 와 같은 값이라 이 비교가 곧 「나」다(실측 확인).
    ///
    /// **`publicId` null 가드가 빠지면 미로그인 상태에서 요약 없는 멤버가 "나"가 된다**
    /// (`null == null` → true). 매퍼가 그 가드를 들고 있다.
    public var isMe: Bool

    public init(id: String, nickname: String, imageUrl: String?, isMe: Bool) {
        self.id = id
        self.nickname = nickname
        self.imageUrl = imageUrl
        self.isMe = isMe
    }
}
