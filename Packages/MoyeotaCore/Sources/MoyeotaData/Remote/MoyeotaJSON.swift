import Foundation

/// 원본 `NetworkModule` 의 `Json { ignoreUnknownKeys = true }` 자리 — REST·에러 본문·SSE 가 같은 설정을 쓴다.
///
/// 모르는 키는 `JSONDecoder` 가 원래 무시한다(서버가 필드를 추가해도 앱이 죽지 않는다). 나머지 설정은
/// kotlinx 기본값과 맞춘다:
///
/// | kotlinx | 여기 |
/// |---|---|
/// | `ignoreUnknownKeys = true` | `JSONDecoder` 기본 동작 |
/// | `coerceInputValues = false` | 명시적 null 을 기본값으로 접지 않는다 — `decodeOrDefault` |
/// | `encodeDefaults = false`, `explicitNulls = true` | 요청 DTO 의 `T? = null` 은 합성 `Encodable` 의 `encodeIfPresent` 로 빠진다 |
/// | `isLenient = false` | `allowsJSON5` 를 켜지 않는다 |
/// | 슬래시를 이스케이프하지 않는다 | `.withoutEscapingSlashes` |
///
/// `.sortedKeys` 는 원본에 없다. `JSONEncoder` 는 선언 순서를 지키지 않아 본문이 실행마다 달라질 수 있으므로
/// 정렬로 고정한다 — JSON 객체는 순서가 없어 서버 계약은 그대로다.
public enum MoyeotaJSON {
    public static let decoder = JSONDecoder()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

extension KeyedDecodingContainer {
    /// kotlinx 의 「기본값이 있는 non-null 필드」 그대로다: **키가 없으면 기본값, 명시적 null 이면 예외.**
    ///
    /// `decodeIfPresent(...) ?? 기본값` 으로 쓰면 안 된다. 그건 명시적 null 까지 기본값으로 접는데, 원본이 일부러
    /// 켜지 않은 `coerceInputValues` 와 같은 동작이다 — accessToken(→ ""), chatRoomId(→ 0), 파티 status(→ "") 의
    /// null 까지 조용히 삼켜, 빈 Bearer 로 401 루프를 도는 쪽이 파싱 실패보다 훨씬 늦게 발견된다
    /// (`PlaceSearchListResponse.PlaceSearchItem.roadName` 주석). null 이 정말 오는 자리는 DTO 가 `T?` 로 받는다.
    ///
    /// 나머지 두 모양은 표준 API 와 일치한다: `T? = null` 은 `decodeIfPresent`, 기본값 없는 non-null 은 `decode`.
    /// (기본값 없는 `T?` 는 kotlinx 에서 키 누락이 예외이므로 `decode(T?.self, forKey:)` 로 받아야 한다.)
    func decodeOrDefault<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) throws -> T {
        contains(key) ? try decode(T.self, forKey: key) : defaultValue()
    }
}
