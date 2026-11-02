/// 경로 기준: user/interfaces/LocalUserController.java (`@RequestMapping("/api/v1/local")`).
///
/// **`AuthApi` 와 붙이면 안 된다.** 프리픽스가 `/api/v1/local` 로 다른 것도 이유지만, 결정적인 건
/// 클라이언트가 달라야 한다는 점이다 — `AuthApi` 는 Bearer 도 401 재발급도 붙지 않는 별도
/// 클라이언트를 쓴다(`NetworkModule.create` 참조). 이 조회는 **토큰 필수**라
/// (실측: 무토큰 → 401 `{"code":"USER005","message":"로그인이 필요합니다."}`)
/// 인증 클라이언트 쪽으로 만들어야 하고, 그래서 프로토콜을 따로 둔다.
///
/// 같은 컨트롤러의 가입(`POST /api/v1/local/users`)은 permitAll 구간이지만 앱은 쓰지 않는다
/// — 가입은 `POST /api/v1/auth/register` 로 간다(`AuthApi.register`).
public protocol UserApi: Sendable {

    /// 200. 조회 주체는 토큰이 정한다(`@CurrentUser`) — 경로·쿼리에 식별자를 싣지 않는다.
    ///
    /// 프리픽스가 `/api/v1/users` 가 아니라 `/api/v1/local` 이다. 즐겨찾기(`/api/v1/users/me/...`)와
    /// 헷갈려 `users` 로 적으면 404 가 아니라 **401** 로 떨어져(Security 가 미매핑 경로도 보호한다)
    /// 세션 만료로 오인하기 쉽다. 값은 `AuthenticatedPathContractTest` 가 못 박는다.
    func getMyProfile() async throws -> UserProfileResponse

    /// 내 프로필 수정. 204 No Content. 기준: `user/interfaces/UserController.java`
    /// (프리픽스가 `/api/v1/users` — `getMyProfile` 의 `/api/v1/local` 과 다르다).
    ///
    /// **PATCH 다.** 서버가 `@PatchMapping` 만 매핑하므로 PUT/POST 로 보내면 405 다.
    /// 본문에서 빠진 필드는 건드리지 않는다 — 지우기는 표현할 수 없다
    /// (`UpdateProfileRequest` 참조).
    ///
    /// 닉네임 형식 위반은 400 `USER107`, 중복은 409 `USER108` 이다.
    func updateProfile(request: UpdateProfileRequest) async throws

    /// 고를 수 있는 프로필 이미지 목록. 200, 본문은 **엔벨로프 없는 벗은 배열**이다.
    /// 기준: `user/users/presentation/UserController.java` (`@RequestMapping("/api/v1/users")`).
    ///
    /// **경로에 `/me` 가 없고 복수형이다** — 되돌리기(`resetProfileImage`)는 반대로 `/me` 가 있고 단수다.
    /// 둘을 바꿔 쓰면 404 가 아니라 **401** 로 떨어져 세션 만료로 오인한다(위 `getMyProfile` 주석과 같은 함정).
    /// 값은 `AuthenticatedPathContractTest` 가 못 박는다.
    ///
    /// 사용자와 무관한 정적 목록인데도 **토큰이 필요하다**(`@CurrentUser` 가 없는데도 보호 구간이다).
    /// 즉 로그인 전 화면에서는 부를 수 없다.
    ///
    /// 실측(2026-11-01, 로컬 `:8080`):
    /// - 무토큰 → `401 {"code":"USER005","message":"로그인이 필요합니다."}` (404 가 아니다)
    /// - 토큰 있음 → 200, 엔벨로프 없는 배열 **16개**:
    ///   `[{"key":"profile/presets/01.png","url":"https://cdn.moyeota.co.kr/profile/presets/01.png"}, … 16.png]`
    ///   서버 설정 순서가 그대로 응답 순서다. 기본 키(`profile/presets/default.png`)는 **이 목록에 없다**.
    func getProfileImages() async throws -> [ProfileImageResponse]

