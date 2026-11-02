import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

@Suite struct PlaceMappersTest {

    @Test("장소 검색 응답을 Place 로 매핑한다")
    func mapsSearchItem() {
        let item = PlaceSearchListResponse.PlaceSearchItem(
            name: "성결대학교",
            roadName: "경기 안양시 만안구 성결대학로 53",
            latitude: 37.3799,
            longitude: 126.9310
        )

        let place = item.toPlace()

        #expect(place.name == "성결대학교")
        #expect(place.roadName == "경기 안양시 만안구 성결대학로 53")
        #expect(isClose(37.3799, place.latitude, 0.0001))
        #expect(isClose(126.9310, place.longitude, 0.0001))
    }

    // 검색은 name, 즐겨찾기는 placeName 으로 서버 필드명이 다르다 — 매퍼가 이 차이를 흡수해야 한다.
    @Test("즐겨찾기 응답의 placeName 을 도메인 name 으로 매핑한다")
    func mapsFavoritePlaceName() throws {
        let item = FavoritePlaceListResponse.FavoritePlaceItem(
            placeId: 7,
            placeName: "집",
            roadName: "서울 강남구 테헤란로 123",
            latitude: 37.5013,
            longitude: 127.0396,
            placeSequence: 2
        )

        let favorite = try #require(item.toFavoritePlaceOrNull())

        #expect(favorite.name == "집")
        #expect(favorite.sequence == 2)
    }

    @Test("즐겨찾기 등록 요청은 name 을 placeName 으로 보낸다")
    func favoriteRequestUsesPlaceName() {
        let dto = Place(
            name: "회사",
            roadName: "경기 성남시 분당구 판교역로 166",
            latitude: 37.3948,
            longitude: 127.1112
        ).toFavoriteRequestDto()

        #expect(dto.placeName == "회사")
        #expect(dto.roadName == "경기 성남시 분당구 판교역로 166")
    }

    @Test("검색 결과가 없거나 list 키가 누락돼도 빈 목록으로 처리한다")
    func missingListKey() throws {
        let decoded = try decodeJSON(PlaceSearchListResponse.self, "{}")

        #expect(decoded.list == [])
    }

    @Test("실제 서버 응답 JSON 을 그대로 역직렬화한다")
    func decodesServerJSON() throws {
        let body = """
            {"list":[{"name":"판교역","roadName":"경기 성남시 분당구 판교역로 160","latitude":37.3947,"longitude":127.1112}]}
            """

        let decoded = try decodeJSON(PlaceSearchListResponse.self, body)

        #expect(decoded.list.count == 1)
        #expect(decoded.list[0].toPlace().name == "판교역")
    }

    // --- roadName null 방어 ---
    // 서버 Place 는 record 라 검증이 없어 카카오가 road_address_name 에 null 을 주면 그대로 내보낸다.
    // 명시적 null 은 기본값으로 떨어지지 않으므로, nullable 로 받지 않으면 한 건 때문에 목록 전체가 날아간다.
    // 운영과 같은 디코더(`MoyeotaJSON`)로 디코딩해야 실제 경로를 검증하는 것이 된다.

    @Test("검색 결과에 roadName 이 null 인 장소가 섞여도 목록 전체가 살아남는다")
    func searchListWithNullRoadName() throws {
        let body = """
            {"list":[
              {"name":"판교역","roadName":"경기 성남시 분당구 판교역로 160","latitude":37.3947,"longitude":127.1112},
              {"name":"도로명없는가게","roadName":null,"latitude":37.5665,"longitude":126.9780}
            ]}
            """

        let places = try decodeJSON(PlaceSearchListResponse.self, body).list.map { $0.toPlace() }

        #expect(places.count == 2)
        // null 인 항목만 빈 도로명이 되고 나머지 필드는 보존된다.
        #expect(places[1].name == "도로명없는가게")
        #expect(places[1].roadName == "")
        #expect(isClose(37.5665, places[1].latitude, 0.0001))
        #expect(isClose(126.9780, places[1].longitude, 0.0001))
        // 앞 항목은 영향을 받지 않는다 — 한 건의 null 이 목록을 오염시키지 않는지가 핵심이다.
        #expect(places[0].name == "판교역")
        #expect(places[0].roadName == "경기 성남시 분당구 판교역로 160")
    }

