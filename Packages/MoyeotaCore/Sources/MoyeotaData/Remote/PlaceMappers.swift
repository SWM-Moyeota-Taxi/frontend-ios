import MoyeotaDomain

private let ADDRESS_NOT_FOUND = "ADDRESS_NOT_FOUND"

// name·roadName 은 서버가 null 을 줄 수 있다(DTO 주석 참고). 도메인은 non-null 을 유지하고 여기서 "" 로
// 떨군다 — 화면은 두 값을 Text 에 그대로 넣으므로 빈 문자열이면 그 줄 한 칸이 비는 것으로 끝난다.
// **항목을 버리지는 않는다**: 좌표는 서버가 보증하므로(DTO 주석) 이름이 비어도 지도로 갈 수는 있다.
extension PlaceSearchListResponse.PlaceSearchItem {
    public func toPlace() -> Place {
        Place(
            name: name ?? "",
            roadName: roadName ?? "",
            latitude: latitude,
            longitude: longitude
        )
    }
}

extension FavoritePlaceListResponse {
    /// 즐겨찾기 목록 응답 → 도메인. **식별자나 좌표가 없는 항목은 그 한 건만 버린다.**
    ///
    /// 한 행 때문에 목록 전체가 사라지지 않게 하는 것이 이 함수의 존재 이유다
    /// (`FavoritePlaceListResponse.FavoritePlaceItem.latitude` 에 DB 가 아직 좌표 NULL 을 허용하는
    /// 사정을 적어 두었다).
    /// 정렬은 `FavoritePlace.sequence` 오름차순 — 순번을 모르는 항목은 맨 뒤로 간다(DTO 주석 참고).
    /// `RemotePlaceRepository` 가 이미 `sequence` 로 같은 순서를 만들고 있어, 어느 쪽을
    /// 거쳐도 보이는 순서는 같다(같은 키로 두 번 정렬해도 결과가 바뀌지 않는다).
    ///
    /// 같은 순번끼리는 받은 순서를 유지한다(원본 `sortedBy` 가 안정 정렬이다. Swift `sorted` 는
    /// 안정성을 문서로 보장하지 않아 위치를 함께 비교한다).
    public func toFavoritePlaces() -> [FavoritePlace] {
        places.compactMap { $0.toFavoritePlaceOrNull() }
            .enumerated()
            .sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }
            .map(\.element)
    }
}

extension FavoritePlaceListResponse.FavoritePlaceItem {
    /// 즐겨찾기 한 건 → 도메인. **식별자나 좌표가 없으면 null 이다.**
    ///
    /// 즐겨찾기는 name 이 아니라 placeName 으로 필드명이 다르다 — 그 차이는 여기서만 흡수한다.
    ///
    /// `placeId` 가 없으면 버리는 이유: 삭제도 못 하고 지도로도 못 가는 행이다. **0 으로 접으면 안 된다** —
    /// 그 0 이 `POST .../favorite-places/batch-delete` 의 placeIds 에 섞이면 서버가 404
    /// `FAVORITE_PLACE_NOT_FOUND` 로 **아무것도 지우지 않는다**(전부-아니면-전무. 실측(2026-11-01,
    /// 로컬 `:8080`): `{"placeIds":[19,999999]}` → 404 이고 19 도 그대로 남아 있었다. id 0·음수도 404).
    /// 즉 지어낸 한 건이 멀쩡한 선택 **전체**를 실패시킨다.
    ///
    /// 좌표가 없는 항목을 (0.0, 0.0) 으로 떨구지 않는 이유: 그 칩을 누르면 기니만 앞바다를 목적지로
    /// 요청하게 되고, 서버는 400 `OUT_OF_SERVICE_AREA` 로 막는다 — 사용자는 자기 즐겨찾기가 왜 안 되는지
    /// 알 길이 없다. **없는 값을 지어내지 않고 그 줄만 지운다**(나머지 즐겨찾기는 그대로 열린다).
    ///
    /// ★ 버린 행은 **서버에서 10칸 중 하나를 계속 차지한다.** 목록에 없으니 고를 수 없고, 전체 삭제
    /// (`DELETE .../favorite-places/all`)만이 그 행을 치운다 — 14 홈의 「전체 삭제」가 필수인 이유다.
    public func toFavoritePlaceOrNull() -> FavoritePlace? {
        guard let id = placeId, let lat = latitude, let lng = longitude else { return nil }
        return FavoritePlace(
            id: id,
            name: placeName,
            roadName: roadName ?? "",
            latitude: lat,
            longitude: lng,
            // 순번을 모르면 맨 뒤 — 0 으로 접으면 사용자가 정한 순서 앞으로 끼어든다(DTO 주석 참고).
            sequence: placeSequence ?? Int.max
        )
    }
}

