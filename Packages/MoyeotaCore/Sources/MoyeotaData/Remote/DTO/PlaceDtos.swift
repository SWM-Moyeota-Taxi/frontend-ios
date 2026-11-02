// 백엔드 place/application/dto/*.java (origin/develop) 와 필드 1:1

// GET /api/v1/places?query=
public struct PlaceSearchListResponse: Decodable, Equatable, Sendable {
    public var list: [PlaceSearchItem]

    public init(list: [PlaceSearchItem] = []) {
        self.list = list
    }

    private enum CodingKeys: String, CodingKey {
        case list
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        list = try c.decodeOrDefault(.list, default: [])
    }

    public struct PlaceSearchItem: Decodable, Equatable, Sendable {
        // 장소명도 nullable 이다 — roadName 과 **같은 경로로 같은 null 이 올 수 있다.**
        // `KakaoPlaceClient.toPlaceOrNull()` 은 좌표 파싱(`Double.parseDouble(x/y)`)만 try 로 감싸므로
        // 좌표가 멀쩡하고 `place_name` 만 null 인 문서는 **걸러지지 않고** `new Place(null, …)` 로
        // 그대로 통과해 응답에 `"name": null` 로 실린다(서버 Place·PlaceSearchResponse 는 record 라
        // 검증이 없다). non-null 로 받으면 그 한 건이 **검색 결과 목록 전체**를 파싱 실패로 만든다.
        // 비면 15 목적지 검색 행의 제목 한 줄이 비는 것으로 끝난다(roadName 과 같은 처리) —
        // 다만 그 장소를 즐겨찾기로 저장하면 서버가 placeName 빈 값을 400 으로 막는다(의도된 실패다).
        public var name: String?
        // roadName 도 nullable 이다. 서버 place/search/domain/Place 는 record 라 검증이 없고,
        // KakaoPlaceClient 가 카카오의 road_address_name 을 그대로 담아 내보낸다 — 도로명이 없는
        // 장소(지번만 있는 건물·지하철역 등)에서 카카오가 null 을 주면 그 null 이 앱까지 온다.
        // 디코더(`decodeOrDefault`)는 **키 누락만** 기본값으로 떨어뜨리고 명시적 null 은 타입 예외라,
        // String 으로 두면 그런 장소 한 건 때문에 검색 결과 목록 전체가 파싱 실패한다.
        //
        // 전역에서 null 을 기본값으로 접지 않은 이유(원본의 coerceInputValues): 그 설정은 기본값을 가진 모든
        // non-null 필드에 걸려 accessToken(→ ""), chatRoomId(→ 0), 파티 status(→ "") 의 null 까지 조용히 삼킨다.
        // 빈 Bearer 로 401 루프를 도는 쪽이 파싱 실패보다 훨씬 늦게 발견된다. 그래서 범위를 여기로 좁혔다.
        public var roadName: String?
        // 좌표는 non-null 로 둬도 안전하다 — 서버가 `Double.parseDouble(doc.y()/doc.x())` 을 try 로
        // 감싸고 실패한 문서를 **목록에서 빼기 때문에**(`toPlaceOrNull` → `filter(Objects::nonNull)`)
        // 검색 응답에 좌표 없는 항목은 올 수 없다. 즐겨찾기 쪽은 사정이 달라 nullable 이다
        // (`FavoritePlaceListResponse.FavoritePlaceItem.latitude` 참고).
        public var latitude: Double
        public var longitude: Double

        public init(name: String? = nil, roadName: String? = nil, latitude: Double = 0.0, longitude: Double = 0.0) {
            self.name = name
            self.roadName = roadName
            self.latitude = latitude
            self.longitude = longitude
        }

        private enum CodingKeys: String, CodingKey {
            case name, roadName, latitude, longitude
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            roadName = try c.decodeIfPresent(String.self, forKey: .roadName)
            latitude = try c.decodeOrDefault(.latitude, default: 0.0)
            longitude = try c.decodeOrDefault(.longitude, default: 0.0)
        }
    }
}

// GET /api/v1/places/reverse?latitude=&longitude= (AddressResponse)
// address 는 서버가 roadAddress ?: jibunAddress 로 조합해 주는 표시용 값(Address.display()).
// 네이버 응답에서 roadaddr/addr 결과 중 하나만 오면 나머지가 null 이 되므로 세 필드 모두 nullable 로 방어한다.
// (실측: 35.0,128.0 → roadAddress=null)
public struct AddressResponseDto: Decodable, Equatable, Sendable {
    public var address: String?
    public var roadAddress: String?
    public var jibunAddress: String?

