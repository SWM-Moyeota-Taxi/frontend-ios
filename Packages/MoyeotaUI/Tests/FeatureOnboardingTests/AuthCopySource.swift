import Foundation

/// `FeatureAuth` 의 가입 전 문구(`LoginTrustBullets`·`mannerPledgeItems`)를 **소스 파일에서** 읽는다.
///
/// 원본 `ProductClaimsTest` 는 같은 모듈이라 `feature.auth` 의 상수를 그대로 참조한다. iOS 는 기능 모듈끼리
/// import 할 수 없어(`docs/PORTING.md` §2) 값으로 가져올 수 없고, 테스트 안에 문구를 복사해 두면 실제 화면과
/// 어긋나도 알아채지 못한다. 그래서 화면이 그리는 상수 선언 자체를 읽는다.
///
/// 읽기 실패의 방향은 **항상 테스트 실패**다. 상수 이름을 바꾸거나 선언 꼴을 바꾸면 조용히 검사가 사라지지
/// 않고 `.unreadable` 로 빨갛게 떨어진다. 주석은 읽지 않는다 — 지운 문구를 이유와 함께 적어 둔 주석이
/// 금지어에 걸리면 안 된다(원본 테스트도 상수만 본다).
///
/// `.notPorted` 는 하나뿐이다: 상수가 살 파일(원본과 같은 이름, `docs/PORTING.md` §2)이 없고, 상수·타입 이름을
/// 코드에서 쓰는 파일도 없을 때. `FeatureAuth` 는 파일 단위로 포팅되므로 그런 파일이 생기는 순간 실제 상수를 본다.
enum AuthCopySource {
    struct Pledge: Equatable, Sendable {
        var title: String
        var description: String?

        /// 원본 `listOfNotNull(it.title, it.description)`.
        var copyParts: [String] { [title, description].compactMap { $0 } }
    }

    enum Lookup<Value: Equatable & Sendable>: Equatable, Sendable {
        /// 상수가 살 파일이 아직 없다 — 읽을 문구가 없다.
        case notPorted
        case found(Value)
        /// 파일은 있는데 상수를 찾거나 읽지 못했다.
        case unreadable(String)
    }

    /// `Packages/MoyeotaUI/Sources`. 시뮬레이터 프로세스도 맥의 파일 시스템을 그대로 읽는다.
    static func sourcesRoot(testFile: String = #filePath) -> URL {
        URL(fileURLWithPath: testFile)
            .deletingLastPathComponent() // FeatureOnboardingTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MoyeotaUI
            .appendingPathComponent("Sources")
    }

    static let bullets: Lookup<[String]> = loadBullets(sourcesRoot: sourcesRoot())
    static let pledges: Lookup<[Pledge]> = loadPledges(sourcesRoot: sourcesRoot())

    static func loadBullets(sourcesRoot: URL) -> Lookup<[String]> {
        load(name: "LoginTrustBullets", markers: [], homeFile: "LoginScreen.swift", sourcesRoot: sourcesRoot, parse: parseBullets)
    }

    static func loadPledges(sourcesRoot: URL) -> Lookup<[Pledge]> {
        load(name: "mannerPledgeItems", markers: ["PledgeItem"], homeFile: "MannerPledgeScreen.swift", sourcesRoot: sourcesRoot, parse: parsePledges)
    }

    /// 상수는 `FeatureAuth` 에 있어야 하지만, 원본의 다른 기능 간 참조처럼 `PresentationCore` 로 옮겨질 수도 있다.
    /// 둘 다 있으면 `FeatureAuth` 쪽이 이긴다 — 같은 모듈 선언이 import 를 가려 화면이 그쪽을 그린다.
    private static func load<Value>(
        name: String,
        markers: [String],
        homeFile: String,
        sourcesRoot: URL,
        parse: ([SwiftToken]) throws -> Value
    ) -> Lookup<Value> {
        let authDirectory = sourcesRoot.appendingPathComponent("FeatureAuth")
        // 폴더째 없으면 포팅 전이 아니라 소스를 못 찾은 것이다 — 건너뛰면 검사가 조용히 꺼진다.
        guard FileManager.default.fileExists(atPath: authDirectory.path) else {
            return .unreadable("소스 폴더가 없다: \(authDirectory.path)")
        }
        let directories = [authDirectory, sourcesRoot.appendingPathComponent("PresentationCore")]
        guard let tokens = arrayTokens(named: name, in: directories) else {
            let home = authDirectory.appendingPathComponent(homeFile)
            if FileManager.default.fileExists(atPath: home.path) {
                return .unreadable("`\(homeFile)` 가 있는데 `\(name)` 배열 선언을 찾지 못했다")
            }
            // 다른 파일에 읽지 못할 꼴로 선언했거나 이름을 바꿨으면 포팅 전이 아니다 — 건너뛰면 검사가 조용히 꺼진다.
            if let file = fileUsing(words: [name] + markers, in: directories) {
                return .unreadable("`\(file)` 가 `\(name)` 관련 이름을 쓰는데 `\(name)` 배열 선언을 찾지 못했다")
            }
            return .notPorted
        }
        do {
            return .found(try parse(tokens))
        } catch {
            return .unreadable("\(error)")
        }
    }

