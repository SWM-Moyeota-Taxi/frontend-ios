import MoyeotaDomain

extension UserProfileResponse {
    /// `UserResponse` → `UserProfileInfo`.
    ///
    /// 서버의 `name` 은 "닉네임 → 실명 → null" 폴백의 결과라 **빈 문자열도 없음으로 취급한다** —
    /// 화면이 빈 값과 null 을 따로 다루게 두면 폴백 표시가 두 갈래로 갈라진다.
    /// 도메인에서 없음은 오직 `null` 하나다.
    ///
    /// `UserProfileInfo.imageUrl` 에도 **같은 규칙**을 쓴다. 두 필드가 서로 다른 "없음"을 가지면
    /// 화면이 폴백을 두 갈래로 만들게 된다.
    func toDomain() -> UserProfileInfo {
        UserProfileInfo(
            uuid: uuid,
            name: name?.takeIfNotBlank(),
            imageUrl: imageUrl?.takeIfNotBlank()
        )
    }
}

extension ProfileImageResponse {
    /// `ProfileImageResponse` → `ProfileImage`.
    ///
    /// 필드를 **뒤집지 않는 것**이 이 매퍼의 전부다 — `ProfileImage.key` 는 서버에 보내는 값이고
    /// `ProfileImage.url` 은 그리는 값이라, 바뀌면 PATCH 가 400 `USER112` 로 거절된다
    /// (그리고 격자에는 아무것도 안 그려진다). 이름 인자를 쓰는 이유가 그것이다.
    func toDomain() -> ProfileImage {
        ProfileImage(
            key: key,
            url: url
        )
    }
}
