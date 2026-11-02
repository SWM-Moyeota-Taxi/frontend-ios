import Foundation
@testable import MoyeotaData

/// `json.decodeFromString<T>(body)` 자리 — 운영과 같은 디코더로 읽어야 실제 경로를 검증하는 것이 된다.
func decodeJSON<T: Decodable>(_ type: T.Type = T.self, _ body: String) throws -> T {
    try MoyeotaJSON.decoder.decode(T.self, from: Data(body.utf8))
}

/// `json.encodeToString(value)` 자리.
func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try MoyeotaJSON.encoder.encode(value), as: UTF8.self)
}

/// `json.parseToJsonElement(body).jsonObject` 자리.
func parseJSONObject(_ body: String) throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(body.utf8))
    guard let object = parsed as? [String: Any] else {
        throw CocoaError(.coderReadCorrupt)
    }
    return object
}

/// JUnit `assertEquals(expected, actual, delta)` 자리. null 은 실패다(원본의 `!!`).
func isClose(_ expected: Double, _ actual: Double?, _ delta: Double) -> Bool {
    guard let actual else { return false }
    return abs(expected - actual) <= delta
}

/// `KSerializer.fieldNames()` 자리 — DTO 의 직렬화 계약(JSON 키 이름·순서)을 읽는다.
func fieldNames<Keys: CodingKey & CaseIterable>(_ keys: Keys.Type) -> [String] {
    keys.allCases.map(\.stringValue)
}
