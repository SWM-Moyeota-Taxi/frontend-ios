import Foundation
import Testing
@testable import MoyeotaData

/// 백엔드가 `@CurrentUser` 로 넘어가면서 경로에서 memberId/userId 가 빠졌다.
/// 이 계층은 문자열이라 **컴파일러도 단위 테스트도 그냥은 못 잡는다** —
/// 틀리면 실행 시점에 404(또는 401)로만 드러난다. 그래서 선언(`ApiRoute`) 값 자체를 못 박는다.
/// 구현이 이 선언으로만 요청을 만들므로 실제로 나가는 값과 어긋나지 않는다.
///
/// 경로는 전부 실서버(localhost:8080) curl 실측으로 확인한 값이다.
/// 백엔드가 다시 바꾸면 이 테스트부터 깨지는 게 정상이다 — 값을 고치고 리포트를 갱신할 것.
@Suite struct AuthenticatedPathContractTest {

    /// 인증 개편으로 가입·로그인이 `/api/v1/users` 계열에서 `/api/v1/auth/` 하위로 옮겨졌다.
    /// 옛 경로는 지금 Security 가 보호 경로로 잡아 **401 을 낸다** — 404 가 아니라서
    /// "아이디/비밀번호가 틀렸나?"로 오해하기 딱 좋다. 그래서 네 경로를 모두 못 박는다.
    @Test("인증 엔드포인트는 전부 auth 프리픽스를 쓴다")
    func authPrefix() {
        #expect(AuthApiRoute.register.route.path == "api/v1/auth/register")
        #expect(AuthApiRoute.login.route.path == "api/v1/auth/login")
        #expect(AuthApiRoute.reissue.route.path == "api/v1/auth/reissue")
        #expect(AuthApiRoute.logout.route.path == "api/v1/auth/logout")
        #expect(AuthApiRoute.checkNickname.route.path == "api/v1/auth/nickname/check")
        #expect(AuthApiRoute.checkPhone.route.path == "api/v1/auth/phone/check")
    }