    @Test("즐겨찾기 목록에 roadName 이 null 인 장소가 섞여도 목록 전체가 살아남는다")
    func favoriteListWithNullRoadName() throws {
        let body = """
            {"places":[
              {"placeId":1,"placeName":"집","roadName":"서울 강남구 테헤란로 123","latitude":37.5013,"longitude":127.0396,"placeSequence":1},
              {"placeId":2,"placeName":"도로명없는가게","roadName":null,"latitude":37.5665,"longitude":126.9780,"placeSequence":2}
            ]}
            """

        let favorites = try decodeJSON(FavoritePlaceListResponse.self, body).toFavoritePlaces()

        #expect(favorites.count == 2)
        #expect(favorites[1].name == "도로명없는가게")
        #expect(favorites[1].roadName == "")
        #expect(favorites[1].sequence == 2)
        #expect(favorites[0].name == "집")
        #expect(favorites[0].roadName == "서울 강남구 테헤란로 123")
    }

    // --- 좌표 null 방어 (즐겨찾기) ---
    // 예전 주석의 「서버 방어가 하나도 없다」는 **이제 틀렸다**: FavoritePlace.from() 이 좌표 null 과
    // 서비스지역 밖을 400 INVALID_COORDINATES 로 막는다(실측 2026-11-01, 로컬 :8080 — 좌표 키 누락과
    // (10.0, 10.0) 둘 다 400). 그래도 아래 방어는 그대로 둔다: DB 의 latitude/longitude 가 여전히
    // NULL 허용이라 검증 도입 전 레거시 행이 남아 있을 수 있다.
    // 그런 행 하나로 파싱이 터지면 GET /users/me/favorite-places 응답 전체가 날아가 14 홈은
    // 즐겨찾기가 조용히 비고 15 목적지는 영구히 에러 문구를 띄운다.
    // 매퍼가 버린 그 행은 사용자 눈에만 안 보이고 서버 10칸 중 하나를 계속 차지하므로,
    // 목록에서 고를 수 없다 — DELETE .../favorite-places/all(전체 삭제)이 유일한 탈출구다.

    @Test("좌표가 없는 즐겨찾기 한 건이 있어도 나머지 목록이 열린다")
    func favoriteListWithoutCoordinates() throws {
        let body = """
            {"places":[
              {"placeId":1,"placeName":"집","roadName":"서울 강남구 테헤란로 123","latitude":37.5013,"longitude":127.0396,"placeSequence":1},
              {"placeId":2,"placeName":"좌표없는곳","roadName":"어딘가","latitude":null,"longitude":null,"placeSequence":2},
              {"placeId":3,"placeName":"회사","roadName":"경기 성남시 분당구 판교역로 166","latitude":37.3948,"longitude":127.1112,"placeSequence":3}
            ]}
            """

        let favorites = try decodeJSON(FavoritePlaceListResponse.self, body).toFavoritePlaces()

        // **한 건만 버린다** — 전에는 이 본문 하나로 목록 전체(세 건)가 사라졌다.
        #expect(favorites.map(\.name) == ["집", "회사"])
    }

    /// 경도만 빠진 경우도 같다 — 한쪽만 있는 좌표로는 지도를 찍을 수 없다.
    @Test("좌표가 한쪽만 있는 즐겨찾기는 버린다")
    func favoriteWithHalfCoordinates() {
        let item = FavoritePlaceListResponse.FavoritePlaceItem(
            placeId: 1,
            placeName: "반쪽좌표",
            latitude: 37.5013,
            longitude: nil,
            placeSequence: 1
        )

        #expect(item.toFavoritePlaceOrNull() == nil)
    }