    public init(address: String? = nil, roadAddress: String? = nil, jibunAddress: String? = nil) {
        self.address = address
        self.roadAddress = roadAddress
        self.jibunAddress = jibunAddress
    }
}

// POST /api/v1/users/me/favorite-places?userId= 요청 본문 (FavoritePlaceRequest)
// 주의: 검색 응답은 name 인데 즐겨찾기 요청/응답은 placeName 이다. 이름이 다르다.
public struct FavoritePlaceRequestDto: Codable, Equatable, Sendable {
    public var placeName: String
    public var roadName: String
    public var latitude: Double
    public var longitude: Double

    public init(placeName: String, roadName: String, latitude: Double, longitude: Double) {
        self.placeName = placeName
        self.roadName = roadName
        self.latitude = latitude
        self.longitude = longitude
    }
}

// GET /api/v1/users/me/favorite-places?userId=
public struct FavoritePlaceListResponse: Decodable, Equatable, Sendable {
    public var places: [FavoritePlaceItem]

    public init(places: [FavoritePlaceItem] = []) {
        self.places = places
    }

    private enum CodingKeys: String, CodingKey {
        case places
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = try c.decodeOrDefault(.places, default: [])
    }

    public struct FavoritePlaceItem: Decodable, Equatable, Sendable {
        /// 삭제 대상을 가리키는 서버 식별자. **삭제 3종이 전부 이 값 하나에 걸려 있다.**
        ///
        /// 오래 「서버가 안 준다」로 적혀 있었지만 틀린 말이었다 — V19 마이그레이션이 PK 를
        /// (user_id, place_name) 복합키에서 단일키 `place_id` 로 바꾼 뒤 `FavoritePlaceResponse` 가
        /// 이 값을 담고 있다. **앱이 안 받고 있었을 뿐이다**(디코더가 모르는 키를 조용히 버렸다).
        /// 실측(2026-11-01, 로컬 `:8080`, `moyeota2`): 2건 등록 후 조회 응답에 `"placeId":19`·`20`.
        ///
        /// **nullable 로 두는 이유는 바로 아래 `latitude` 와 같다.** `FavoritePlaceResponse` 는 검증
        /// 없는 record 라 서버가 null 을 실을 길이 열려 있고, non-null 로 받으면 그 한 행이
        /// 파싱 예외로 **목록 전체**를 죽여 14 홈 즐겨찾기가 조용히 비고
        /// 15 목적지는 영구히 에러를 띄운다. 없는 항목은 매퍼가 그 한 건만 버린다
        /// (`toFavoritePlaceOrNull`).
        ///
        /// 이 값은 유저별이 아니라 **테이블 전역 시퀀스**다(실측: 다른 계정이 1·2·3 을 쓴 뒤
        /// 이 계정의 첫 항목이 4 였고, 이번 측정에서는 19 부터 나왔다). 소유 검사는 서버가 하므로
        /// 로컬에 캐시해 두고 다른 세션에서 쓰면 **남의 행을 가리킨다** — 세션이 바뀌면 재조회할 것.
        public var placeId: Int64?
        public var placeName: String
        // `PlaceSearchListResponse.PlaceSearchItem.roadName` 과 같은 이유로 nullable.
        // 검색에서 roadName 이 빈 장소를 즐겨찾기에 저장하면 서버가 받은 값을 그대로 보관하므로
        // 조회 응답에도 같은 값이 돌아온다 — 여기서 안 막으면 홈 진입마다 즐겨찾기 조회가 실패한다.
        public var roadName: String?
        /// 좌표. **바로 위 roadName 과 같은 함정이지만, 막는 곳이 서버에 생겼다.**
        ///
        /// 예전 주석은 「서버 방어가 0 건」이라고 적고 있었는데 **이제 틀린 말이다** —
        /// `FavoritePlace.from()` 이 좌표 null 과 서비스지역 밖을 400 `INVALID_COORDINATES` 로 막는다.
        /// 실측(2026-11-01, 로컬 `:8080`, `moyeota2`): 좌표 키 누락 → 400 `INVALID_COORDINATES`,
        /// (10.0, 10.0) → 400 `INVALID_COORDINATES`.
        ///
        /// **그래도 nullable 을 걷어내면 안 된다.** DB 는 여전히 `favorite_place.latitude`·`longitude`
        /// 가 **NULL 허용**이라(`place_name`·`user_id`·`place_id` 만 not null) 이 검증이 들어오기 전에
        /// 만들어진 레거시 행이 남아 있을 수 있다. 그런 행 하나로 non-null 파싱이 터지면
        /// `GET /api/v1/users/me/favorite-places` **응답 전체**가 날아가
        /// ① 14 홈은 실패를 빈 목록으로 접어 **아무 표시 없이** 즐겨찾기가 비고
        /// (사용자는 자기 즐겨찾기가 지워진 줄 안다) ② 15 목적지는 「자주 가는 곳을 불러오지 못했어요」가
        /// **영구히** 뜬다. 그래서 좌표 없는 항목은 매퍼가 **그 한 건만 버린다**
        /// (`toFavoritePlaceOrNull`).
        ///
        /// ★ 버린 행은 **사용자 눈에만 안 보이고 서버에서는 10칸 중 하나를 계속 차지한다.** 목록에서
        /// 고를 수 없으니 per-item 삭제로는 닿지 못한다 — `DELETE .../favorite-places/all`
        /// (전체 삭제)이 그 행을 치우는 **유일한 탈출구**다. 14 홈의 「전체 삭제」를 지우지 말 것.
        public var latitude: Double?
        /// 좌표. 근거는 `latitude` 와 같다.
        public var longitude: Double?
        /// 목록 정렬 순번. 서버 `FavoritePlaceService.save()` 가 늘 `max + 1` 로 채우므로(그리고 그
        /// 계산이 `mapToInt(getPlaceSequence)` 라 **null 인 행이 있으면 서버의 등록 자체가 NPE 로 깨진다**)
        /// null 은 「서버도 다룰 수 없는 행」이라는 뜻이다. 그래서 매퍼는 이 값을 0 으로 접지 않고
        /// **정렬 맨 뒤**로 보낸다 — 0 으로 접으면 그 행이 「집」(sequence 1) 앞으로 올라와 사용자가
        /// 직접 정한 순서를 흔든다.
        public var placeSequence: Int?

