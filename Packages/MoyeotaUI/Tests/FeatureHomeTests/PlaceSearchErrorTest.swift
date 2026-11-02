import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureHome

/// 목적지 검색의 **실패 문구가 결과를 가리지 않는지**를 못 박는다.
///
/// 2026-10-15 결함(QA 실기 발견): 빠르게 타이핑하면 서버가 200 과 정상 목록을 줘도 화면에
/// 「장소를 검색하지 못했어요」만 보이고 결과가 한 건도 안 떴다. 사슬은 셋이었다.
///
/// 1. 글자를 칠 때마다 `searchJob?.cancel()` 이 직전 요청을 끊는다 — 정상 동작이다.
/// 2. 그 취소가 올라오는데 `catch` 하나가 **그것까지** 받아 실패 문구를 세웠다. 취소는 실패가 아니다.
/// 3. 뒤이어 **성공한** 검색이 문구를 지우지 않았고, 화면은 에러를 분기의 첫 가지로 두므로
///    (`DestinationScreen`) 결과가 그 문구에 가려졌다.
///
/// 셋 중 하나만 되돌려도 증상이 되살아나므로 셋 다 본다.
///
/// 원본은 코루틴을 돌릴 수단이 없어 소스 문자열만 봤다. 여기서는 소스가 내린 결정(원본 세 테스트)에 더해,
/// 디바운스를 주입해 실제 타이핑·취소 순서를 돌려 본다.
///
/// 소스를 문자열로 읽으므로 서식을 크게 바꾸면 깨질 수 있다. 깨지면 **먼저 결정이 그대로인지
/// 확인하고** 패턴을 고쳐라 — 결정을 되돌리면서 테스트를 지우는 것이 이 테스트가 막는 일이다.
@MainActor
@Suite struct PlaceSearchErrorTest {

    private static let featureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // FeatureHomeTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MoyeotaUI
        .appendingPathComponent("Sources/FeatureHome")

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.featureRoot.appendingPathComponent(name), encoding: .utf8)
    }

    /// `runSearch` 본문만 떼어 본다 — 같은 파일의 즐겨찾기 조회 등 다른 `catch` 에 걸리지 않게.
    private func runSearchBody() throws -> Substring {
        let route = try source("DestinationRoute.swift")
        let start = try #require(
            route.range(of: "private func runSearch("),
            "runSearch 를 찾지 못했다 — 이름이 바뀌었으면 이 테스트도 같이 고쳐라"
        )
        let next = route.range(of: "\n    public func ", range: start.upperBound..<route.endIndex)
        return route[start.lowerBound..<(next?.lowerBound ?? route.endIndex)]
    }

    @Test("검색 취소는 실패로 취급하지 않는다")
    func cancellationIsNotFailure() throws {
        let body = try runSearchBody()
        let message = try #require(body.range(of: "장소를 검색하지 못했어요"), "실패 문구를 찾지 못했다")

        // 코루틴의 `catch (e: CancellationException) { throw e }` 자리. Swift 에서는 catch 하나 안에서 가른다.
        // 판정은 **태스크 취소만** 본다. 살아 있는 태스크의 `URLError(.cancelled)` 는 원본 OkHttp `IOException` 이라
        // 실패 문구로 간다(`liveTaskUrlCancelIsFailure`).
        let taskCancelled = body.range(of: "if Task.isCancelled { return }")
        #expect(
            taskCancelled.map { $0.lowerBound < message.lowerBound } == true,
            "runSearch 가 끊긴 태스크를 먼저 거르지 않는다 — 타이핑하는 족족 실패 문구가 선다(글자마다 searchJob.cancel 이 돈다)"
        )
    }

    @Test("검색에 성공하면 이전 실패 문구를 지운다")
    func successClearsPreviousFailure() throws {
        let body = try runSearchBody()
        #expect(body.range(of: "searchResults = results") != nil, "성공 분기(searchResults = results)를 찾지 못했다")
        let cleared = body.range(
            of: #"searchResults\s*=\s*results\s+(self\??\.)?uiState\.searchErrorMessage\s*=\s*nil"#,
            options: .regularExpression
        )
        #expect(
            cleared != nil,
            "성공했는데 searchErrorMessage 를 nil 로 지우지 않는다 — 화면이 에러를 먼저 그리므로 결과가 와도 그 문구에 가려 한 건도 안 보인다"
        )
    }

    @Test("화면은 실패 문구를 결과보다 먼저 그린다 - 그래서 문구를 지우는 것이 중요하다")
    func screenDrawsErrorBeforeResults() throws {
        let screen = try source("DestinationScreen.swift")
        let whenStart = try #require(screen.range(of: "if let searchErrorMessage {"), "검색 결과 영역의 분기를 찾지 못했다")
        let resultsStart = try #require(screen.range(of: "searchResults.isEmpty"), "검색 결과 영역의 분기를 찾지 못했다")
        #expect(
            whenStart.lowerBound < resultsStart.lowerBound,
            "에러 분기가 결과 분기보다 뒤에 있다 — 이 테스트의 전제(에러가 결과를 가린다)가 바뀌었으니 runSearch 가 문구를 지워야 하는 이유도 다시 따져라"
        )
    }

    // ─── 원본에 없는 동작 확인: 실제 타이핑·취소 순서를 돌린다 ─────────────────────

    /// 앞 글자의 요청이 끊긴 뒤 어떤 모양으로 끝나도 문구를 세우지 않고, 뒤 검색의 결과가 보인다.
    @Test(
        "끊긴 검색이 무엇으로 끝나든 문구를 세우지 않고 새 검색의 결과가 보인다",
        arguments: [
            ScriptedOutcome.failure(CancellationError()),
            .failure(URLError(.cancelled)),
            .failure(URLError(.timedOut)),
            .results([spot("앞 글자의 늦은 응답")]),
        ]
    )
    func cancelledSearchNeverWritesState(lateOutcome: ScriptedOutcome) async {
        let repository = ScriptedSearchRepository(script: ["서": lateOutcome, "서면": .results([spot("서면역")])])
        await repository.hold("서")
        let viewModel = DestinationViewModel(repository: repository, sleep: { _ in })

        let first = viewModel.onQueryChange("서")
        await repository.waitUntilStarted("서")
        let second = viewModel.onQueryChange("서면")
        await second?.value
        await repository.release("서")
        await first?.value

        #expect(viewModel.uiState.searchErrorMessage == nil)
        #expect(viewModel.uiState.searchResults == [spot("서면역")])
        #expect(!viewModel.uiState.searchLoading)
    }

    /// 태스크가 살아 있는데 `URLError(.cancelled)` 가 오면 덮어 줄 새 요청이 없다. 원본은 OkHttp `IOException("Canceled")` 을
    /// `catch (e: Exception)` 로 받아 문구를 세운다 — 문구 없이 비면 「검색 결과 없음」으로 읽힌다.
    @Test("살아 있는 태스크의 URLError 취소는 실패 문구를 세우고 로딩을 내린다")
    func liveTaskUrlCancelIsFailure() async {
        let repository = ScriptedSearchRepository(script: ["서면": .failure(URLError(.cancelled))])
        let viewModel = DestinationViewModel(repository: repository, sleep: { _ in })

        await viewModel.onQueryChange("서면")?.value

        #expect(viewModel.uiState.searchErrorMessage == "장소를 검색하지 못했어요")
        #expect(!viewModel.uiState.searchLoading)
    }

    @Test("진짜 실패는 문구를 세우고 다음 성공이 지운다")
    func realFailureThenSuccess() async {
        let repository = ScriptedSearchRepository(script: [
            "서": .failure(URLError(.timedOut)),
            "서면": .results([spot("서면역")]),
        ])
        let viewModel = DestinationViewModel(repository: repository, sleep: { _ in })

        await viewModel.onQueryChange("서")?.value
        #expect(viewModel.uiState.searchErrorMessage == "장소를 검색하지 못했어요")
        #expect(viewModel.uiState.searchResults == [])

        await viewModel.onQueryChange("서면")?.value
        #expect(viewModel.uiState.searchErrorMessage == nil)
        #expect(viewModel.uiState.searchResults == [spot("서면역")])
    }
}