    /// 좌표가 없는 항목을 (0, 0) 으로 떨구지 않는다는 것 — 그 칩을 누르면 기니만 앞바다를 목적지로
    /// 요청하게 되고 서버가 400 `OUT_OF_SERVICE_AREA` 로 막는다. 사용자는 이유를 알 길이 없다.
    @Test("좌표가 없는 즐겨찾기를 0 0 으로 지어내지 않는다")
    func favoriteWithoutCoordinatesIsNotZero() throws {
        let favorites = try decodeJSON(
            FavoritePlaceListResponse.self,
            #"{"places":[{"placeId":1,"placeName":"좌표없는곳","placeSequence":1}]}"#
        ).toFavoritePlaces()

        #expect(favorites.count == 0)
    }

    /// `placeSequence` 가 없으면 **맨 뒤**로 간다. 0 으로 접으면 그 행이 사용자가 정한 순서(「집」=1)
    /// 앞으로 끼어든다. 서버 `FavoritePlaceService.save()` 는 늘 `max + 1` 을 채우므로(그 계산이
    /// `mapToInt(getPlaceSequence)` 라 null 인 행이 있으면 서버의 등록 자체가 NPE 로 깨진다)
    /// null 은 「서버도 다룰 수 없는 행」이라는 뜻이다.
    @Test("순번이 없는 즐겨찾기는 목록 맨 뒤로 간다")
    func favoriteWithoutSequenceGoesLast() throws {
        let body = """
            {"places":[
              {"placeId":2,"placeName":"순번없음","latitude":37.1,"longitude":127.1},
              {"placeId":1,"placeName":"집","latitude":37.5013,"longitude":127.0396,"placeSequence":1}
            ]}
            """

        let favorites = try decodeJSON(FavoritePlaceListResponse.self, body).toFavoritePlaces()

        #expect(favorites.map(\.name) == ["집", "순번없음"])
    }

    /// 검색 응답의 `name` 이 null 인 항목이 섞여도 **목록 전체가 살아남는다.**
    ///
    /// 서버 `KakaoPlaceClient.toPlaceOrNull()` 은 좌표 파싱만 try 로 감싸므로, 좌표가 멀쩡하고
    /// `place_name` 만 null 인 카카오 문서는 걸러지지 않고 `"name": null` 로 실려 온다 —
    /// roadName 과 **같은 경로의 같은 함정**이다.
    @Test("검색 결과에 name 이 null 인 장소가 섞여도 목록 전체가 살아남는다")
    func searchListWithNullName() throws {
        let body = """
            {"list":[
              {"name":null,"roadName":"경기 성남시 분당구 판교역로 160","latitude":37.3947,"longitude":127.1112},
              {"name":"판교역","roadName":"경기 성남시 분당구 판교역로 160","latitude":37.3947,"longitude":127.1112}
            ]}
            """

        let places = try decodeJSON(PlaceSearchListResponse.self, body).list.map { $0.toPlace() }

        #expect(places.count == 2)
        // 이름만 비고 나머지는 보존된다 — 항목을 버리지는 않는다(좌표는 서버가 보증한다).
        #expect(places[0].name == "")
        #expect(places[0].roadName == "경기 성남시 분당구 판교역로 160")
        #expect(places[1].name == "판교역")
    }

    // 키 자체가 없는 경우는 원래 기본값으로 떨어졌다 — nullable 로 바꾼 뒤에도 같은 결과여야 한다.
    @Test("roadName 키가 아예 없어도 빈 도로명으로 매핑된다")
    func missingRoadNameKey() throws {
        let body = #"{"list":[{"name":"판교역","latitude":37.3947,"longitude":127.1112}]}"#

        let list = try decodeJSON(PlaceSearchListResponse.self, body).list
        #expect(list.count == 1)
        let place = list[0].toPlace()

        #expect(place.roadName == "")
    }

