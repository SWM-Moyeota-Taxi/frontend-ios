/// 고를 수 있는 프로필 이미지 한 장. `GET /api/v1/users/profile-images` 의 항목이다.
///
/// ### `key` 와 `url` 을 바꿔 쓰면 안 된다
/// - `key` 는 **서버에 보내는 값**이다(`PATCH /api/v1/users/me` 의 `imageKey`). 예: `profile/presets/03.png`
/// - `url` 은 **화면에 그리는 값**이다(CDN 전체 주소). 예: `https://cdn.moyeota.co.kr/profile/presets/03.png`
///
/// 둘을 뒤집어 보내면 서버가 400 `USER112`
/// (`AuthError.invalidProfileImage`)
/// 로 거절한다 — 저장은 되지 않지만 원인이 "응답 파싱에서 두 필드가 바뀌었다"라 추적이 어렵다.
/// 그래서 매퍼에 전용 테스트를 둔다.
///
/// ### 기본 이미지는 이 목록에 없다
/// 서버 설정의 `default-key`(`profile/presets/default.png`)는 `presets` 목록 **밖**이고, 목록은 정확히
/// 16장이다. 기본 키를 `key` 로 보내면 프리셋이 아니라서 400 `USER112` 다 — 기본으로 되돌리려면
/// `AuthRepository.resetProfileImage`
/// (`DELETE /api/v1/users/me/profile-image`)를 써야 한다. `imageKey = null` 은 "되돌리기"가 아니라
/// **"건드리지 마라"** 라는 뜻이다.
///
/// 그 대신 이 분리 덕에 화면이 「아직 안 고름」을 알 수 있다 —
/// `UserProfileInfo.imageUrl` 이 `default.png` 로 끝나면 고른 적이 없는 것이다.
public struct ProfileImage: Hashable, Sendable {
    public var key: String
    public var url: String

    public init(key: String, url: String) {
        self.key = key
        self.url = url
    }
}
