import Foundation
import Testing
@testable import PresentationCore

/// 화면 상태에서 **방 id 가 살아남는지**, 그리고 방을 모르는 상태에서 **예시 방이 그려질 길이 없는지**를 못 박는다.
///
/// 2026-10-15 결함(원본): `MainNavGraph` 의 `createdPartyId`·`activePartyId` 가 회전에 사라지는 `remember` 였다.
/// 두 값은 사라지는데 백스택은 **복원되므로** 21·25 목적지로 돌아왔고, 그 라우트가 방 id 없이 화면을 불러 **예시 방**
/// (센텀시티역→서면역 · 3,600원)을 그렸다 — 진짜 방에 들어 있던 사용자에게 남의 가짜 방이 뜬 것이다.
///
/// **이 테스트가 덮지 못하는 것**: 여기서 보는 것은 **코드가 내린 결정**이다 — 어떤 상태가 뷰 수명을 넘어 살도록
/// 선언돼 있고, nil 분기가 무엇을 그리는가. iOS 는 세로 고정이고 `rememberSaveable` 의 자리가 `@State` 라
/// (`docs/PORTING.md` §4) `@State` 또는 `@SceneStorage` 면 통과다.
///
/// 소스를 문자열로 읽는 테스트라 서식을 크게 바꾸면 깨질 수 있다. 깨지면 **먼저 결정이 그대로인지
/// 확인하고** 정규식을 고쳐라 — 결정을 되돌리면서 테스트를 지우는 것이 이 테스트가 막는 일이다.
///
/// 대상 파일(`MainNavGraph.swift`, 21·25 의 Route)이 아직 없으면 그 테스트는 건너뛴다.
/// 포팅되는 즉시 이 테스트가 그 파일을 검사하기 시작한다.
@Suite struct ConfigChangeStateTest {
    private static let navGraphPath = "AppNavigation/MainNavGraph.swift"
    private static let waitingRoutes = [
        ("FeatureMatching/MatchWaitingRoute.swift", "MatchWaitingScreen("),
        ("FeatureMatching/DispatchStatusRoute.swift", "DispatchStatusScreen("),
    ]

    private func assertSavedState(_ names: [String], message: (String) -> String) throws {
        let navGraph = try #require(SourceTree.read(Self.navGraphPath))
        for name in names {
            let pattern = #"@(?:State|SceneStorage(?:\([^)]*\))?)\s+(?:(?:private|fileprivate|internal)\s+)?var\s+"#
                + name + #"\b"#
            #expect(!SourceTree.matches(pattern, in: navGraph).isEmpty, Comment(rawValue: message(name)))
        }
    }

    // ───────────────────────── 1. 방 id 는 살아남는다 ─────────────────────────

    /// 21·22·25·26·27 이 「어느 방인가」를 묻는 값.
    @Test(
        "화면 사이로 넘기는 방 id 는 구성 변경에서 살아남는다",
        .enabled(if: SourceTree.exists(navGraphPath), "MainNavGraph.swift 가 아직 포팅되지 않았다")
    )
    func partyIdsSurvive() throws {
        try assertSavedState(["createdPartyId", "activePartyId", "selectedPartyId"]) {
            "\($0) 이 @State 가 아니다 — 방 id 가 날아가면 21·25 가 어느 방인지 모르게 된다"
        }
    }

    /// 16 방 생성 모달이 쓰는 좌표. 사라지면 16 이 「출발지가 없어요」로 떨어져, 사용자가 방금
    /// 끝낸 15 를 다시 하게 된다.
    @Test(
        "15 에서 확정한 출발지와 도착지도 구성 변경에서 살아남는다",
        .enabled(if: SourceTree.exists(navGraphPath), "MainNavGraph.swift 가 아직 포팅되지 않았다")
    )
    func confirmedPlacesSurvive() throws {
        try assertSavedState(["confirmedOrigin", "confirmedDestination"]) {
            "\($0) 이 @State 가 아니다 — 16 이 고른 경로를 잃는다"
        }
    }