    /// 프로필 이미지를 기본값으로 되돌린다. 204 No Content, **멱등**(이미 기본이어도 204).
    /// 기준: `user/users/presentation/UserController.java`.
    ///
    /// `deleteAccount` 의 `HTTP(hasBody: true)` 패턴을 복사하지 마라 — 그건 본문에 비밀번호를
    /// 실어야 해서 쓴 우회이고, 되돌리기는 본문이 없어 평범한 `DELETE` 가 맞다.
    ///
    /// **같은 `/users/me` 계열이지만 탈퇴와 완전히 다른 경로다**: 탈퇴는 `DELETE /users/me`,
    /// 이건 `DELETE /users/me/profile-image`. 뒤에 한 조각을 빠뜨리면 **계정이 지워진다.**
    ///
    /// `updateProfile` 에 `imageKey = nil` 을 보내는 것으로는 이 동작을 표현할 수 없다 —
    /// 서버는 넘어온 필드만 갱신하므로 null 은 "건드리지 마라"는 뜻이다.
    ///
    /// 실측(2026-11-01, 로컬 `:8080`, `moyeota1`):
    /// - `PATCH {"imageKey":"profile/presets/07.png"}` → 204, 직후 조회의 `imageUrl` 이 `…/07.png`
    /// - `DELETE` → 204, 조회가 `…/default.png` 로 돌아옴
    /// - `DELETE` **한 번 더** → 204, 값 그대로 (멱등 확인)
    /// - `PATCH {"imageKey":"profile/presets/default.png"}` → **400 `USER112`** — 기본 키는
    ///   프리셋 목록 밖이라 **직접 고를 수 없다.** 되돌리기 경로가 이 DELETE 뿐인 이유다.
    func resetProfileImage() async throws

    /// 푸시 토큰 등록. 204 No Content, 멱등(같은 토큰을 다시 보내도 덮어쓰기만 한다).
    /// 기준: `user/interfaces/UserController.java` — 이쪽만 프리픽스가 `/api/v1/users` 다
    /// (`getMyProfile` 의 `/api/v1/local` 과 다르다. 둘을 바꿔 쓰면 401 로 떨어져 세션 만료로 오인한다).
    ///
    /// 이 토큰이 있어야 기사 도착 시 `FcmPassengerNotifier` 가 이 사용자를 멀티캐스트 대상에 넣는다
    /// — 등록이 없으면 서버는 조용히 `"FCM 토큰이 등록된 승객이 없음"` 을 로그로 남기고 끝낸다.
    func registerFcmToken(request: FcmTokenRequest) async throws

    /// 푸시 토큰 해제. 204 No Content.
    ///
    /// **로그아웃 API 가 대신 해 주지 않는다** — 서버 `UserFcmTokenService` 주석이 명시하듯
    /// 로그아웃은 리프레시 토큰만 받으므로, 앱이 로그아웃 **직전에** 따로 불러야 한다.
    /// 순서가 뒤집혀 세션을 먼저 비우면 Bearer 가 사라져 401 이 나고, 서버에는 죽은 토큰이 남아
    /// 다음 사용자가 이 기기로 로그인할 때까지 남의 도착 알림이 이 기기로 온다.
    func deleteFcmToken() async throws