private func spot(_ name: String) -> Place {
    Place(name: name, roadName: "도로명", latitude: 35.0, longitude: 129.0)
}

enum ScriptedOutcome: Sendable, CustomTestStringConvertible {
    case results([Place])
    case failure(any Error)

    var testDescription: String {
        switch self {
        case .results: "늦은 성공"
        case let .failure(error): "실패: \(error)"
        }
    }
}

/// 검색어별 결과를 정해 두고, `hold` 한 검색어는 `release` 까지 응답을 붙잡는다.
/// 붙잡힌 호출은 취소를 무시한다 — 끊긴 뒤에 서버 응답이 도착한 경우를 흉내 낸다.
actor ScriptedSearchRepository: PlaceRepository {
    private let script: [String: ScriptedOutcome]
    private var held: Set<String> = []
    private var started: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var searches: [String] = []
    var favorites: [FavoritePlace] = []
    var addError: (any Error)?
    private(set) var added: [Place] = []

    init(script: [String: ScriptedOutcome] = [:]) {
        self.script = script
    }

    func hold(_ query: String) {
        held.insert(query)
    }

    func release(_ query: String) {
        held.remove(query)
        gates.removeValue(forKey: query)?.resume()
    }

    func setFavorites(_ value: [FavoritePlace]) {
        favorites = value
    }

    func setAddError(_ error: (any Error)?) {
        addError = error
    }

    func waitUntilStarted(_ query: String) async {
        for _ in 0..<2_000 where !started.contains(query) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func searchPlaces(query: String) async throws -> [Place] {
        searches.append(query)
        started.insert(query)
        if held.contains(query) {
            await withCheckedContinuation { gates[query] = $0 }
        }
        switch script[query] {
        case let .results(places): return places
        case let .failure(error): throw error
        case nil: return []
        }
    }

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> ReverseAddress? { nil }

    func addFavoritePlace(place: Place) async throws {
        added.append(place)
        if let addError { throw addError }
    }

    func getFavoritePlaces() async throws -> [FavoritePlace] { favorites }

    func deleteFavoritePlace(id: Int64) async throws {}

    func deleteFavoritePlaces(ids: [Int64]) async throws {}

    func deleteAllFavoritePlaces() async throws {}
}
