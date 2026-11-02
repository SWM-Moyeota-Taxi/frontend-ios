// 장소 검색 결과 1건. 백엔드 PlaceSearchResponse(name, roadName, latitude, longitude) 대응.
public struct Place: Hashable, Sendable {
    public var name: String
    public var roadName: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, roadName: String, latitude: Double, longitude: Double) {
        self.name = name
        self.roadName = roadName
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 좌표를 되짚은 주소 1건. 백엔드 AddressResponse 대응.
///
/// `address` 는 서버가 도로명 우선(없으면 지번)으로 조합해 준 표시 전용 값이라 항상 비어 있지 않다.
/// 앱에서 다시 조합하지 말고 그대로 노출한다 — 조합 규칙이 서버에 있어야 나중에 바뀌어도 앱이 안 깨진다.
/// `roadAddress` 는 시골/신규 필지처럼 도로명이 없는 좌표에서 null 이다.
public struct ReverseAddress: Hashable, Sendable {
    public var address: String
    public var roadAddress: String?
    public var jibunAddress: String?

    public init(address: String, roadAddress: String?, jibunAddress: String?) {
        self.address = address
        self.roadAddress = roadAddress
        self.jibunAddress = jibunAddress
    }
}

/// 자주 가는 장소. 백엔드 FavoritePlaceResponse 대응.
///
/// `id` 는 서버 `placeId` 다 — **삭제 3종이 전부 이 값으로 대상을 가리킨다.** 식별자가 없으면
/// 「이 줄을 지워라」를 표현할 길이 없어 오래 삭제 UI 를 못 만들었고, 그 동안 10칸을 채운 사용자는
/// 새 장소를 담을 수도 자리를 비울 수도 없어 **회원 탈퇴가 유일한 탈출구**였다. 그래서 non-null 이고,
/// 서버가 id 를 주지 않은 행은 매퍼가 **버린다**(0 으로 지어내면 그 한 건이 다중 선택 삭제 전체를
/// 404 로 실패시킨다 — 서버가 전부-아니면-전무다).
///
/// 이 값은 유저별이 아니라 테이블 전역 시퀀스라 **세션이 바뀌면 재조회해야 한다** — 다른 계정으로
/// 로그인한 뒤 들고 있던 id 를 쓰면 남의 행을 가리킨다(소유 검사는 서버가 하고, 실패는 404 다).
///
/// `sequence` 는 등록 순서(1부터)이고 목록 정렬 기준으로만 쓴다. **삭제 후 재번호되지 않는다** —
/// 중간을 지우면 1·2·5 처럼 구멍이 난 번호가 정상이다(서버에 순서 갱신 TODO 가 남아 있다).
/// 구멍을 보고 「목록이 깨졌다」고 판단해 보정 로직을 넣지 말 것.
public struct FavoritePlace: Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var roadName: String
    public var latitude: Double
    public var longitude: Double
    public var sequence: Int

    public init(
        id: Int64,
        name: String,
        roadName: String,
        latitude: Double,
        longitude: Double,
        sequence: Int
    ) {
        self.id = id
        self.name = name
        self.roadName = roadName
        self.latitude = latitude
        self.longitude = longitude
        self.sequence = sequence
    }
}