    // ─────────────────────────── 선언 찾기 ───────────────────────────

    /// 주석을 뺀 코드에서 `words` 중 하나를 쓰는 첫 파일의 이름.
    private static func fileUsing(words: [String], in directories: [URL]) -> String? {
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "swift" {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let tokens = tokenizeSwift(source)
                if words.contains(where: { tokens.contains(.word($0)) }) { return file.lastPathComponent }
            }
        }
        return nil
    }

    private static func arrayTokens(named name: String, in directories: [URL]) -> [SwiftToken]? {
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "swift" {
                guard let source = try? String(contentsOf: file, encoding: .utf8), source.contains(name) else { continue }
                if let tokens = arrayTokens(named: name, source: source) { return tokens }
            }
        }
        return nil
    }

    /// `let 이름 [: 타입] = [ … ]` 의 대괄호 안쪽 토큰. 그런 선언이 없으면 nil.
    static func arrayTokens(named name: String, source: String) -> [SwiftToken]? {
        let tokens = tokenizeSwift(source)
        for index in tokens.indices where index + 1 < tokens.endIndex {
            guard tokens[index] == .word("let") || tokens[index] == .word("var"),
                  tokens[index + 1] == .word(name) else { continue }
            guard let equals = tokens[(index + 2)...].firstIndex(of: .symbol("=")),
                  // `{` 가 먼저 오면 계산 프로퍼티다 — 그 뒤의 `=` 는 다른 선언의 것이다.
                  !tokens[(index + 2)..<equals].contains(.symbol("{")),
                  equals + 1 < tokens.endIndex,
                  tokens[equals + 1] == .symbol("[") else { return nil }

            var depth = 1
            var cursor = equals + 2
            while cursor < tokens.endIndex {
                switch tokens[cursor] {
                case .symbol("["), .symbol("("): depth += 1
                case .symbol("]"), .symbol(")"): depth -= 1
                default: break
                }
                if depth == 0 { return Array(tokens[(equals + 2)..<cursor]) }
                cursor += 1
            }
            return nil
        }
        return nil
    }

    // ─────────────────────────── 값 읽기 ───────────────────────────

    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    /// `"…", "…"` 꼴만 받는다. 다른 것이 섞이면 문구를 다 읽었다고 말할 수 없으므로 실패다.
    static func parseBullets(_ tokens: [SwiftToken]) throws -> [String] {
        var bullets: [String] = []
        for token in tokens {
            switch token {
            case .string(let value): bullets.append(value)
            case .symbol(","): continue
            default: throw ParseError(description: "`LoginTrustBullets` 안에 문자열이 아닌 것이 있다: \(token)")
            }
        }
        return bullets
    }

    /// `PledgeItem("제목", "설명")` 꼴을 받는다. 라벨(`title:`)·`nil`·설명 생략도 읽는다.
    static func parsePledges(_ tokens: [SwiftToken]) throws -> [Pledge] {
        var pledges: [Pledge] = []
        var cursor = tokens.startIndex
        while cursor < tokens.endIndex {
            guard tokens[cursor] == .symbol("(") else {
                if case .string(let value) = tokens[cursor] {
                    throw ParseError(description: "`mannerPledgeItems` 의 괄호 밖에 문자열이 있다: \(value)")
                }
                if tokens[cursor] == .opaqueString {
                    throw ParseError(description: "`mannerPledgeItems` 의 괄호 밖에 읽을 수 없는 문자열이 있다")
                }
                cursor += 1
                continue
            }
            var depth = 1
            var values: [String?] = []
            cursor += 1
            while cursor < tokens.endIndex, depth > 0 {
                switch tokens[cursor] {
                case .symbol("("): depth += 1
                case .symbol(")"): depth -= 1
                case .string(let value): values.append(value)
                case .word("nil"): values.append(nil)
                case .opaqueString:
                    throw ParseError(description: "`mannerPledgeItems` 에 값을 읽을 수 없는 문자열(보간·여러 줄)이 있다")
                default: break
                }
                cursor += 1
            }
            guard (1...2).contains(values.count), let title = values[0] else {
                throw ParseError(description: "`mannerPledgeItems` 항목은 제목과 선택적 설명이어야 한다: \(values)")
            }
            pledges.append(Pledge(title: title, description: values.count == 2 ? values[1] : nil))
        }
        return pledges
    }
}

/// 원본 `LoginScreen.kt`·`MannerPledgeScreen.kt` 의 상수를 글자 그대로 옮긴 기준 문구.
/// 포팅된 상수가 이것과 같은지 보고, 미포팅이면 `ProductClaimsTest` 가 이것으로 검사를 돌린다.
enum OriginalAuthCopy {
    static let bullets = [
        "휴대폰 인증을 마친 사람만 가입해요",
        "함께 탈 사람의 탑승 횟수가 보여요",
    ]

