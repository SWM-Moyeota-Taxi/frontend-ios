/// `AppConfigResponse` — 서버가 필드를 늘려도 깨지지 않게 모르는 키는 무시한다.
///
/// 빠진 값은 **동승 모드(false)** 로 본다. 서버 쪽 프로퍼티 기본값(`moyeota.taxi.enabled` 미설정 = true)과
/// 일부러 다르다 — 응답에 키가 없다는 건 설정을 모른다는 뜻이고, 모를 땐 실배포 모드가 안전하다
/// (`AppConfig.Default` 와 같은 이유). 서버 컨트롤러는 항상 이 키를 내려주므로
/// 실제로는 거의 타지 않는 분기다.
///
/// ### 업데이트 기준을 Android 와 다른 키로 읽는 이유
/// 서버의 `minVersionCode`·`recommendedVersionCode` 는 **Android `versionCode` 수열**을 기준으로 한 값이다.
/// iOS 빌드 번호는 그 수열과 아무 관계가 없으므로 이 키로 판정하면 Android 배포에 맞춰 올린 숫자에 iOS 사용자가
/// 잠기거나, 반대로 막아야 할 iOS 빌드가 통과한다. 그래서 **두 키는 아예 읽지 않고**
/// `iosMinVersionCode`·`iosRecommendedVersionCode` 만 받는다(`docs/IOS-DIFFERENCES.md`).
public struct AppConfigResponse: Decodable, Equatable, Sendable {
    public var taxiEnabled: Bool
    /// iOS 강제 업데이트 기준. **키가 없으면 null 이고 아무도 막지 않는다.**
    /// 안 와도 역직렬화가 깨지지 않고, 서버가 나중에 추가하면 그날부터 걸린다.
    public var iosMinVersionCode: Int?
    /// iOS 권장 업데이트 기준. 막지 않고 한 번 알리기만 한다. 위와 같은 이유로 null 기본값이다.
    public var iosRecommendedVersionCode: Int?

    public init(
        taxiEnabled: Bool = false,
        iosMinVersionCode: Int? = nil,
        iosRecommendedVersionCode: Int? = nil
    ) {
        self.taxiEnabled = taxiEnabled
        self.iosMinVersionCode = iosMinVersionCode
        self.iosRecommendedVersionCode = iosRecommendedVersionCode
    }

    private enum CodingKeys: String, CodingKey {
        case taxiEnabled, iosMinVersionCode, iosRecommendedVersionCode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taxiEnabled = try c.decodeOrDefault(.taxiEnabled, default: false)
        iosMinVersionCode = try c.decodeIfPresent(Int.self, forKey: .iosMinVersionCode)
        iosRecommendedVersionCode = try c.decodeIfPresent(Int.self, forKey: .iosRecommendedVersionCode)
    }
}