    /// 전화번호 가입 여부 선확인. 닉네임 확인과 **생김새가 닮아 경로를 섞어 쓰기 쉽다**
    /// (`/nickname/check` ↔ `/phone/check`) — `/api/v1/phone/check` 처럼 auth 프리픽스를 빠뜨리면
    /// 404 가 아니라 **401** 로 떨어져(Security 가 미매핑 경로도 보호한다) 세션 만료로 오인한다.
    ///
    /// 동사도 함께 못 박는다: 서버가 `@PostMapping` 만 매핑하므로 `GET` 으로 적으면 **405** 인데
    /// (실측 2026-11-01, 로컬 :8080), 405 는 앱 로그에서 네트워크 오류와 구분이 안 된다.
    /// 그리고 선확인은 결과를 조용히 버리는 호출이라, 틀려도 **화면에 아무 증상이 없다.**
    @Test("전화번호 가입 여부 확인은 auth phone check 경로의 POST 다")
    func phoneCheck() {
        #expect(AuthApiRoute.checkPhone.route.path == "api/v1/auth/phone/check")
        #expect(AuthApiRoute.checkPhone.route.method == .POST, "가입 여부 확인이 POST 가 아니다 — GET 이면 405 다")
        #expect(
            AuthApiRoute.checkNickname.route.path != AuthApiRoute.checkPhone.route.path,
            "닉네임 확인과 같은 경로를 탄다 — 번호를 닉네임으로 묻는 셈이다"
        )
    }

    /// 문자 인증 컨트롤러는 별 파일(`user/verification/presentation/SmsVerificationController.java`)이지만
    /// 프리픽스가 `/api/v1/auth/sms` 다 — **그래야 permitAll 구간에 들어와 가입 전(무토큰)에 부를 수 있다.**
    /// `/api/v1/sms/...` 처럼 적으면 404 가 아니라 **401** 이 나서(Security 가 미매핑 경로도 보호한다)
    /// "세션이 만료됐나"로 오해하게 된다. 두 경로는 `POST` 이고, 발송만 204 다.
    @Test("문자 인증 두 경로는 auth sms 프리픽스를 쓴다")
    func smsPrefix() {
        #expect(AuthApiRoute.sendSmsCode.route.path == "api/v1/auth/sms/send")
        #expect(AuthApiRoute.verifySmsCode.route.path == "api/v1/auth/sms/verify")

        for route in [AuthApiRoute.sendSmsCode, .verifySmsCode] {
            #expect(route.route.method == .POST, "\(route.rawValue) 이 POST 가 아니다")
        }
    }

    /// 닉네임 중복 확인은 **가입 도중, 즉 토큰이 없는 상태에서** 불린다. permitAll 구간이 `/api/v1/auth/`
    /// 하위뿐이라 경로도 그쪽이어야 하고, **`AuthApi` 에 있어야 한다** — `UserApi` 는 Bearer 부착
    /// 인터셉터와 401 재발급이 붙은 클라이언트로 만들어지므로, 만료된 토큰이 세션에
    /// 남아 있으면 permitAll 경로인데도 JWT 필터에 걸려 401 이 날 수 있다.
    /// 그래서 "auth 프리픽스인데 UserApi 에 있는" 조합을 아예 막는다.
    @Test("비보호 호출은 Bearer 가 붙지 않는 AuthApi 에만 있다")
    func unprotectedOnlyOnAuthApi() {
        let misplaced = UserApiRoute.allCases
            .filter { $0.route.path.hasPrefix("api/v1/auth/") }
            .map(\.rawValue)

        #expect(misplaced.isEmpty, "토큰 없이 부르는 경로가 인증 클라이언트 쪽에 있다: \(misplaced)")
    }

    /// 프로필 수정은 반대다 — 토큰 필수라 `UserApi` 여야 하고, 서버가 `@PatchMapping` 만 매핑하므로
    /// PUT/POST 로 보내면 405 다(같은 `/users/me` 경로에 fcm-token 쪽 PUT 이 있어 헷갈리기 쉽다).
    @Test("프로필 수정은 users me 경로의 PATCH 다")
    func updateProfile() {
        #expect(UserApiRoute.updateProfile.route.path == "api/v1/users/me")
        #expect(UserApiRoute.updateProfile.route.method == .PATCH, "프로필 수정이 PATCH 가 아니다")
    }

    /// 내 정보 조회만 프리픽스가 `/api/v1/local` 이다 — 나머지 사용자 API(`/api/v1/users/me/...`)와 다르다.
    /// 틀리면 404 가 아니라 **401** 이 나서(Security 가 미매핑 경로도 보호한다) 세션 만료로 오인한다.
    @Test("내 정보 조회는 local 프리픽스를 쓴다")
    func myProfile() {
        #expect(UserApiRoute.getMyProfile.route.path == "api/v1/local/users/info")
    }

    /// 반대로 푸시 토큰만 `/api/v1/users` 다 — 같은 `UserApi` 안에서 내 정보 조회(`/api/v1/local`)와
    /// 프리픽스가 갈린다. 백엔드 컨트롤러가 실제로 둘로 나뉘어 있어서 생긴 비대칭이고
    /// (`LocalUserController` vs `UserController`), 한쪽에 맞춰 통일하면 401 이 난다.
    @Test("푸시 토큰 등록과 해제는 users me 경로를 쓴다")
    func fcmPaths() {
        #expect(UserApiRoute.registerFcmToken.route.path == "api/v1/users/me/fcm-token")
        #expect(UserApiRoute.deleteFcmToken.route.path == "api/v1/users/me/fcm-token")
    }

    /// 경로가 같고 동사만 다른 쌍이라 path 검사만으로는 POST 오타를 못 잡는다.
    /// 서버는 `@PutMapping`/`@DeleteMapping` 만 매핑하므로 POST 로 보내면 405 가 난다.
    @Test("푸시 토큰 등록은 PUT 해제는 DELETE 다")
    func fcmVerbs() {
        #expect(UserApiRoute.registerFcmToken.route.method == .PUT, "등록이 PUT 이 아니다")
        #expect(UserApiRoute.deleteFcmToken.route.method == .DELETE, "해제가 DELETE 가 아니다")
    }

    /// 회원 탈퇴. `/users/me` 는 프로필 수정(PATCH)과 **경로가 같고 동사만 다르다** — path 검사만으로는
    /// 둘이 뒤바뀌어도 통과하므로 `HTTP` 의 세 값을 모두 못 박는다.
    ///
    /// `hasBody = true` 가 특히 중요하다. 서버가 비밀번호를 `@RequestBody` 로 받는데 `ApiRoute.DELETE` 는
    /// 본문을 못 실으므로 `HTTP` 가 유일한 길이다. 실제로 본문이 실려 나가는지는
    /// `UserApiDeleteBodyTest` 가 확인한다.
    ///
    /// 탈퇴가 `AuthApi` 로 옮겨 가는 것도 막는다 — 그쪽은 Bearer 가 붙지 않아 `@CurrentUser` 가
    /// 대상을 못 찾고 401 `USER005` 가 된다.
    @Test("회원 탈퇴는 users me 경로의 DELETE 이고 본문을 싣는다")
    func deleteAccount() async throws {
        let route = UserApiRoute.deleteAccount.route

        #expect(route.path == "api/v1/users/me")
        #expect(route.method == .DELETE)
        #expect(route.hasBody, "탈퇴 요청이 본문을 싣지 않는다 — 비밀번호를 보낼 자리가 없다")
        // 비밀번호가 경로·쿼리로 새면 서버 액세스 로그에 평문으로 남는다.
        #expect(route.pathParameterNames.isEmpty)
        #expect(route.queryNames.isEmpty)
        // 원본의 「@Body 파라미터가 하나」 자리. 호출부 서명이 본문 하나만 받는지를 컴파일로, 실린 값을 실행으로 본다.
        let stub = StubServer(status: 204)
        let api = RestUserApi(rest: try stub.rest())
        let call: (AccountDeletionRequest) async throws -> Void = api.deleteAccount(request:)
        try await call(AccountDeletionRequest(password: "p"))
        #expect(stub.requests.first?.bodyString == #"{"password":"p"}"#)

        #expect(
            AuthApiRoute(rawValue: "deleteAccount") == nil,
            "탈퇴가 Bearer 없는 AuthApi 쪽으로 옮겨졌다 — 401 USER005 가 된다"
        )
    }

    /// 프로필 이미지 두 경로는 **생김새가 닮아 바꿔 쓰기 쉽다** — 목록은 복수형에 `/me` 가 없고
    /// (`api/v1/users/profile-images`), 되돌리기는 단수형에 `/me` 가 있다
    /// (`api/v1/users/me/profile-image`). 둘을 뒤집으면 404 가 아니라 **401** 로 떨어져
    /// (Security 가 미매핑 경로도 보호한다) 세션 만료로 오인한다.
    ///
    /// **되돌리기에서 뒤 조각이 빠지면 그건 회원 탈퇴다**(`DELETE /api/v1/users/me` — 이 파일의
    /// 「회원 탈퇴는 users me 경로의 DELETE 이고 본문을 싣는다」 가 고정하는 그 경로다). 동사까지 같은
    /// DELETE 라 요청은 204 로 성공하고, 사용자는 「기본 이미지로 바꿨다」고 생각하는데 **계정이 지워진다.**
    /// 그래서 경로 값만이 아니라 「탈퇴와 다른 경로인가」를 따로 단언한다.
    ///
    /// 기준은 백엔드 `user/users/presentation/UserController.java` 소스다(실서버 미검증) —
    /// 다시 바뀌면 이 테스트부터 깨지는 게 정상이다.
    @Test("프로필 이미지 목록과 되돌리기는 서로 다른 경로를 쓴다")
    func profileImages() {
        let list = UserApiRoute.getProfileImages.route
        let reset = UserApiRoute.resetProfileImage.route

        #expect(list.path == "api/v1/users/profile-images")
        #expect(reset.path == "api/v1/users/me/profile-image")

        #expect(list.method == .GET, "목록 조회가 GET 이 아니다")
        #expect(reset.method == .DELETE, "되돌리기가 DELETE 가 아니다")

        #expect(
            UserApiRoute.deleteAccount.route.path != reset.path,
            "되돌리기가 회원 탈퇴와 같은 경로를 탄다 — 같은 DELETE 라 성공하고 계정이 지워진다"
        )
        // 탈퇴처럼 본문을 싣는 우회(HTTP hasBody)를 복사해 오면 서버 매핑과 어긋난다 — 되돌리기는 본문이 없다.
        #expect(!reset.hasBody, "되돌리기에 본문 파라미터가 붙었다 — 서버는 본문 없는 DELETE 를 매핑한다")
    }

    @Test("합류는 partyId 만 담은 경로를 쓴다")
    func joinPath() {
        #expect(MatchingApiRoute.joinParty.route.path == "api/v1/matching/rooms/{partyId}/join")
    }

    /// 예전에는 서버 매핑에 쓰이지 않는 `{memberId}` 세그먼트가 남아 있어 더미 `/0` 을 박아야 했다.
    /// 백엔드가 매핑을 `/matching/leave/{partyId}` 로 정리해 그 잔재가 사라졌다
    /// (실측: `/leave/{id}` → 204, `/leave/{id}/0` → 404). 되살아나지 않게 값을 고정한다.
    @Test("나가기 경로에 더미 세그먼트가 없다")
    func leavePath() {
        #expect(MatchingApiRoute.leaveParty.route.path == "api/v1/matching/leave/{partyId}")
    }

    /// 방 상세 경로에 **세그먼트가 붙지 않는 것**을 못박는다.
    ///
    /// 예전에는 `/status` 가 붙은 가벼운 상태 조회가 따로 있었고, 이 테스트는 둘을 혼동하지 않게
    /// 두 경로를 함께 고정했다. 백엔드가 `GET /matching/rooms/{partyId}/status` 와 지문을
    /// **삭제했으므로**(`04f6be7` — 매칭방 변화가 SSE 전용이 되어 폴링용 조회가 쓰이지 않게 됐다)
    /// 지금은 상세 하나만 남는다. `/status` 를 되살리면 **404** 다.
    ///
    /// 25·26 의 주기 조회가 이 경로로 옮겨와 **폴링이 이 한 경로에 걸려 있다** — 틀리면 두 화면이
    /// 배차·운행 전이를 영영 못 잡는다(그 전이에는 SSE 도 FCM 도 없다).
    @Test("방 상세 조회 경로에는 뒤에 붙는 세그먼트가 없다")
    func partyDetailPath() {
        #expect(MatchingApiRoute.getPartyDetail.route.path == "api/v1/matching/rooms/{partyId}")
        // 삭제된 상태 조회가 되살아나면 여기서 먼저 걸린다.
        #expect(
            MatchingApiRoute(rawValue: "getPartyStatus") == nil,
            "MatchingApi 에 상태 조회(/status) 메서드가 되살아났다 — 서버에 없는 경로다"
        )
    }

    @Test("기사 위치 조회는 partyId 만 담은 경로를 쓴다")
    func driverLocationPath() {
        #expect(DispatchApiRoute.getDriverLocation.route.path == "api/v1/dispatch/rides/{partyId}")
    }

    @Test("즐겨찾기는 userId 없이 me 경로를 쓴다")
    func favoritesPaths() {
        #expect(PlaceApiRoute.addFavoritePlace.route.path == "api/v1/users/me/favorite-places")
        #expect(PlaceApiRoute.getFavoritePlaces.route.path == "api/v1/users/me/favorite-places")
        // 삭제 3종(실측 2026-11-01, 로컬 :8080). `all` 리터럴은 `{placeId}` 템플릿을 이긴다(실측 204).
        #expect(PlaceApiRoute.deleteFavoritePlace.route.path == "api/v1/users/me/favorite-places/{placeId}")
        #expect(PlaceApiRoute.deleteFavoritePlaces.route.path == "api/v1/users/me/favorite-places/batch-delete")
        #expect(PlaceApiRoute.deleteAllFavoritePlaces.route.path == "api/v1/users/me/favorite-places/all")
    }

    /// **다건 삭제는 POST 다.** 「삭제니까 DELETE 로 정리」하는 손길을 막는 것이 이 테스트의 전부다.
    ///
    /// 틀렸을 때의 실패 모양이 405 가 아니라 **400
    /// `{"code":"INVALID_REQUEST","message":"placeId: 형식이 올바르지 않습니다."}`** 다(실측 2026-11-01,
    /// 로컬 `:8080`) — `DELETE .../favorite-places/{placeId}` 매핑이 "batch-delete" 를 placeId 로 잡아
    /// Long 변환에 실패한 것이다. 즉 **조용히 엉뚱한 엔드포인트로 가서** 「메서드 미지원」처럼 보이지
    /// 않으므로, 디버깅이 본문·검증 쪽으로 샌다. `UserApi.deleteAccount` 의 `HTTP(hasBody: true)` 를
    /// 복사하면 바로 이 상태가 된다.
    @Test("즐겨찾기 다건 삭제는 POST 다")
    func batchDeleteIsPost() {
        let route = PlaceApiRoute.deleteFavoritePlaces.route

        #expect(route.method == .POST, "batch-delete 가 POST 가 아니다")
        #expect(route == .POST(route.path), "batch-delete 가 HTTP 로 선언됐다 — DELETE 로 나가면 400 INVALID_REQUEST placeId 다")
    }

    // 백엔드가 이 경로를 `{reportId}` 유무로 오간 이력이 있다. 현행 컨트롤러
    // (report/interfaces/ReportController.java)는 reportId 없이 @CurrentUser 의 신고에 기록한다 —
    // 컨트롤러 소스 기준(실서버 미검증)이며, 다시 바뀌면 이 테스트부터 깨지는 게 정상이다.
    @Test("통화 결과 확정은 reportId 없는 경로를 쓴다")
    func callResultPath() {
        #expect(ReportApiRoute.confirmCallResult.route.path == "api/v1/reports/call-result")
    }

    /// 전환된 엔드포인트에 memberId/userId 가 되살아나는 걸 막는다.
    /// 채팅이 마지막 예외였는데 백엔드가 `@CurrentUser` 로 넘기면서 **전 도메인이 대상이 됐다**
    /// (방 생성은 본문 creatorId 를 떼면서 합류됐고, 본문 쪽은
    /// `PartyMappersTest` 의 「생성 요청 본문에 방장 id 를 싣지 않는다」 가 지킨다).
    @Test("전환된 API 어디에도 memberId userId 파라미터가 남아 있지 않다")
    func noMemberIdOrUserId() {
        func leftovers<R: ApiRouteSet & RawRepresentable>(_: R.Type) -> [String] where R.RawValue == String {
            R.allCases
                .filter { !Set($0.route.pathParameterNames + $0.route.queryNames).isDisjoint(with: ["memberId", "userId"]) }
                .map { "\(R.self).\($0.rawValue)" }
        }

        let found = leftovers(MatchingApiRoute.self) + leftovers(DispatchApiRoute.self) + leftovers(PlaceApiRoute.self)
            + leftovers(ReportApiRoute.self) + leftovers(UserApiRoute.self) + leftovers(ChatApiRoute.self)

        #expect(found.isEmpty, "토큰이 정하는 주체를 앱이 다시 보내고 있다: \(found)")
    }

    // 참여자 목록도 주체는 토큰이다 — 서버가 @CurrentUser 로 "부른 사람이 참여자인지"를 검사한다.
    // GET 이라 본문이 없고, 경로에 남길 수 있는 건 chatRoomId 뿐이어야 한다.
    @Test("참여자 목록 조회는 GET 이고 방 id 만 경로에 담는다")
    func membersRoute() {
        let members = ChatApiRoute.getMembers.route

        #expect(members.method == .GET, "참여자 목록이 GET 이 아니다")
        #expect(members.pathParameterNames.count == 1)
    }

    /// 채팅은 오랫동안 `@RequestHeader("X-User-Id")` 를 받는 유일한 도메인이었다. 토큰 주체와 헤더 id 가
    /// 서로 검증되지 않아 **누가 로그인하든 고정 id 로 채팅이 나갔다** — 백엔드가 `@CurrentUser` 로
    /// 넘어간 지금 헤더가 하나라도 되살아나면 그 버그가 그대로 돌아온다.
    ///
    /// 주체는 이제 Bearer 토큰뿐이고, 그건 `ChatApi` 가 apiClient(인터셉터가 Bearer 를 붙이고
    /// 401 이면 재발급하는 클라이언트)로 생성되기 때문에 붙는다(`NetworkModule.create`).
    ///
    /// 원본은 파라미터 애노테이션을 리플렉션으로 봤다. 여기는 그 수단이 없어 **모든 메서드를 실제로 불러**
    /// 나간 헤더를 본다. 아래 switch 는 빠짐없이 적어야 컴파일되므로 새 메서드도 이 검사를 피할 수 없다.
    @Test("채팅 API 에는 헤더 파라미터가 하나도 없다")
    func chatHasNoHeaderParameters() async throws {
        let stub = StubServer(status: 200, body: "{}")
        let api = RestChatApi(rest: try stub.rest())

        for route in ChatApiRoute.allCases {
            // 응답 모양은 이 검사의 관심이 아니다 — 요청이 나간 것까지만 본다.
            switch route {
            case .getRoom: _ = try? await api.getRoom(chatRoomId: 1)
            case .getMyRooms: _ = try? await api.getMyRooms()
            case .joinRoom: try await api.joinRoom(chatRoomId: 1)
            case .leaveRoom: try await api.leaveRoom(chatRoomId: 1)
            case .getMembers: _ = try? await api.getMembers(chatRoomId: 1)
            case .muteNotification: try await api.muteNotification(chatRoomId: 1)
            case .unmuteNotification: try await api.unmuteNotification(chatRoomId: 1)
            case .readRoom: try await api.readRoom(chatRoomId: 1, readMessageId: 2)
            case .getMessages: _ = try? await api.getMessages(chatRoomId: 1, cursor: nil, size: 30)
            case .getMessagesAfter: _ = try? await api.getMessagesAfter(chatRoomId: 1, cursor: 2, size: 30)
            case .sendMessage: _ = try? await api.sendMessage(chatRoomId: 1, request: SendMessageRequestDto(content: "x"))
            case .deleteMessage: try await api.deleteMessage(chatRoomId: 1, messageId: 2)
            case .searchMessages: _ = try? await api.searchMessages(chatRoomId: 1, keyword: "kw", cursor: nil, size: 30)
            case .reportMessage:
                try await api.reportMessage(
                    chatRoomId: 1,
                    request: ChatReportRequestDto(chatMessageId: 2, reason: "SPAM")
                )
            }
        }

        #expect(stub.requests.count == ChatApiRoute.allCases.count)
        let allowed: Set<String> = ["content-type", "accept", "accept-encoding", "accept-language", "user-agent", "content-length"]
        let withHeaders = stub.requests.filter { request in
            !request.headers.keys.allSatisfy { allowed.contains($0.lowercased()) }
        }
        #expect(withHeaders.isEmpty, "채팅이 사용자 id 를 헤더로 다시 싣고 있다: \(withHeaders.map(\.headers))")
    }

    /// 채팅만 경로 프리픽스가 `/api/v1/chat-rooms` 다. 메시지 조회/전송은 같은 경로에 동사만 다른 쌍이라
    /// path 만으로는 오타를 못 잡아 검색·after 처럼 세그먼트가 붙는 쪽을 함께 못 박는다.
    @Test("채팅 경로는 chat-rooms 프리픽스를 쓴다")
    func chatPaths() {
        #expect(ChatApiRoute.getMyRooms.route.path == "api/v1/chat-rooms/me")
        #expect(ChatApiRoute.joinRoom.route.path == "api/v1/chat-rooms/{chatRoomId}/users")
        // 참여자 목록은 합류/나가기와 경로가 같고 동사만 GET 이다 — 참여자만 부를 수 있어
        // 잘못 짚으면 404 가 아니라 403(CHAT_NOT_PARTICIPANT)처럼 보인다.
        #expect(ChatApiRoute.getMembers.route.path == "api/v1/chat-rooms/{chatRoomId}/users")
        #expect(ChatApiRoute.readRoom.route.path == "api/v1/chat-rooms/{chatRoomId}/users/read/{readMessageId}")
        #expect(ChatApiRoute.getMessages.route.path == "api/v1/chat-rooms/{chatRoomId}/messages")
        #expect(ChatApiRoute.getMessagesAfter.route.path == "api/v1/chat-rooms/{chatRoomId}/messages/after")
        #expect(ChatApiRoute.searchMessages.route.path == "api/v1/chat-rooms/{chatRoomId}/messages/search")
        // 복수형 `reports` 다. `/report` 로 적으면 Security 가 미매핑 경로도 보호해서 404 가 아니라
        // **401** 로 떨어지고, 앱은 그걸 재발급 실패(세션 만료)로 읽는다 — 신고가 안 되는 게 아니라
        // 로그인이 풀린 것처럼 보인다.
        #expect(ChatApiRoute.reportMessage.route.path == "api/v1/chat-rooms/{chatRoomId}/reports")
    }

    /// 채팅 메시지 신고와 긴급 신고는 **다른 엔드포인트·다른 본문**이다. 둘을 한 DTO 로 합치려는
    /// 시도를 막는다 — 긴급 신고에는 사유 필드가 없고(`ReportDtos` 주석: 「사유(reason) 필드는
    /// 서버에 없다 — 임의로 추가하지 말 것」) 메시지 신고에는 `reason` 이 **필수**다. 섞으면
    /// 서버가 400 `INVALID_REQUEST` 를 낸다(실측 2026-11-01).
    ///
    /// 이름이 비슷해서(`reportMessage` / `report`) 다음 사람이 「신고는 하나로 합치자」로 손대기
    /// 쉬운 자리다. 그러면 사유가 붙은 본문이 `POST /api/v1/reports` 로 가거나 좌표가 메시지
    /// 신고로 가서 **둘 다 400** 이 된다. 신고 대상도 다르다 — 그쪽은 파티, 이쪽은 메시지 1건이다.
    @Test("메시지 신고와 긴급 신고는 서로 다른 본문 타입을 쓴다")
    func reportBodiesDiffer() async throws {
        let stub = StubServer(status: 200, body: #"{"reportId":1}"#)
        let chat = RestChatApi(rest: try stub.rest())
        let report = RestReportApi(rest: try stub.rest())

        // 본문 타입은 컴파일이 못 박는다: 이 대입은 서명이 정확히 이 DTO 를 받을 때만 통과한다.
        let chatReport: (Int64, ChatReportRequestDto) async throws -> Void = chat.reportMessage(chatRoomId:request:)
        let emergency: (ReportRequestDto) async throws -> ReportResponse = report.report(request:)

        try await chatReport(7, ChatReportRequestDto(chatMessageId: 2, reason: "SPAM"))
        _ = try await emergency(ReportRequestDto(partyId: 3, latitude: 37.5, longitude: 127.0))

        let chatKeys = Set(try parseJSONObject(try #require(stub.requests[0].bodyString)).keys)
        let emergencyKeys = Set(try parseJSONObject(try #require(stub.requests[1].bodyString)).keys)
        #expect(chatKeys == ["chatMessageId", "reason"])
        #expect(emergencyKeys == ["partyId", "latitude", "longitude"])
        #expect(chatKeys != emergencyKeys)

        // 메시지 신고는 **방 id 만** 경로에 담는다 — 신고자는 토큰이, 피신고자는 서버가 메시지에서
        // 찾는다. 경로에 사용자 id 가 끼면 「전환된 API 어디에도 memberId userId 가 없다」와 충돌한다.
        #expect(ChatApiRoute.reportMessage.route.pathParameterNames.count == 1)
    }

    /// 탑승 기록(2026-11-01 신규). 경로가 **`/api/v1/users/me/parties`** 다 — 같은 `UserApi` 안에
    /// 프리픽스가 셋(`/api/v1/local`·`/api/v1/users`·`/api/v1/auth` 금지)이라 가장 틀리기 쉬운 자리고,
    /// 틀리면 404 가 아니라 **401** 로 떨어져 세션 만료로 오인한다(Security 가 미매핑 경로도 보호한다).
    ///
    /// 특히 `/api/v1/local/users/parties`(내 정보 조회의 프리픽스를 복사)와
    /// `/api/v1/matching/users/me/parties`(「방 목록」으로 읽고 매칭 쪽에 두는 실수)를 값으로 막는다.
    ///
    /// 쿼리가 **`cursor`·`size` 둘뿐**인 것도 함께 못 박는다. `status` 를 붙이는 실수가
    /// 특히 위험하다 — 서버에 그 파라미터가 없는데 400 이 아니라 **200 + 조용히 무시**라서
    /// (실측 2026-11-01: `?status=ACTIVE` → 200, 결과 동일) 「필터가 동작한다」고 착각하고 지나간다.
    @Test("탑승 기록 조회는 users me parties 경로의 GET 이고 쿼리가 cursor size 둘뿐이다")
    func rideRecordRoute() {
        let records = UserApiRoute.getMyRideRecords.route

        #expect(records.path == "api/v1/users/me/parties")
        #expect(records.method == .GET, "탑승 기록 조회가 GET 이 아니다")
        #expect(records.queryNames == ["cursor", "size"])
    }
}