extension Response where T == AddressResponseDto {
    /// 역지오코딩 응답을 도메인으로 옮긴다. "주소 없음"은 실패가 아니라 null 이다.
    ///
    /// 성공(2xx)이어도 세 필드가 전부 비어 오면(네이버가 roadaddr/addr 어느 쪽도 못 채운 경우)
    /// 표시할 게 없으므로 404 와 같은 취급으로 null 을 준다 — 호출측 분기를 한 갈래로 유지한다.
    /// 404 는 서버가 의도한 ADDRESS_NOT_FOUND 일 때만 null 이고, 경로 오타 같은 404 는 그대로 던져 드러낸다.
    public func toReverseAddressOrNull() throws -> ReverseAddress? {
        if isSuccessful { return body()?.toReverseAddressOrNull() }
        if code() == 404 && errorCode() == ADDRESS_NOT_FOUND { return nil }
        throw HttpException(self)
    }
}

extension AddressResponseDto {
    public func toReverseAddressOrNull() -> ReverseAddress? {
        let road = roadAddress?.takeIfNotBlank()
        let jibun = jibunAddress?.takeIfNotBlank()
        // 서버 Address.display() 와 같은 폴백 순서. address 가 이미 조합돼 오므로 그것이 1순위다.
        guard let display = address?.takeIfNotBlank() ?? road ?? jibun else { return nil }
        return ReverseAddress(address: display, roadAddress: road, jibunAddress: jibun)
    }
}

extension Response {
    /// 에러 본문의 code. 본문이 없거나 ErrorResponse shape 이 아니면 null.
    fileprivate func errorCode() -> String? {
        decodeApiError(errorBody: errorBody())?.code
    }
}

extension Place {
    public func toFavoriteRequestDto() -> FavoritePlaceRequestDto {
        FavoritePlaceRequestDto(
            placeName: name,
            roadName: roadName,
            latitude: latitude,
            longitude: longitude
        )
    }
}

extension Array where Element == Int64 {
    /// 삭제할 id 목록 → 다건 삭제 요청 본문.
    ///
    /// 하는 일은 **키 이름을 `placeIds` 로 고정하는 것**뿐이다. 서버는 모르는 키를 무시하므로 이름이
    /// 틀리면 조용히 400 `INVALID_PLACE_IDS` 가 되고, 그 실패는 「서버가 거부했다」처럼 보여 원인이
    /// 앱 쪽 오타임을 가린다(실측(2026-11-01, 로컬 `:8080`): `{"ids":[2]}` → 400 `INVALID_PLACE_IDS`).
    /// 중복 id 는 서버가 한 번만 센다(실측: `[5,6,5]` → 204, 5·6 둘 다 삭제).
    public func toFavoriteDeleteRequestDto() -> FavoritePlaceDeleteRequestDto {
        FavoritePlaceDeleteRequestDto(placeIds: self)
    }
}

extension Error {
    /// 즐겨찾기 삭제 실패를 `FavoritePlaceException` 으로 좁힌다 — presentation 이 HTTP 를 모르게 하는
    /// 경계다(`toChatException` 과 같은 방식).
    ///
    /// 상태 코드만으로 갈리지 않는다: **404 하나에 「이미 지워졌다」·「없는 id」·「남의 id」가 전부
    /// 들어 있다**(실측(2026-11-01, 로컬 `:8080`) — 403 이 아니다). 그래서 코드까지 읽어 두고,
    /// 화면은 `FavoritePlaceException.isNotFound` 로만 분기한다.
    ///
    /// 본문 파싱 실패를 null 로 접는 이유: `{code,message}` 가 아닌 응답이 실제로 온다 —
    /// `POST .../favorite-places/all` 은 405 에 Spring 기본 `{timestamp,status,error,path}` 를 싣는다(실측).
    func toFavoritePlaceException() -> FavoritePlaceException {
        if let failure = self as? FavoritePlaceException { return failure }

        if let http = self as? HttpException {
            let body = http.readApiError()
            return FavoritePlaceException(
                code: body?.code,
                serverMessage: body?.message,
                httpStatus: http.code(),
                cause: http
            )
        }

        // 응답 자체를 못 받은 경우(연결 거부·타임아웃·DNS). 사용자에게는 재시도를 안내한다.
        // URLError(.cancelled) 는 취소이지 전송 실패가 아니다 — 그 도메인이 같아 먼저 거른다.
        if !isCancellation(throwable: self), isIOFailure(throwable: self) {
            return FavoritePlaceException(code: nil, serverMessage: nil, isNetwork: true, cause: self)
        }

        return FavoritePlaceException(code: nil, serverMessage: nil, cause: self)
    }
}

/// 즐겨찾기 삭제 호출을 감싸 실패를 `FavoritePlaceException` 으로 통일한다.
/// 취소는 그대로 통과시킨다 — 취소를 에러로 바꾸면 화면 이탈이 에러 문구로 보인다.
func favoritePlaceCall<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ block: () async throws -> T
) async throws -> T {
    do {
        return try await block()
    } catch let error where isCancellation(throwable: error) {
        throw error
    } catch {
        throw error.toFavoritePlaceException()
    }
}
