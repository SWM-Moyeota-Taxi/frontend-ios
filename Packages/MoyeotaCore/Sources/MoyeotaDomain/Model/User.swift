/// 파티 참여자를 화면에 그리기 위한 표시용 모델. 서버 `PartyDetailResult.MemberInfo` 가 출처다.
///
/// `id` 는 서버 `publicId`(UUID v7, JWT `sub` 와 같은 값)다. **탈퇴 등으로 유저 요약이 없으면
/// 서버가 publicId·nickname·imageUrl 을 전부 null 로 내리므로 그때는 빈 문자열이다**
/// — 화면은 빈 id 를 "탭 불가"로 다뤄야 한다(프로필로 넘어갈 대상이 없다).
///
/// `rating` 은 지금 항상 0.0 이다. 평가 API 자체가 서버에 없다 —
/// 화면은 0.0 을 "평가 없음"으로 표시해야 하며, 4.9·매너 98% 같은 가짜 값을 지어내면 안 된다.
/// `verifiedLabel` 도 같은 처지다: 서버 `badgeId` 가 TODO 라 항상 null 이므로 빈 문자열이 온다.
public struct User: Hashable, Sendable {
    public var id: String
    public var nickname: String
    public var verifiedLabel: String // 예: "성결대 인증", "직장 인증"
    public var rating: Double
    public var rideCount: Int
    /// 프로필 이미지 URL(전체 주소). `MemberAvatar` 가 이것을 그리고, 못 그리면 닉네임 첫 글자 원으로
    /// 되돌아간다.
    ///
    /// **null 을 "이미지 없음"으로 읽지 말 것.** 2026-10-15 배포(Backend #235)부터 서버는 고른 적
    /// 없는 사용자에게도 **기본 이미지의 전체 URL** 을 준다. 여기가 null 인 경우는 사실상 하나뿐인데,
    /// 그건 유저 요약 자체가 없는 멤버(탈퇴 등)라 publicId·nickname 과 **함께** null 로 오는 경우다.
    /// 그 판정은 `id` 가 비었는지로 한다(`User.isWithdrawn`) — 이 필드로 하지 마라.
    public var imageUrl: String?
    /// 이 멤버가 로그인한 본인인가. `publicId == UserSession.currentUserUuid` 로 판정한다.
    ///
    /// 기본값이 false 인 건 **식별자가 없는 응답**(목록·방 생성) 때문이다 — 그쪽 자리 표시용 멤버는
    /// 누가 나인지 알 방법이 없다. 상세/합류 응답에서만 실제로 채워진다.
    public var isMe: Bool
    /// 이 멤버가 방장인가. 서버 `PartyDetailResult.MemberInfo.host` 가 출처다(Backend #240).
    ///
    /// **앱이 추정하지 않는다.** 서버의 방장은 *저장값이 아니라 파생값*이다 — `Party.hostId()` =
    /// 현재 멤버 중 `min(joinedAt, memberId)`. 그래서 멤버 구성이 바뀔 때마다 달라지고, 판별의 단일
    /// 창구는 서버 `Party.isHost(memberId)` 뿐이다. 앱이 입장 순서나 목록 첫째 원소로 흉내 내면
    /// 서버가 거부하는 사람에게 방장 권한을 보여 준다(예전 `joinedAt` 추정이 지워진 이유다).
    ///
    /// 기본값이 false 인 건 **서버가 멤버를 설명해 주지도 않은 자리** 때문이다 — 목록·방 생성 응답의
    /// 자리 표시용 멤버가 그렇다. 그쪽은 식별자조차 없어 `isMe` 도 false 라 이 값을 읽는 쪽이 없다.
    /// 서버가 멤버는 설명했지만 `host` 만 빠뜨린 경우의 처리는 **다르다** —
    /// `PartyMappers` 의 `toUser` 에 근거와 함께 적어 두었다.
    ///
    /// 화면이 「내가 방장인가」를 물을 때는 이 필드를 직접 훑지 말고 `Ride.isHostedByMe` 를 쓴다.
    public var isHost: Bool

    public init(
        id: String,
        nickname: String,
        verifiedLabel: String,
        rating: Double,
        rideCount: Int,
        imageUrl: String? = nil,
        isMe: Bool = false,
        isHost: Bool = false
    ) {
        self.id = id
        self.nickname = nickname
        self.verifiedLabel = verifiedLabel
        self.rating = rating
        self.rideCount = rideCount
        self.imageUrl = imageUrl
        self.isMe = isMe
        self.isHost = isHost
    }
}