    /// `finishedRide`(`Ride`)·`selectedPartner`(`User`)는 **일부러** 저장 상태(`@SceneStorage`)에 넣지 않는다.
    /// 값이 크고, 두 값이 없을 때 33·23 은 거짓을 말하지 않는다(요약 줄을 숨기거나 안내로 되돌린다).
    ///
    /// 이 테스트는 그 결정을 **기록**한다. 바꿀 이유가 생기면 이 테스트를 고쳐라.
    @Test(
        "큰 도메인 객체는 저장 상태에 담지 않는다",
        .enabled(if: SourceTree.exists(navGraphPath), "MainNavGraph.swift 가 아직 포팅되지 않았다")
    )
    func largeObjectsStayInMemory() throws {
        let navGraph = try #require(SourceTree.read(Self.navGraphPath))
        for name in ["finishedRide", "selectedPartner"] {
            let pattern = #"@State\s+(?:(?:private|fileprivate|internal)\s+)?var\s+"# + name + #"\b"#
            #expect(
                !SourceTree.matches(pattern, in: navGraph).isEmpty,
                "\(name) 이 저장 상태로 바뀌었다 — Ride·User 는 저장 상태에 담을 크기가 아니다(근거는 선언부 주석)"
            )
        }
    }

    // ──────────────── 2. 방을 모를 때 예시 방을 그리지 않는다 ────────────────

    /// 21·25 의 `partyId == nil` 분기. 20·22·23 과 같은 방식 — 사실대로 말하고 되돌린다.
    ///
    /// 분기 **안**을 본다: 화면 호출(`MatchWaitingScreen(`·`DispatchStatusScreen(`)이 아니라
    /// `ErrorBox` 가 있어야 한다. 「잠시 후 다시 시도」류 문구도 함께 막는다 — 되돌아가는 것
    /// 말고는 사용자가 할 수 있는 게 없는 자리다.
    @Test(
        "방 id 가 없으면 21 과 25 는 예시 방 대신 사실을 말한다",
        .enabled(
            if: waitingRoutes.contains { SourceTree.exists($0.0) },
            "21·25 Route 가 아직 포팅되지 않았다"
        )
    )
    func missingPartyIdTellsTheTruth() throws {
        for (path, screenCall) in Self.waitingRoutes where SourceTree.exists(path) {
            let source = try #require(SourceTree.read(path))
            let body = try #require(missingPartyBranch(in: source), "\(path): 방 id 없음 분기를 찾지 못했다")
            #expect(body.contains("ErrorBox("), "\(path): 방 id 없음 분기가 ErrorBox 를 그리지 않는다")
            #expect(!body.contains(screenCall), "\(path): 방 id 없음 분기가 화면을 직접 그린다 — 예시 방이 다시 샐 수 있다")
            #expect(!body.contains("잠시 후"), "\(path): 할 수 없는 일을 안내한다 — 이 자리에서 다시 불러올 방법은 없다")
        }
    }

    /// 프로덕션 화면의 **기본 인자로 도메인 데이터를 지어내지 않는다.**
    ///
    /// 이 결함의 마지막 고리였다 — `ride: Ride = waitingRideDummy` 가 있는 한, 방을 모르는 호출부는
    /// 컴파일을 통과하면서 가짜 방을 그린다. 기본값을 걷어낸 지금은 같은 사고가 나려면 컴파일이
    /// 먼저 깨진다.
    ///
    /// 범위를 21·25 로 좁히지 않고 UI 패키지 전체를 본다 — 같은 트랩이 25b·25c·17 에도 있었고
    /// (2026-10-15 함께 제거), 새 화면에 다시 생기는 것을 여기서 막는다.
    @Test("화면 기본 인자로 도메인 데이터를 지어내지 않는다")
    func noFabricatedDefaultArguments() throws {
        // "들여쓴 파라미터: 도메인타입 = nil·빈값이 아닌 무엇" 을 찾는다.
        let pattern = #"^\s+\w+: \[?(?:Ride|User|ChatRoom|ChatMessage|Place|FavoritePlace|AssignedDriver)\]?\??\s*=\s*(?!nil|\[\]|\[:\])\S"#
        let files = SourceTree.swiftFiles()
        // 소스를 하나도 못 읽고 통과하는 일을 막는다.
        #expect(files.contains { $0.lastPathComponent == "ActiveParty.swift" })
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in SourceTree.matches(pattern, in: text, options: [.anchorsMatchLines]) {
                offenders.append("\(file.lastPathComponent): \(match.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        #expect(offenders.isEmpty, "화면 기본 인자가 도메인 데이터를 지어낸다 — 호출부가 값을 빼먹으면 가짜가 그려진다: \(offenders)")
    }

    // ─── 검사 도구 자체의 검증 ───
    //
    // 위 테스트 일부는 대상 파일이 생기기 전까지 건너뛴다. 그동안에도 정규식과 분기 찾기가 맞는지는 여기서 본다.

    @Test("분기 찾기는 세 가지 모양을 모두 찾고 없으면 nil 이다")
    func branchFinderShapes() {
        let ifNil = "if partyId == nil {\n ErrorBox(a) { x }\n return\n}\nMatchWaitingScreen(ride)"
        #expect(missingPartyBranch(in: ifNil)?.contains("ErrorBox(") == true)
        #expect(missingPartyBranch(in: ifNil)?.contains("MatchWaitingScreen(") == false)

        let guardLet = "guard let partyId else {\n ErrorBox(a)\n return\n}\nMatchWaitingScreen(ride)"
        #expect(missingPartyBranch(in: guardLet)?.contains("ErrorBox(") == true)
        #expect(missingPartyBranch(in: guardLet)?.contains("MatchWaitingScreen(") == false)

        let ifLet = "if let id = partyId {\n MatchWaitingScreen(id) { y }\n} else {\n ErrorBox(a)\n}\nfoo()"
        #expect(missingPartyBranch(in: ifLet)?.contains("ErrorBox(") == true)
        #expect(missingPartyBranch(in: ifLet)?.contains("MatchWaitingScreen(") == false)
        #expect(missingPartyBranch(in: ifLet)?.contains("foo()") == false)

        #expect(missingPartyBranch(in: "MatchWaitingScreen(ride)") == nil)
    }

    @Test("상태 선언 정규식과 상수 읽기가 실제 코드 모양을 잡는다")
    func toolPatterns() {
        let state = #"@(?:State|SceneStorage(?:\([^)]*\))?)\s+(?:(?:private|fileprivate|internal)\s+)?var\s+createdPartyId\b"#
        #expect(!SourceTree.matches(state, in: "@State private var createdPartyId: Int64?").isEmpty)
        #expect(!SourceTree.matches(state, in: "@SceneStorage(\"a\") var createdPartyId = 0").isEmpty)
        #expect(SourceTree.matches(state, in: "private var createdPartyId: Int64?").isEmpty)
        #expect(SourceTree.int64Constant("PARTY_DETAIL_POLL_FLOOR_MS", under: "PresentationCore") == 6_000)
        #expect(SourceTree.int64Constant("NO_SUCH_CONSTANT", under: "PresentationCore") == nil)

        let fabricated = #"^\s+\w+: \[?(?:Ride|User)\]?\??\s*=\s*(?!nil|\[\]|\[:\])\S"#
        #expect(!SourceTree.matches(fabricated, in: "    ride: Ride = waitingRideDummy,", options: [.anchorsMatchLines]).isEmpty)
        #expect(SourceTree.matches(fabricated, in: "    ride: Ride? = nil,", options: [.anchorsMatchLines]).isEmpty)
        #expect(SourceTree.matches(fabricated, in: "    members: [User] = [],", options: [.anchorsMatchLines]).isEmpty)
    }

    // ─── 분기 찾기 ───

    /// 방 id 가 없을 때 실행되는 블록의 본문. SwiftUI 코드는 `if partyId == nil { }`, `guard let … else { }`,
    /// `if let … { } else { }` 어느 모양으로도 쓸 수 있어 셋 다 찾는다.
    private func missingPartyBranch(in source: String) -> String? {
        for pattern in [
            #"if\s+partyId\s*==\s*nil\s*\{"#,
            #"guard\s+let\s+(?:partyId|\w+\s*=\s*partyId)\b[^{]*?else\s*\{"#,
        ] {
            if let open = firstMatchEnd(pattern, in: source) {
                return block(in: source, openingBraceEnd: open)
            }
        }
        if let open = firstMatchEnd(#"if\s+let\s+(?:partyId|\w+\s*=\s*partyId)\b[^{]*\{"#, in: source),
           let success = block(in: source, openingBraceEnd: open) {
            let after = source[source.index(open, offsetBy: success.count + 1)...]
            let trimmed = after.drop { $0.isWhitespace }
            if trimmed.hasPrefix("else"), let brace = trimmed.firstIndex(of: "{") {
                return block(in: source, openingBraceEnd: source.index(after: brace))
            }
        }
        return nil
    }

    private func firstMatchEnd(_ pattern: String, in source: String) -> String.Index? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = regex.firstMatch(in: source, range: range) else { return nil }
        return Range(match.range, in: source)?.upperBound
    }

    /// 여는 중괄호 바로 뒤부터 짝이 맞는 닫는 중괄호 앞까지.
    private func block(in source: String, openingBraceEnd start: String.Index) -> String? {
        var depth = 1
        var index = start
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[start..<index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
