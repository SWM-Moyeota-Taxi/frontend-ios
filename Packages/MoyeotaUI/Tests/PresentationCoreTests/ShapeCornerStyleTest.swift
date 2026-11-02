import Foundation
import Testing

// 원본에 없는 테스트. SwiftUI 도형의 기본 모서리는 `.continuous`(초타원)이고 원본 `CircleShape`·`RoundedCornerShape` 는
// 원호다. 같은 반지름이어도 모서리 윤곽이 달라지므로 모든 도형에 `.circular` 를 적는다 — 기본값으로 쓰면 컴파일러가 잡지 못한다.
@Suite struct ShapeCornerStyleTest {
    /// `이름(` 부터 짝이 맞는 `)` 까지. 주석 줄은 건너뛴다.
    private func shapeCalls(in text: String) -> [String] {
        let names = ["UnevenRoundedRectangle", "RoundedRectangle", "Capsule", "Path"]
        var found: [String] = []
        let chars = Array(text)
        for match in SourceTree.matches("(?<![A-Za-z`])(?:\(names.joined(separator: "|")))\\(", in: text, positions: true) {
            let lineStart = chars[..<match.lowerBound].lastIndex(of: "\n").map { $0 + 1 } ?? 0
            if String(chars[lineStart..<match.lowerBound]).trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var depth = 0
            var end = match.upperBound - 1
            while end < chars.count {
                if chars[end] == "(" { depth += 1 }
                if chars[end] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end += 1
            }
            found.append(String(chars[match.lowerBound...min(end, chars.count - 1)]))
        }
        return found
    }

    @Test("모든 도형이 .circular 모서리를 쓴다")
    func everyShapeIsCircular() throws {
        let dirs = ["MoyeotaDesignSystem", "PresentationCore", "FeatureAuth", "FeatureOnboarding", "FeatureHome",
                    "FeatureExplore", "FeatureMatching", "FeatureChat", "FeatureMyPage"]
        var seen = 0
        for dir in dirs {
            for file in SourceTree.swiftFiles(under: dir) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for call in shapeCalls(in: text) {
                    // `Path` 는 둥근 사각형을 만들 때만 모서리 값이 있다.
                    if call.hasPrefix("Path("), !call.contains("roundedRect:") { continue }
                    seen += 1
                    #expect(call.contains("style: .circular"), "\(file.lastPathComponent): \(call)")
                }
                #expect(!text.contains(".clipShape(.capsule)"), "\(file.lastPathComponent)")
                #expect(!text.contains("in: .capsule"), "\(file.lastPathComponent)")
                #expect(!text.contains(".rect(cornerRadius"), "\(file.lastPathComponent)")
                #expect(!text.contains(".cornerRadius("), "\(file.lastPathComponent)")
            }
        }
        #expect(seen > 100, "도형을 하나도 못 찾으면 이 검사는 뜻이 없다")
    }
}