/// 멤버의 이름 자리에 **사람 이름이 아닌 것**이 들어오는 두 경우의 문자열 — 한 곳에 모아 둔다.
///
/// 흩어 놓으면 둘 중 하나를 못 걸러 안내문이 **지킬 수 없는 약속**을 한다(「다 타면 방장 탈퇴한
/// 사용자님이 「합승 완료」를 눌러…」 — 그 사람은 영원히 누를 수 없다). 그래서 넣는 쪽(데이터 매퍼)과
/// 거르는 쪽(화면)이 **같은 상수**를 본다.
///
/// | 상수 | 넣는 쪽 | 서버 쪽 사실 |
/// |---|---|---|
/// | `SERVER_DELETED` | **서버** (`user/users/domain/User.DELETED_DISPLAY_NAME`) | **soft delete** 다 — `publicId` 는 **살아 있고** 닉네임만 이 상수로 가려진다(`isDeleted() ? DELETED_DISPLAY_NAME : nickname`) |
/// | `NO_SUMMARY` | **앱 매퍼** (`PartyMappers.toUser`) | 서버가 유저 요약 자체를 못 찾아 `MemberInfo` 의 publicId·nickname·imageUrl 을 **전부 null** 로 내린 경우 |
///
/// **두 경우를 하나로 접지 말 것.** 모양이 다르다: 앞은 식별자가 있어 프로필로 들어갈 수 있고(배지도
/// 붙는다), 뒤는 식별자가 없어 탭조차 막아야 한다(`User.isWithdrawn` = `id` 가 빈 값). 겹치는 것은
/// **이름으로 부를 수 없다**는 한 가지뿐이고, 그 판정만 `ALL` 로 함께 한다.
public enum WithdrawnMemberNames {

    /// 서버가 soft delete 된 사용자의 닉네임 자리에 직접 넣는 값. publicId 는 살아 있다.
    public static let SERVER_DELETED = "탈퇴한 사용자"

    /// 유저 요약이 없는 멤버(전 필드 null)에 **앱이** 채우는 자리값.
    public static let NO_SUMMARY = "탈퇴한 회원"

    /// 어느 쪽이든 **사람 이름이 아니다** — 이름으로 부르는 문구에서 걸러야 한다.
    public static let ALL: Set<String> = [SERVER_DELETED, NO_SUMMARY]
}

/// 로그인한 본인의 서버 기준 신원. GET /api/v1/local/users/info 의 결과다.
///
/// 같은 파일의 `User` 와는 쓰임이 다르다 — `User` 는 파티 참여자를 화면에 그리기 위한 표시용 모델이고,
/// 이쪽은 **서버가 확인해 준 "나"** 다. 별점·인증 라벨 같은 건 이 엔드포인트가 주지 않는다.
///
/// `name` 이 nullable 인 이유: 서버가 "닉네임 → 프로필 실명 → null" 순으로 폴백하기 때문이다.
/// 현재 서버에는 닉네임을 설정하는 경로가 없어 사실상 항상 실명이 오지만, 프로필이 비어 있으면 null 이다.
/// **화면은 null 을 반드시 처리해야 한다** — "이름 없음" 폴백 문구든, 이름 영역 숨김이든.
///
/// `uuid` 는 `AuthState.authenticated.userUuid` 와 같은 값이다(액세스 토큰 `sub`). 즉 uuid 만 필요하면
/// 이 호출은 필요 없다 — 이 엔드포인트를 부르는 이유는 `name` 과 `imageUrl` 이다.
public struct UserProfileInfo: Hashable, Sendable {
    public var uuid: String
    public var name: String?
    /// 내 프로필 이미지 URL(전체 주소). **서버는 이 값을 비워 보내지 않는다** —
    /// 한 번도 고른 적 없는 사용자에게는 기본 이미지의 전체 주소를 준다
    /// (서버 `ProfileImages.toUrl` 이 key 가 null 이면 `default-key` 를 붙인다).
    ///
    /// 그래서 여기가 null 이면 "이미지가 없다"가 아니라 **응답을 못 받았거나 서버가 구버전**이라는 뜻이다.
    /// 화면은 그때 기존 이니셜/회색 원으로 떨어뜨린다.
    ///
    /// **끝이 `default.png` 인지로 「아직 안 고름」을 구분할 수 있다** — 기본 키는
    /// `GET /api/v1/users/profile-images` 목록(16장)에 들어 있지 않기 때문이다
    /// (`ProfileImage` 주석). 「기본 이미지로 되돌리기」를 켤지 끌지가 이 구분에 달려 있다.
    public var imageUrl: String?

    public init(uuid: String, name: String?, imageUrl: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.imageUrl = imageUrl
    }
}