    /// 회원 탈퇴. 204 No Content. 기준: `user/deletion/presentation/UserDeletionController.java`
    /// (`@RequestMapping("/api/v1/users")` + `@DeleteMapping("/me")` + `@ResponseStatus(NO_CONTENT)`).
    ///
    /// ### `DELETE` 가 아니라 `HTTP` 인 이유
    /// `ApiRoute.DELETE` 는 Retrofit `@DELETE` 처럼 **본문을 실을 수 없다**(`hasBody = false`).
    /// 그 선언에 본문을 넘기면 `RestClient` 가
    /// `IllegalArgumentException: Non-body HTTP method cannot contain @Body or @Field parameters.`
    /// 로 거부한다 — 즉 「탈퇴하기」를 누른 그 순간에야 드러난다.
    ///
    /// 서버는 비밀번호를 **본문으로** 받으므로(`@Valid @RequestBody UserDeletionRequest`) 본문을
    /// 반드시 실어야 하고, 그 조합을 표현하는 길이 `HTTP(hasBody: true)` 뿐이다. 쿼리로 돌리는 선택지는
    /// 애초에 없다 — 비밀번호가 URL 과 서버 액세스 로그에 평문으로 남는다.
    ///
    /// 본문이 실제로 실려 나가는지는 `UserApiDeleteBodyTest` 와 `LoopbackWireTest` 가 확인한다.
    ///
    /// ### `AuthApi` 가 아니라 여기여야 하는 이유
    /// `@CurrentUser` 로 주체를 정하므로 **Bearer 가 필수다**. `AuthApi` 는 Bearer 도 401 재발급도
    /// 붙지 않는 클라이언트로 만들어지므로(`NetworkModule.create` 의 `publicRest`) 거기 두면
    /// 무토큰 요청이 되어 401 `USER005` 다. `/api/v1/users/` 하위는 Security 의 permitAll 구간도 아니다.
    ///
    /// ### 성공 후
    /// 서버가 리프레시 전량 취소 + 인증 캐시 축출까지 하므로 **이 응답 뒤의 모든 요청은 401 이다.**
    /// 그래서 성공 자리에서 세션·로컬 기억을 비우는 것까지가 한 동작이다
    /// (`RemoteAuthRepository.deleteAccount`).
    ///
    /// 실패: 400 `USER111`(비밀번호 불일치) · 409 `USER110`(진행 중 합승) · 401 `USER005`(무토큰).
    func deleteAccount(request: AccountDeletionRequest) async throws

    /// 내 탑승 기록 한 페이지. 200. 기준: `matching/record/RideRecordController.java`
    /// (`@RequestMapping("/api/v1")` + `@GetMapping("/users/me/parties")`).
    ///
    /// **경로 이름에 속지 마라 — 「내가 참여 중인 방 목록」이 아니다.** 하차까지 끝난 탑승만 온다.
    /// 진행 중인 방은 들어오지 않으므로 `ActivePartyRepository` 의
    /// 로컬 기억을 이것으로 대체할 수 없다(실측 근거는 `RideRecordPageResponse` 주석).
    ///
    /// **`status` 쿼리 파라미터는 없다.** `docs/BACKEND-GAP-CLEANUP.md` §4 가 적어 둔
    /// `?status=FINISHED` 는 구현되지 않은 추측이었다 — 붙여도 서버가 **조용히 무시**하고 200 이다
    /// (실측: `?status=ACTIVE` → 200, 결과가 파라미터 없을 때와 같다). 필터가 필요 없다:
    /// 서버가 이미 완료분만 준다.
    ///
    /// `cursor` 는 이전 응답의 `nextCursor` 를 그대로 보낸다. null 이면 첫 페이지이고, 그 쿼리를
    /// **아예 싣지 않는다**(`UserApiRideRecordQueryTest` 가 나간 URL 로 못 박는다).
    /// `size` 범위는 **1~50**, 서버 기본 20(`RIDE_RECORD_PAGE_SIZE`).
    ///
    /// 경로를 틀리면 404 가 아니라 **401** 로 떨어져 세션 만료로 오인한다(이 파일의 다른 주석과
    /// 같은 함정 — Security 가 미매핑 경로도 보호한다). 값은 `AuthenticatedPathContractTest` 가 못 박는다.
    ///
    /// 실측(2026-11-01, 로컬 `:8080`):
    /// - 기록 없음(`moyeota2`) → 200 `{"rides":[],"nextCursor":null,"hasNext":false}`
    /// - 기록 2건 → 200, `dropoffTime` 내림차순(partyId 69 → 67)
    /// - `size=1` 로 쪼갬 → 1페이지 `nextCursor=69, hasNext=true`,
    ///   `cursor=69` 2페이지 `nextCursor=null, hasNext=false`
    /// - `size=0`·`size=51` → 400 `INVALID_PAGE_SIZE`(`"조회 개수는 1~50 이어야 합니다."`)
    /// - `cursor=abc` → 400 `INVALID_REQUEST`(`"cursor: 형식이 올바르지 않습니다."`)
    /// - `cursor=999999`(없는 기록) · `cursor=<아직 하차 전인 방 id>` → 400 `INVALID_CURSOR`
    /// - 무토큰 → 401 `{"code":"USER005","message":"로그인이 필요합니다."}`
    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse
}

