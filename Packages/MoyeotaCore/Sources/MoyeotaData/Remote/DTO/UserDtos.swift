/// GET /api/v1/local/users/info 의 200 응답.
/// 백엔드 `UserResponse(UUID uuid, String name, String imageUrl)` 와 필드 1:1.
///
/// 실측(2026-11-01, localhost:8080, `moyeota1` — 사진을 고른 적 없는 사용자):
/// `{"uuid":"01a187cc-3d2f-74c3-94d5-b0d8657088ac","name":"모여타일","imageUrl":"https://cdn.moyeota.co.kr/profile/presets/default.png"}`
/// 사진을 고른 뒤에는 `imageUrl` 만 `…/profile/presets/07.png` 로 바뀐다.
///
/// (옛 실측, `imageUrl` 이 생기기 전: `{"uuid":"01a06145-…","name":"김성윤"}` — 필드가 둘이었다.)
///
/// **`name` 이 nullable 인 건 방어가 아니라 서버 계약 그대로다.**
/// `LocalUserService.getProfile` 은 `user.nickname` 을 먼저 보고, 없으면 프로필 실명으로 폴백한 뒤
/// 그마저 없으면 `null` 을 내려보낸다(`orElse(null)`). 현재 서버에는 닉네임 설정 경로 자체가 없어
/// 항상 실명이 오지만, 프로필이 비어 있는 사용자에게는 `"name":null` 이 그대로 내려온다
/// — Jackson 이 null 을 지우지 않으므로 키는 남고 값만 null 이다. 논-널로 선언하면 그 순간 파싱이 터진다.
///
/// `uuid` 의 기본값은 서버가 필드를 빼는 경우가 아니라 **빈 값 판정을 Repository 한 곳으로 모으기 위한 것**이다
/// (`RegisterResponse` 와 같은 방식).
///
/// `imageUrl` 은 2026-10-15 배포(Backend #235)로 생겼다. **서버는 이 값을 비워 보내지 않는다** —
/// 고른 적 없는 사용자에게는 기본 이미지의 전체 주소를 준다(`ProfileImages.toUrl` 이 key 가 null 이면
/// `default-key` 를 붙인다). 기본값 null 은 구버전 서버 대비용이다.
public struct UserProfileResponse: Decodable, Equatable, Sendable {
    public var uuid: String
    public var name: String?
    public var imageUrl: String?

    public init(uuid: String = "", name: String? = nil, imageUrl: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.imageUrl = imageUrl
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, name, imageUrl
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeOrDefault(.uuid, default: "")
        name = try c.decodeIfPresent(String.self, forKey: .name)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
    }
}

/// GET /api/v1/users/profile-images 의 200 응답 **항목**. 본문은 엔벨로프 없는 벗은 JSON 배열이다.
/// 백엔드 `ProfileImageResponse(String key, String url)` 과 필드 1:1.
///
/// **`key` 와 `url` 의 순서를 뒤집지 마라.** `key` 가 `PATCH /users/me` 에 싣는 값이고
/// (`UpdateProfileRequest.imageKey`) `url` 은 화면에 그리는 CDN 전체 주소다. 뒤집어 보내면
/// 400 `USER112` 인데, 원인이 응답 파싱이라 추적이 어렵다 — 그래서 매퍼에 전용 테스트가 있다.
///
/// 기본 이미지(`profile/presets/default.png`)는 **이 목록에 들어 있지 않다**. 서버 설정의
/// `default-key` 는 `presets` 목록 밖이고, 그래서 기본 키로 PATCH 하면 프리셋이 아니라 400 이다.
public struct ProfileImageResponse: Decodable, Equatable, Sendable {
    public var key: String
    public var url: String

    public init(key: String = "", url: String = "") {
        self.key = key
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case key, url
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeOrDefault(.key, default: "")
        url = try c.decodeOrDefault(.url, default: "")
    }
}

/// PATCH /api/v1/users/me 의 요청 본문 — 백엔드 `UpdateProfileRequest(String nickname, String imageKey)`.
///
/// **`imageUrl` 이 아니라 `imageKey` 다.** 2026-10-15 배포(Backend #235)부터 서버는 아무 URL 이나
/// 받지 않고 자기가 제공하는 16장의 **S3 키**(`profile/presets/03.png`)만 받는다 — 목록은
/// `GET /api/v1/users/profile-images` 가 `{key, url}` 로 준다. 목록에 없는 키는 400 `USER112`.
/// 옛 이름 `imageUrl` 로 보내면 **에러가 아니라 조용히 무시된다**(Spring 이 모르는 필드를 버린다).
/// 서버는 아무것도 바꾸지 않고 204 를 주므로, 틀린 이름을 쓰면 성공한 줄 알고 넘어가게 된다.
///
/// **null 필드는 본문에서 아예 빠진다**(합성 `Encodable` 이 옵셔널을 `encodeIfPresent` 로 쓴다).
/// 서버가 "넘어온 것만 갱신"하는 계약이라 이게 정확히 맞는 동작이다 — null 을 실어 보내도 결과는 같지만,
/// 빼는 쪽이 의도가 분명하다. 둘 다 null 이면 서버는 아무것도 하지 않고 204 를 준다.
///
/// 대상 사용자는 `@CurrentUser` 가 Bearer 에서 뽑으므로 본문에 식별자를 넣을 자리가 없다.
public struct UpdateProfileRequest: Codable, Equatable, Sendable {
    public var nickname: String?
    public var imageKey: String?

    public init(nickname: String? = nil, imageKey: String? = nil) {
        self.nickname = nickname
        self.imageKey = imageKey
    }
}

/// DELETE /api/v1/users/me 의 요청 본문 — 백엔드 `UserDeletionRequest(@NotBlank String password)`.
/// 키 이름은 반드시 `password` 다.
///
/// **DELETE 에 본문이 실린다는 게 이 DTO 의 전부다.** 그 사정은 `UserApi.deleteAccount` 주석에 적는다.
///
/// 누구를 지우는지는 싣지 않는다. 대상은 `@CurrentUser` 가 Bearer 에서 뽑는다
/// — 그래서 이 호출은 **반드시 인증 클라이언트**(`UserApi`)로 나가야 한다.
///
/// 빈 문자열은 서버가 400 `INVALID_REQUEST` 로 튕긴다(`@NotBlank`). 화면이 빈 입력으로는 버튼을
/// 누를 수 없게 막으므로(`canSubmitAccountDeletion`) 실제로 나가지는 않는다.
public struct AccountDeletionRequest: Codable, Equatable, Sendable {
    public var password: String

    public init(password: String) {
        self.password = password
    }
}

/// PUT /api/v1/users/me/fcm-token 의 요청 본문.
/// 백엔드 `user.application.dto.RegisterFcmTokenRequest(@NotBlank String token)` 와 필드 1:1 —
/// 키 이름은 반드시 `token` 이다.
///
/// **누구의 토큰인지는 싣지 않는다.** 대상 사용자는 `@CurrentUser` 가 Bearer 에서 뽑으므로
/// 본문에 userId 를 넣을 자리가 없다(넣어도 무시된다).
///
/// 빈 문자열은 서버가 400 으로 튕긴다(`@NotBlank`). FCM SDK 가 빈 토큰을 주는 일은 없지만,
/// 보내기 전에 `FcmTokenRegistrar` 가 한 번 더 걸러 낸다 —
/// 400 을 받아 봐야 앱이 할 수 있는 일이 없기 때문이다.
public struct FcmTokenRequest: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}
