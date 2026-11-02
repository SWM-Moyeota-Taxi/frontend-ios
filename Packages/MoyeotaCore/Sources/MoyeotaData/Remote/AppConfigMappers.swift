import MoyeotaDomain

extension AppConfigResponse {
    /// iOS 전용 키를 도메인의 공통 자리로 옮긴다. 도메인과 화면은 플랫폼을 모르고 `minVersionCode` 만 본다 —
    /// Android `versionCode` 수열을 iOS 판정에 쓰면 안 되는 사정은 `AppConfigResponse` 주석에 적었다.
    public func toAppConfig() -> AppConfig {
        AppConfig(
            taxiEnabled: taxiEnabled,
            minVersionCode: iosMinVersionCode,
            recommendedVersionCode: iosRecommendedVersionCode
        )
    }
}
