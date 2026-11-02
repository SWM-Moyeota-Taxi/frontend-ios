import Foundation

/// 테스트가 소스 문자열을 읽는 입구. 원본 `ConfigChangeStateTest` 의 `sourceRoot` 자리다.
///
/// `#filePath` 로 찾으므로 소스가 있는 Mac 의 시뮬레이터에서만 돈다(실기기에서는 경로가 없다).
enum SourceTree {
    /// `Packages/MoyeotaUI/Sources`
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PresentationCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MoyeotaUI
        .appendingPathComponent("Sources")

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    static func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// `dir` 아래(없으면 Sources 전체)의 Swift 파일 전부.
    static func swiftFiles(under dir: String? = nil) -> [URL] {
        let base = dir.map { root.appendingPathComponent($0) } ?? root
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// 찾은 자리를 문자(`Character`) 위치로 돌려준다. 문자 배열로 짝 맞는 괄호를 찾을 때 쓴다.
    static func matches(_ pattern: String, in text: String, positions: Bool) -> [Range<Int>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            let start = text.distance(from: text.startIndex, to: found.lowerBound)
            return start..<(start + text.distance(from: found.lowerBound, to: found.upperBound))
        }
    }

    /// `let NAME: Int64 = 7_000` 꼴 상수의 값. `dir` 아래에서 찾는다.
    static func int64Constant(_ name: String, under dir: String) -> Int64? {
        let pattern = "(?:let|var)\\s+\(name)(?:\\s*:\\s*\\w+)?\\s*=\\s*([0-9_]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for file in swiftFiles(under: dir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), let value = Range(match.range(at: 1), in: text) {
                return Int64(text[value].replacingOccurrences(of: "_", with: ""))
            }
        }
        return nil
    }
}