    static let pledges: [AuthCopySource.Pledge] = [
        .init(title: "이용약관 · 개인정보 수집에 동의해요", description: "실명·생년월일·연락처는 본인 확인에만 써요"),
        .init(title: "약속한 시간과 장소를 지킬게요", description: "무단 취소가 반복되면 이용이 제한돼요"),
        .init(title: "불쾌한 말과 행동을 하지 않을게요", description: "채팅방에서 메시지를 길게 눌러 신고할 수 있어요"),
        .init(title: "매칭이 확정되면 꼭 나갈게요", description: "매칭 확정 후 오지 않으면 이용이 제한될 수 있어요"),
    ]
}

enum SwiftToken: Equatable, Sendable {
    case string(String)
    /// 값을 정적으로 알 수 없는 문자열(보간·여러 줄·원시 문자열).
    case opaqueString
    case word(String)
    case symbol(Character)
}

/// 상수 선언을 읽는 데 필요한 만큼만 자르는 어휘 분석기. 주석은 버린다.
func tokenizeSwift(_ source: String) -> [SwiftToken] {
    let chars = Array(source)
    var tokens: [SwiftToken] = []
    var i = 0

    func hasPrefix(_ prefix: String, at index: Int) -> Bool {
        let wanted = Array(prefix)
        guard index + wanted.count <= chars.count else { return false }
        return Array(chars[index..<(index + wanted.count)]) == wanted
    }

    while i < chars.count {
        let c = chars[i]
        if hasPrefix("//", at: i) {
            while i < chars.count, !chars[i].isNewline { i += 1 }
        } else if hasPrefix("/*", at: i) {
            var depth = 1
            i += 2
            while i < chars.count, depth > 0 {
                if hasPrefix("/*", at: i) {
                    depth += 1
                    i += 2
                } else if hasPrefix("*/", at: i) {
                    depth -= 1
                    i += 2
                } else {
                    i += 1
                }
            }
        } else if c == "#", i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "#" {
            // 원시 문자열 — #…" 부터 "…# 까지
            var hashes = 0
            while i < chars.count, chars[i] == "#" {
                hashes += 1
                i += 1
            }
            let closing = "\"" + String(repeating: "#", count: hashes)
            i += hasPrefix("\"\"\"", at: i) ? 3 : 1
            while i < chars.count, !hasPrefix(closing, at: i) { i += 1 }
            i += closing.count
            tokens.append(.opaqueString)
        } else if hasPrefix("\"\"\"", at: i) {
            i += 3
            while i < chars.count, !hasPrefix("\"\"\"", at: i) {
                i += chars[i] == "\\" ? 2 : 1
            }
            i += 3
            tokens.append(.opaqueString)
        } else if c == "\"" {
            let (token, next) = readStringLiteral(chars, from: i)
            tokens.append(token)
            i = next
        } else if c.isLetter || c == "_" || c.isNumber {
            let start = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
            tokens.append(.word(String(chars[start..<i])))
        } else if c.isWhitespace {
            i += 1
        } else {
            tokens.append(.symbol(c))
            i += 1
        }
    }
    return tokens
}

/// 한 줄 문자열 리터럴. 보간이 있으면 값을 알 수 없으므로 `.opaqueString` 이다.
private func readStringLiteral(_ chars: [Character], from start: Int) -> (SwiftToken, Int) {
    var value = ""
    var opaque = false
    var i = start + 1
    while i < chars.count {
        let c = chars[i]
        if c == "\"" {
            return (opaque ? .opaqueString : .string(value), i + 1)
        }
        guard c == "\\", i + 1 < chars.count else {
            value.append(c)
            i += 1
            continue
        }
        let escape = chars[i + 1]
        i += 2
        switch escape {
        case "n": value.append("\n")
        case "t": value.append("\t")
        case "r": value.append("\r")
        case "0": value.append("\0")
        case "\"", "\\", "'": value.append(escape)
        case "u":
            // \u{…}
            var hex = ""
            i += 1
            while i < chars.count, chars[i] != "}" {
                hex.append(chars[i])
                i += 1
            }
            i += 1
            if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) {
                value.unicodeScalars.append(scalar)
            } else {
                opaque = true
            }
        case "(":
            // 보간 — 안쪽에 문자열·괄호가 있을 수 있어 짝을 맞춰 건너뛴다.
            opaque = true
            var depth = 1
            while i < chars.count, depth > 0 {
                if chars[i] == "\"" {
                    i = readStringLiteral(chars, from: i).1
                    continue
                }
                if chars[i] == "(" { depth += 1 }
                if chars[i] == ")" { depth -= 1 }
                i += 1
            }
        default:
            opaque = true
        }
    }
    return (.opaqueString, i)
}