    // --- 역지오코딩 (GET /api/v1/places/reverse) ---
    // 아래 3개 응답 본문은 localhost:8080 실서버 curl 결과 그대로다.

    @Test("역지오코딩 정상 응답을 ReverseAddress 로 매핑한다")
    func mapsReverseAddress() throws {
        let body = """
            {"address":"부산광역시 금정구 부산대학로63번길 2 부산대학교","roadAddress":"부산광역시 금정구 부산대학로63번길 2 부산대학교","jibunAddress":"부산광역시 금정구 장전동 40"}
            """

        let address = try #require(
            try Response.success(decodeJSON(AddressResponseDto.self, body)).toReverseAddressOrNull()
        )

        #expect(address.address == "부산광역시 금정구 부산대학로63번길 2 부산대학교")
        #expect(address.roadAddress == "부산광역시 금정구 부산대학로63번길 2 부산대학교")
        #expect(address.jibunAddress == "부산광역시 금정구 장전동 40")
    }

    // 도로명이 없는 좌표(실측 35.0,128.0). roadAddress 만 null 이고 address 는 지번으로 채워져 온다.
    @Test("roadAddress 가 null 이어도 address 는 지번으로 유지된다")
    func reverseAddressWithoutRoadAddress() throws {
        let body = """
            {"address":"경상남도 사천시 서포면 자혜리 1230-17","roadAddress":null,"jibunAddress":"경상남도 사천시 서포면 자혜리 1230-17"}
            """

        let address = try #require(
            try Response.success(decodeJSON(AddressResponseDto.self, body)).toReverseAddressOrNull()
        )

        #expect(address.address == "경상남도 사천시 서포면 자혜리 1230-17")
        #expect(address.roadAddress == nil)
        #expect(address.jibunAddress == "경상남도 사천시 서포면 자혜리 1230-17")
    }

    // 바다에 핀을 찍는 건 정상 유저 행동이라 예외가 아니라 null 이어야 한다.
    @Test("주소 없는 좌표의 404 ADDRESS_NOT_FOUND 는 예외가 아니라 null 이다")
    func addressNotFoundIsNil() throws {
        let response = errorResponse(
            404,
            #"{"code":"ADDRESS_NOT_FOUND","message":"해당 좌표의 주소를 찾을 수 없습니다."}"#
        )

        #expect(try response.toReverseAddressOrNull() == nil)
    }

    @Test("한국 밖 좌표의 400 INVALID_COORDINATES 는 예외로 던진다")
    func invalidCoordinatesThrows() {
        let response = errorResponse(
            400,
            #"{"code":"INVALID_COORDINATES","message":"좌표가 올바르지 않습니다."}"#
        )

        let e = #expect(throws: HttpException.self) { try response.toReverseAddressOrNull() }
        #expect(e?.code() == 400)
    }

    // 경로 오타 등 서버가 의도하지 않은 404 까지 null 로 삼키면 연동 실패가 조용히 묻힌다.
    @Test("ADDRESS_NOT_FOUND 가 아닌 404 는 예외로 던진다")
    func otherNotFoundThrows() {
        let response = errorResponse(404, #"{"timestamp":"2026-09-01","status":404,"error":"Not Found"}"#)

        #expect(throws: HttpException.self) { try response.toReverseAddressOrNull() }
    }

    @Test("세 필드가 모두 비면 표시할 주소가 없으므로 null 이다")
    func emptyAddressIsNil() {
        #expect(AddressResponseDto().toReverseAddressOrNull() == nil)
    }

    // --- placeId 방어 (즐겨찾기 삭제의 대상 식별자) ---
    // 오래 「서버가 placeId 를 안 준다」고 적혀 있었지만 틀린 말이었다 — 앱 DTO 에 필드가 없어
    // 디코더가 조용히 버리고 있었을 뿐이다. 아래 세 테스트가 그 복구와,
    // **없는 값을 0 으로 지어내지 않는 것**을 못 박는다.

    /// 실측 응답 본문 그대로(2026-11-01, 로컬 `:8080`, `moyeota2` — 2건 등록 후 조회).
    @Test("즐겨찾기 응답의 placeId 를 도메인 id 로 가져온다")
    func mapsPlaceId() throws {
        let body = """
            {"places":[{"placeId":19,"placeName":"지움테스트A","roadName":"서울 강남구 테헤란로 152","latitude":37.4979,"longitude":127.0276,"placeSequence":1},{"placeId":20,"placeName":"지움테스트B","roadName":"경기 성남시 분당구 판교역로 166","latitude":37.3948,"longitude":127.1112,"placeSequence":2}]}
            """

        let favorites = try decodeJSON(FavoritePlaceListResponse.self, body).toFavoritePlaces()

        #expect(favorites.map(\.id) == [19, 20])
    }

    /// 좌표 null 과 같은 모양 — 한 행이 목록 전체를 죽이지 않는다.
    @Test("placeId 가 없는 즐겨찾기 한 건이 있어도 나머지 목록이 열린다")
    func favoriteListWithoutPlaceId() throws {
        let body = """
            {"places":[
              {"placeId":1,"placeName":"집","roadName":"서울 강남구 테헤란로 123","latitude":37.5013,"longitude":127.0396,"placeSequence":1},
              {"placeId":null,"placeName":"식별자없는곳","roadName":"어딘가","latitude":37.5,"longitude":127.0,"placeSequence":2},
              {"placeId":3,"placeName":"회사","roadName":"경기 성남시 분당구 판교역로 166","latitude":37.3948,"longitude":127.1112,"placeSequence":3}
            ]}
            """

        let favorites = try decodeJSON(FavoritePlaceListResponse.self, body).toFavoritePlaces()

        #expect(favorites.map(\.name) == ["집", "회사"])
    }

    /// **0 으로 접지 않는다는 것**이 핵심이다. 0 이 섞이면 `POST .../favorite-places/batch-delete` 가
    /// 404 `FAVORITE_PLACE_NOT_FOUND` 로 떨어지고 **선택 전체가 안 지워진다**(전부-아니면-전무.
    /// 실측 2026-11-01: `[19, 999999]` → 404 이고 19 도 그대로 남았다. id 0·음수도 404).
    /// 즉 지어낸 한 건이 멀쩡한 선택까지 전부 실패시킨다.
    @Test("placeId 가 없는 즐겨찾기를 0 으로 지어내지 않는다")
    func favoriteWithoutPlaceIdIsNotZero() throws {
        let favorites = try decodeJSON(
            FavoritePlaceListResponse.self,
            #"{"places":[{"placeName":"식별자없는곳","latitude":37.5,"longitude":127.0,"placeSequence":1}]}"#
        ).toFavoritePlaces()

        #expect(favorites.count == 0)
    }

    /// 다건 삭제 본문의 키는 `placeIds` 다. 이름이 틀리면 서버가 모르는 키를 **무시**해 400
    /// `INVALID_PLACE_IDS` 로 조용히 실패하고(실측: `{"ids":[2]}` → 400), 컴파일도 실행도 통과하므로
    /// 문자열 비교로만 막을 수 있다.
    @Test("다건 삭제 요청 본문의 키는 placeIds 다")
    func deleteRequestKey() throws {
        let dto = ([1, 2] as [Int64]).toFavoriteDeleteRequestDto()

        #expect(try encodeJSON(dto) == #"{"placeIds":[1,2]}"#)
    }

    private func errorResponse(_ code: Int, _ body: String) -> Response<AddressResponseDto> {
        Response.error(code, body)
    }
}
