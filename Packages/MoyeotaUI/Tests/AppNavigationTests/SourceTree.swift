import Foundation

/// 테스트가 소스 문자열을 읽는 입구. 원본 `NavBackStackRulesTest` 의 `sourceRoot` 자리다.
///
/// `#filePath` 로 찾으므로 소스가 있는 Mac 의 시뮬레이터에서만 돈다.
enum SourceTree {
    /// `Packages/MoyeotaUI/Sources`
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AppNavigationTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MoyeotaUI
        .appendingPathComponent("Sources")

    static func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 첫 번째 찾은 자리 전체와 캡처 묶음들.
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func contains(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }
}