extension UserApi {
    /// 원본의 기본 인자(`cursor = null`, `size = RIDE_RECORD_PAGE_SIZE`) 자리.
    /// 프로토콜 요구사항과 서명을 달리해야 구현이 빠졌을 때 컴파일러가 잡는다.
    public func getMyRideRecords() async throws -> RideRecordPageResponse {
        try await getMyRideRecords(cursor: nil, size: RIDE_RECORD_PAGE_SIZE)
    }

    public func getMyRideRecords(cursor: Int64?) async throws -> RideRecordPageResponse {
        try await getMyRideRecords(cursor: cursor, size: RIDE_RECORD_PAGE_SIZE)
    }
}

enum UserApiRoute: String, CaseIterable, ApiRouteSet {
    case getMyProfile, updateProfile, getProfileImages, resetProfileImage
    case registerFcmToken, deleteFcmToken, deleteAccount, getMyRideRecords

    var route: ApiRoute {
        switch self {
        case .getMyProfile: .GET("api/v1/local/users/info")
        case .updateProfile: .PATCH("api/v1/users/me")
        case .getProfileImages: .GET("api/v1/users/profile-images")
        case .resetProfileImage: .DELETE("api/v1/users/me/profile-image")
        case .registerFcmToken: .PUT("api/v1/users/me/fcm-token")
        case .deleteFcmToken: .DELETE("api/v1/users/me/fcm-token")
        case .deleteAccount: .HTTP(method: .DELETE, path: "api/v1/users/me", hasBody: true)
        case .getMyRideRecords: .GET("api/v1/users/me/parties", query: ["cursor", "size"])
        }
    }
}

struct RestUserApi: UserApi {
    let rest: RestClient

    func getMyProfile() async throws -> UserProfileResponse {
        try await rest.call(UserApiRoute.getMyProfile.route)
    }

    func updateProfile(request: UpdateProfileRequest) async throws {
        try await rest.callUnit(UserApiRoute.updateProfile.route, body: request)
    }

    func getProfileImages() async throws -> [ProfileImageResponse] {
        try await rest.call(UserApiRoute.getProfileImages.route)
    }

    func resetProfileImage() async throws {
        try await rest.callUnit(UserApiRoute.resetProfileImage.route)
    }

    func registerFcmToken(request: FcmTokenRequest) async throws {
        try await rest.callUnit(UserApiRoute.registerFcmToken.route, body: request)
    }

    func deleteFcmToken() async throws {
        try await rest.callUnit(UserApiRoute.deleteFcmToken.route)
    }

    func deleteAccount(request: AccountDeletionRequest) async throws {
        try await rest.callUnit(UserApiRoute.deleteAccount.route, body: request)
    }

    func getMyRideRecords(cursor: Int64?, size: Int) async throws -> RideRecordPageResponse {
        try await rest.call(
            UserApiRoute.getMyRideRecords.route,
            query: ["cursor": cursor.map { String($0) }, "size": String(size)]
        )
    }
}
