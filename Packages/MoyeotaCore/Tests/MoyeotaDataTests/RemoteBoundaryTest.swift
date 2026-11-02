import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 원본에 대응 테스트가 없는 iOS 쪽 경계를 본다. kotlinx·Retrofit 이 해 주던 동작을 직접 구현한 자리들이다.
@Suite struct RemoteBoundaryTest {

    // MARK: - JSON 설정 (kotlinx 기본값과 같은가)

    /// 원본은 `coerceInputValues` 를 켜지 않았다 — non-null 필드의 명시적 null 은 파싱 실패다.
    /// 기본값으로 접으면 파티 status(→ "") 의 null 까지 조용히 삼킨다(`PlaceSearchItem.roadName` 주석).
    @Test("기본값이 있는 non-null 필드의 명시적 null 은 파싱 실패다")
    func explicitNullOnDefaultedFieldThrows() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(PartyListResponse.self, #"{"list":null}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(PartyDetailResponse.self, #"{"id":7,"status":null}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(PartyListResponse.self, #"{"list":[{"partyId":7,"capacity":null}]}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(RideRecordPageResponse.self, #"{"rides":[],"hasNext":null}"#)
        }
    }

    @Test("기본값이 있는 non-null 필드의 키가 없으면 기본값이다")
    func missingKeyOnDefaultedFieldUsesDefault() throws {
        let detail = try decodeJSON(PartyDetailResponse.self, #"{"id":7}"#)

        #expect(detail.status == "")
        #expect(detail.capacity == 0)
        #expect(detail.members == [])
        #expect(detail.currentMembers == nil)

        let joined = try decodeJSON(MemberJoinedPayload.self, "{}")
        #expect(joined.member == PartyDetailResponse.MemberInfo())
    }

    @Test("기본값이 없는 필드의 키가 없으면 파싱 실패다")
    func missingRequiredKeyThrows() {
        #expect(throws: DecodingError.self) { try decodeJSON(PartyDetailResponse.self, "{}") }
        #expect(throws: DecodingError.self) { try decodeJSON(OpenPartyResponse.self, "{}") }
        #expect(throws: DecodingError.self) { try decodeJSON(ReportResponse.self, "{}") }
        #expect(throws: DecodingError.self) { try decodeJSON(PartyListResponse.self, #"{"list":[{}]}"#) }
    }

    /// kotlinx 는 슬래시를 이스케이프하지 않는다. 합성 `Encodable` 의 null 도 빠진다(`encodeDefaults = false`).
    @Test("요청 본문은 슬래시와 한글을 이스케이프하지 않고 null 을 싣지 않는다")
    func encoderMatchesKotlinxOutput() throws {
        let body = try encodeJSON(FavoritePlaceRequestDto(placeName: "집", roadName: "A/B", latitude: 37.5, longitude: 127))

        #expect(body == #"{"latitude":37.5,"longitude":127,"placeName":"집","roadName":"A/B"}"#)
        #expect(try encodeJSON(ReportRequestDto()) == "{}")
    }

    @Test("실시간 추천 요청의 좌표 키는 destLat destLng 다")
    func realtimeRequestKeys() throws {
        let body = try encodeJSON(
            RealTimeMatchingRequestDto(departureLat: 37.1, departureLng: 127.1, destLat: 37.2, destLng: 127.2)
        )

        #expect(Set(try parseJSONObject(body).keys) == ["departureLat", "departureLng", "destLat", "destLng"])
    }

    // MARK: - 즐겨찾기 정렬

    @Test("즐겨찾기 순번이 같으면 받은 순서를 유지한다")
    func favoriteSortIsStable() {
        let items = (1...20).map { id in
            FavoritePlaceListResponse.FavoritePlaceItem(
                placeId: Int64(id), placeName: "p\(id)", latitude: 37, longitude: 127, placeSequence: 1
            )
        }

        let favorites = FavoritePlaceListResponse(places: items).toFavoritePlaces()

        #expect(favorites.map(\.id) == (1...20).map { Int64($0) })
    }

    // MARK: - 역지오코딩 폴백

    @Test("address 가 공백뿐이면 도로명 지번 순으로 떨어진다")
    func reverseAddressFallback() {
        #expect(
            AddressResponseDto(address: "  ", roadAddress: "도로", jibunAddress: "지번").toReverseAddressOrNull()
                == ReverseAddress(address: "도로", roadAddress: "도로", jibunAddress: "지번")
        )
        #expect(
            AddressResponseDto(address: nil, roadAddress: " ", jibunAddress: "지번").toReverseAddressOrNull()
                == ReverseAddress(address: "지번", roadAddress: nil, jibunAddress: "지번")
        )
    }

    // MARK: - SSE 프레임 변환

    @Test("connected 프레임은 상세 매퍼로 바뀌고 순번을 함께 싣는다")
    func snapshotEvent() {
        let detail = PartyDetailResponse(
            id: 7,
            status: "ACTIVE",
            members: [PartyDetailResponse.MemberInfo(publicId: "me", nickname: "성윤")],
            version: 3
        )

        let event = PartySseEvent.snapshot(detail: detail).toPartyEvent(currentUuid: "me")

        #expect(event == .snapshot(ride: detail.toRide(currentUuid: "me"), version: 3))
    }

    @Test("member-joined 프레임은 상세와 같은 매퍼로 멤버를 옮긴다")
    func memberJoinedEvent() {
        let payload = MemberJoinedPayload(
            member: PartyDetailResponse.MemberInfo(publicId: "me", nickname: "성윤", rideCount: 2),
            status: "COMPLETED",
            version: 4
        )

        let event = PartySseEvent.memberJoined(payload: payload).toPartyEvent(currentUuid: "me")

        // host 를 말하지 않았으므로 상세와 같이 「나」는 방장으로 떨어진다.
        let expected = User(
            id: "me", nickname: "성윤", verifiedLabel: "", rating: 0.0, rideCount: 2, isMe: true, isHost: true
        )
        #expect(event == .memberJoined(member: expected, status: .matched, version: 4))
    }

    @Test("member-left 프레임의 빈 publicId 와 hostPublicId 는 null 로 접힌다")
    func memberLeftEventFoldsBlank() {
        let event = PartySseEvent.memberLeft(
            payload: MemberLeftPayload(publicId: "  ", status: "ACTIVE", hostPublicId: "", version: 5)
        ).toPartyEvent()

        #expect(event == .memberLeft(publicId: nil, status: .recruiting, hostPublicId: nil, version: 5))

        let kept = PartySseEvent.memberLeft(
            payload: MemberLeftPayload(publicId: "a", status: "ACTIVE", hostPublicId: "b")
        ).toPartyEvent()

        #expect(kept == .memberLeft(publicId: "a", status: .recruiting, hostPublicId: "b", version: nil))
    }

    @Test("closed 와 disconnected 는 값 없이 옮겨진다")
    func terminalEvents() {
        #expect(PartySseEvent.closed.toPartyEvent() == .closed)
        #expect(PartySseEvent.disconnected.toPartyEvent() == .disconnected)
    }

    // MARK: - 에러 본문

    @Test("에러 본문은 HTTP 실패의 JSON 일 때만 읽힌다")
    func readApiErrorShapes() {
        let readable = httpException(409, #"{"code":"PARTY_FULL","message":"가득 찼습니다."}"#)
        #expect(readable.readApiError() == ApiErrorDto(code: "PARTY_FULL", message: "가득 찼습니다."))

        // 게이트웨이가 가로챈 HTML·빈 본문·본문 없음은 사유를 추측하지 않는다.
        #expect(httpException(502, "<html>Bad Gateway</html>").readApiError() == nil)
        #expect(httpException(502, "   ").readApiError() == nil)
        #expect(HttpException(Response<Void>.error(502, nil)).readApiError() == nil)

        // Spring 기본 본문은 파싱은 되지만 code 가 없다.
        #expect(
            httpException(405, #"{"timestamp":"t","status":405,"error":"x","path":"/p"}"#).readApiError()
                == ApiErrorDto()
        )

        #expect(URLError(.timedOut).readApiError() == nil)
    }

    // MARK: - 합류 실패 경계

    @Test("합류 HTTP 실패는 코드 상태 joinedStatus 를 싣는다")
    func joinHttpFailure() {
        let status = PartyStatus(status: .recruiting, currentMembers: 2)
        let failure = httpException(409, "{}")

        let e = partyJoinException(
            failure: failure,
            error: ApiErrorDto(code: "ALREADY_JOINED_OTHER_PARTY", message: "이미 참여 중입니다."),
            joinedStatus: status
        )

        #expect(e.code == "ALREADY_JOINED_OTHER_PARTY")
        #expect(e.serverMessage == "이미 참여 중입니다.")
        #expect(e.httpStatus == 409)
        #expect(e.joinedStatus == status)
        #expect(!e.isNetwork)
        #expect(e.cause is HttpException)
    }

    @Test("합류 전송 실패는 네트워크로 분류하고 취소는 네트워크가 아니다")
    func joinTransportFailure() {
        #expect(partyJoinException(failure: URLError(.timedOut), error: nil).isNetwork)
        #expect(partyJoinException(failure: IOException("끊김"), error: nil).isNetwork)
        #expect(!partyJoinException(failure: URLError(.cancelled), error: nil).isNetwork)
        #expect(!partyJoinException(failure: CancellationError(), error: nil).isNetwork)
        #expect(!partyJoinException(failure: IllegalStateException("x"), error: nil).isNetwork)
    }

    @Test("이미 좁혀진 합류 완료 추천 예외는 그대로 돌려준다")
    func alreadyNarrowedExceptionsPassThrough() {
        let join = PartyJoinException(code: "A", serverMessage: "원문")
        #expect(partyJoinException(failure: join, error: ApiErrorDto(code: "B")).code == "A")

        let finish = PartyFinishException(code: "A", serverMessage: "원문")
        #expect(partyFinishException(failure: finish, error: ApiErrorDto(code: "B")).code == "A")

        let realtime = RealtimeMatchException(code: "A", serverMessage: "원문")
        #expect(realtimeMatchException(failure: realtime, error: ApiErrorDto(code: "B")).code == "A")
    }

    @Test("완료 실패는 코드로만 갈리고 전송 실패에는 코드가 없다")
    func finishFailure() {
        let http = partyFinishException(
            failure: httpException(403, "{}"),
            error: ApiErrorDto(code: PartyFinishException.NOT_PARTY_HOST, message: "m")
        )
        #expect(http.isNotHost)
        #expect(http.httpStatus == 403)
        #expect(http.serverMessage == "m")

        let transport = partyFinishException(failure: URLError(.timedOut), error: nil)
        #expect(transport.code == nil)
        #expect(transport.httpStatus == nil)
    }

    @Test("추천 실패는 HTTP 상태를 싣고 전송 실패에는 상태가 없다")
    func realtimeFailure() {
        let http = realtimeMatchException(failure: httpException(502, ""), error: nil)
        #expect(http.isRouteUnavailable)
        #expect(http.code == nil)

        let transport = realtimeMatchException(failure: URLError(.timedOut), error: nil)
        #expect(transport.httpStatus == nil)
        #expect(!transport.isRouteUnavailable)
    }

    // MARK: - 즐겨찾기 실패 경계

    @Test("즐겨찾기 404 는 본문의 코드와 함께 isNotFound 가 된다")
    func favoriteNotFound() {
        let e = httpException(404, #"{"code":"FAVORITE_PLACE_NOT_FOUND","message":"없습니다."}"#)
            .toFavoritePlaceException()

        #expect(e.isNotFound)
        #expect(e.code == "FAVORITE_PLACE_NOT_FOUND")
        #expect(e.serverMessage == "없습니다.")
        #expect(e.httpStatus == 404)
        #expect(!e.isNetwork)
    }

    /// 실측: `POST .../favorite-places/all` 은 405 에 Spring 기본 본문을 싣는다.
    @Test("즐겨찾기 Spring 기본 본문은 코드 없이 상태만 남는다")
    func favoriteSpringBody() {
        let e = httpException(405, #"{"timestamp":"t","status":405,"error":"x","path":"/p"}"#)
            .toFavoritePlaceException()

        #expect(e.code == nil)
        #expect(e.httpStatus == 405)
        #expect(!e.isNotFound)
    }

    @Test("즐겨찾기 호출은 전송 실패를 네트워크로 좁힌다")
    func favoriteCallNetwork() async {
        let error = await #expect(throws: FavoritePlaceException.self) {
            try await favoritePlaceCall { () async throws -> Int in throw URLError(.notConnectedToInternet) }
        }

        #expect(error?.isNetwork == true)
    }

    @Test("즐겨찾기 호출은 이미 좁혀진 예외를 그대로 돌려준다")
    func favoriteCallPassThrough() async {
        let error = await #expect(throws: FavoritePlaceException.self) {
            try await favoritePlaceCall { () async throws -> Int in
                throw FavoritePlaceException(code: "A", serverMessage: "원문")
            }
        }

        #expect(error?.code == "A")
    }

    /// 취소를 에러로 바꾸면 화면 이탈이 에러 문구로 보인다.
    @Test("즐겨찾기 호출은 취소를 그대로 통과시킨다")
    func favoriteCallCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await favoritePlaceCall { () async throws -> Int in throw CancellationError() }
        }
        await #expect(throws: URLError.self) {
            try await favoritePlaceCall { () async throws -> Int in throw URLError(.cancelled) }
        }
    }

    @Test("즐겨찾기 호출은 성공 값을 그대로 돌려준다")
    func favoriteCallSuccess() async throws {
        #expect(try await favoritePlaceCall { 7 } == 7)
    }

    // MARK: - 인증·채팅 DTO

    /// `decodeOrDefault` 주석이 이름을 든 두 자리다 — 빈 Bearer 로 401 루프를 도는 쪽이 파싱 실패보다 늦게 발견된다.
    @Test("토큰과 채팅방 id 의 명시적 null 은 파싱 실패다")
    func explicitNullOnTokenAndRoomIdThrows() {
        #expect(throws: DecodingError.self) { try decodeJSON(TokenResponse.self, #"{"accessToken":null}"#) }
        #expect(throws: DecodingError.self) { try decodeJSON(ChatRoomUserResponse.self, #"{"chatRoomId":null}"#) }
    }

    @Test("채팅 응답의 필수 id 가 빠지면 파싱 실패다")
    func missingChatIdsThrow() {
        #expect(throws: DecodingError.self) { try decodeJSON(ChatRoomResponse.self, "{}") }
        #expect(throws: DecodingError.self) { try decodeJSON(ChatRoomUserResponse.self, "{}") }
        #expect(throws: DecodingError.self) { try decodeJSON(ChatMessageResponse.self, "{}") }
        #expect(throws: DecodingError.self) { try decodeJSON(ChatLastMessageResponse.self, "{}") }
    }

    @Test("활성 참여자의 기본값은 active 다")
    func memberActiveDefault() throws {
        #expect(try decodeJSON(ChatMemberResponse.self, #"{"publicId":"p"}"#).active)
    }

    /// 서버가 「넘어온 것만 갱신」하는 계약이다. 둘 다 null 이면 빈 객체가 나간다.
    @Test("프로필 수정 요청은 null 필드를 싣지 않는다")
    func updateProfileOmitsNil() throws {
        #expect(try encodeJSON(UpdateProfileRequest()) == "{}")
        #expect(
            try encodeJSON(UpdateProfileRequest(imageKey: "profile/presets/03.png"))
                == #"{"imageKey":"profile/presets/03.png"}"#
        )
    }

    @Test("가입 요청의 닉네임은 앞뒤 공백을 떼고 보낸다")
    func registerTrimsNickname() {
        let user = NewUser(
            loginId: "a",
            password: "p",
            nickname: "  모여타 ",
            name: "n",
            birthDate: LocalDate(year: 2000, month: 1, dayOfMonth: 1)!,
            phoneNumber: "010",
            gender: .female,
            email: "e",
            verificationToken: "t"
        )

        #expect(user.toDto().nickname == "모여타")
    }

    // MARK: - 인증·채팅 실패 경계

    @Test("인증과 채팅은 URLError 를 네트워크로 좁히되 취소는 네트워크가 아니다")
    func authAndChatTransportFailure() {
        #expect(URLError(.timedOut).toAuthException().error == .network)
        #expect(URLError(.cancelled).toAuthException().error == .unknown)
        #expect(IllegalStateException("x").toAuthException().error == .unknown)

        #expect(URLError(.timedOut).toChatException().isNetwork)
        #expect(IOException("끊김").toChatException().isNetwork)
        #expect(!URLError(.cancelled).toChatException().isNetwork)
        #expect(!IllegalStateException("x").toChatException().isNetwork)
    }

    @Test("채팅 HTTP 실패는 코드 원문 상태를 싣고 깨진 본문은 상태만 남긴다")
    func chatHttpFailure() {
        let e = httpException(403, #"{"code":"CHAT_NOT_PARTICIPANT","message":"참여자가 아닙니다."}"#).toChatException()

        #expect(e.code == "CHAT_NOT_PARTICIPANT")
        #expect(e.serverMessage == "참여자가 아닙니다.")
        #expect(e.httpStatus == 403)
        #expect(e.isNotParticipant)
        #expect(!e.isNetwork)
        #expect(e.cause is HttpException)

        let broken = httpException(404, "<html>oops</html>").toChatException()
        #expect(broken.code == nil)
        #expect(broken.isRoomNotFound)
    }

    @Test("이미 좁혀진 인증 채팅 예외는 그대로 돌려준다")
    func authAndChatPassThrough() {
        #expect(AuthException(error: .loginFailed, serverMessage: "원문").toAuthException().serverMessage == "원문")
        #expect(ChatException(code: "A", serverMessage: "원문").toChatException().code == "A")
    }

    /// 취소를 에러로 바꾸면 화면 이탈이 에러 토스트로 보인다.
    @Test("인증과 채팅 호출은 취소를 그대로 통과시킨다")
    func authAndChatCallCancellation() async {
        await #expect(throws: CancellationError.self) {
            try await authCall { () async throws -> Int in throw CancellationError() }
        }
        await #expect(throws: URLError.self) {
            try await authCall { () async throws -> Int in throw URLError(.cancelled) }
        }
        await #expect(throws: CancellationError.self) {
            try await chatCall { () async throws -> Int in throw CancellationError() }
        }
        await #expect(throws: URLError.self) {
            try await chatCall { () async throws -> Int in throw URLError(.cancelled) }
        }
    }

    @Test("인증과 채팅 호출은 실패를 도메인 예외로 좁히고 성공 값은 그대로 돌려준다")
    func authAndChatCallNarrowing() async throws {
        let auth = await #expect(throws: AuthException.self) {
            try await authCall { () async throws -> Int in throw URLError(.notConnectedToInternet) }
        }
        #expect(auth?.error == .network)

        let chat = await #expect(throws: ChatException.self) {
            try await chatCall { () async throws -> Int in throw URLError(.notConnectedToInternet) }
        }
        #expect(chat?.isNetwork == true)

        #expect(try await authCall { 7 } == 7)
        #expect(try await chatCall { 7 } == 7)
    }

    private func httpException(_ code: Int, _ body: String) -> HttpException {
        HttpException(Response<Void>.error(code, body))
    }
}