        public init(
            placeId: Int64? = nil,
            placeName: String = "",
            roadName: String? = nil,
            latitude: Double? = nil,
            longitude: Double? = nil,
            placeSequence: Int? = nil
        ) {
            self.placeId = placeId
            self.placeName = placeName
            self.roadName = roadName
            self.latitude = latitude
            self.longitude = longitude
            self.placeSequence = placeSequence
        }

        private enum CodingKeys: String, CodingKey {
            case placeId, placeName, roadName, latitude, longitude, placeSequence
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            placeId = try c.decodeIfPresent(Int64.self, forKey: .placeId)
            placeName = try c.decodeOrDefault(.placeName, default: "")
            roadName = try c.decodeIfPresent(String.self, forKey: .roadName)
            latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
            longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
            placeSequence = try c.decodeIfPresent(Int.self, forKey: .placeSequence)
        }
    }
}

/// POST /api/v1/users/me/favorite-places/batch-delete 요청 본문 (FavoritePlaceDeleteRequest).
///
/// **키 이름이 `placeIds` 인 것이 이 타입의 전부다.** 서버는 모르는 키를 조용히 무시하므로
/// 이름을 틀리면 컴파일도 실행도 통과한 뒤 400 `INVALID_PLACE_IDS` 로만 드러난다
/// (실측(2026-11-01, 로컬 `:8080`): `{"ids":[2]}` → 400 `INVALID_PLACE_IDS`,
/// `{"placeIds":[]}` → 400 `INVALID_PLACE_IDS`). 그래서
/// `PlaceApiDeleteTest` 가 직렬화 결과 문자열을 못 박는다.
///
/// 개수 제한은 **서버가 강제하지 않는다** — 메시지는 「1개 이상 100개 이하」지만
/// `FavoritePlaceDeleteRequest` 에 `@Size` 가 없고 컨트롤러 `@RequestBody` 에 `@Valid` 도 없다
/// (실측: 없는 id 101개·5000개 모두 개수 검사를 통과해 404 로 떨어졌다).
/// 등록 상한이 10개라 앱이 실제로 보내는 id 는 최대 10개다.
public struct FavoritePlaceDeleteRequestDto: Codable, Equatable, Sendable {
    public var placeIds: [Int64]

    public init(placeIds: [Int64]) {
        self.placeIds = placeIds
    }
}
