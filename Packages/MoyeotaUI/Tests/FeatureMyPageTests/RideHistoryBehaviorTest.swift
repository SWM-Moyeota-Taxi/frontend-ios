import Foundation
import MoyeotaDomain
import Testing
@testable import FeatureMyPage

// 원본 테스트에 없는 것들. 뷰모델의 페이징과, PORTING §6 의 서버 시각 해석을 고정한다.

private struct NetworkDown: Error {}

private final class FakeRideRecordRepository: RideRecordRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<RideRecordPage, any Error>]
    private var _cursors: [Int64?] = []

    init(_ results: [Result<RideRecordPage, any Error>]) {
        self.results = results
    }

    var cursors: [Int64?] { lock.withLock { _cursors } }

    func getMyRecords(cursor: Int64?, size: Int) async throws -> RideRecordPage {
        let result = lock.withLock {
            _cursors.append(cursor)
            return results.removeFirst()
        }
        return try result.get()
    }
}

private func ride(_ partyId: Int64) -> RideRecord {
    RideRecord(
        partyId: partyId,
        departure: "강남역",
        destination: "판교역",
        pickupTime: nil,
        dropoffTime: "2026-10-31T19:15:17Z",
        totalFare: nil,
        farePerPerson: nil,
        memberCount: 1,
        members: []
    )
}

private func page(_ ids: [Int64], next: Int64? = nil) -> Result<RideRecordPage, any Error> {
    .success(RideRecordPage(records: ids.map(ride), nextCursor: next, hasNext: next != nil))
}

@MainActor
@Suite struct RideHistoryBehaviorTest {

    private func settled(_ viewModel: RideHistoryViewModel) async {
        await viewModel.loadJob?.value
    }

    @Test("진입 즉시 커서 없이 첫 페이지를 받고 호출 자리에서 loading 을 켠다")
    func refreshOnInit() async {
        let repository = FakeRideRecordRepository([page([3, 2], next: 2)])
        let viewModel = RideHistoryViewModel(repository: repository)

        #expect(viewModel.uiState.loading)
        await settled(viewModel)

        #expect(repository.cursors == [nil])
        #expect(viewModel.uiState.records.map(\.partyId) == [3, 2])
        #expect(!viewModel.uiState.loading)
        #expect(viewModel.uiState.hasNext)
        #expect(viewModel.uiState.nextCursor == 2)
    }

    @Test("다음 페이지는 커서로 받아 뒤에 붙이고 같은 방은 한 번만 넣는다")
    func loadMoreAppendsWithoutDuplicates() async {
        let repository = FakeRideRecordRepository([page([3, 2], next: 2), page([2, 1])])
        let viewModel = RideHistoryViewModel(repository: repository)
        await settled(viewModel)

        viewModel.loadMore()
        #expect(viewModel.uiState.loadingMore)
        await settled(viewModel)

        #expect(repository.cursors == [nil, 2])
        #expect(viewModel.uiState.records.map(\.partyId) == [3, 2, 1])
        #expect(!viewModel.uiState.loadingMore)
        #expect(!viewModel.uiState.hasNext)
        #expect(viewModel.uiState.nextCursor == nil)
    }

    @Test("hasNext 가 false 면 loadMore 가 요청을 보내지 않는다")
    func loadMoreStopsAtEnd() async {
        let repository = FakeRideRecordRepository([page([1])])
        let viewModel = RideHistoryViewModel(repository: repository)
        await settled(viewModel)

        viewModel.loadMore()
        await settled(viewModel)

        #expect(repository.cursors == [nil])
    }

    @Test("진행 중이면 조회를 겹쳐 보내지 않는다")
    func noOverlappingLoads() async {
        let repository = FakeRideRecordRepository([page([2], next: 2), page([1])])
        let viewModel = RideHistoryViewModel(repository: repository)
        await settled(viewModel)

        viewModel.loadMore()
        viewModel.loadMore()
        viewModel.refresh()
        await settled(viewModel)

        #expect(repository.cursors == [nil, 2])
    }

    @Test("첫 페이지 실패는 failed 로 남고 다시 시도하면 내려간다")
    func refreshFailureThenRetry() async {
        let repository = FakeRideRecordRepository([.failure(NetworkDown()), page([1])])
        let viewModel = RideHistoryViewModel(repository: repository)
        await settled(viewModel)

        #expect(viewModel.uiState.failed)
        #expect(!viewModel.uiState.loading)

        viewModel.refresh()
        #expect(!viewModel.uiState.failed)
        await settled(viewModel)

        #expect(viewModel.uiState.records.map(\.partyId) == [1])
        #expect(!viewModel.uiState.failed)
    }

    @Test("다음 페이지가 실패해도 목록과 커서가 남고 다시 시도는 끊긴 커서부터 잇는다")
    func loadMoreFailureKeepsListAndCursor() async {
        let repository = FakeRideRecordRepository([page([2], next: 2), .failure(NetworkDown()), page([1])])
        let viewModel = RideHistoryViewModel(repository: repository)
        await settled(viewModel)

        viewModel.loadMore()
        await settled(viewModel)
        #expect(viewModel.uiState.failed)
        #expect(!viewModel.uiState.loadingMore)
        #expect(viewModel.uiState.records.map(\.partyId) == [2])
        #expect(viewModel.uiState.hasNext)

        // 「다시 시도」는 화면이 `failed` 가드 없이 onLoadMore 로 직접 부른다
        viewModel.loadMore()
        await settled(viewModel)

        #expect(repository.cursors == [nil, 2, 2])
        #expect(viewModel.uiState.records.map(\.partyId) == [2, 1])
        #expect(!viewModel.uiState.failed)
    }

    @Test("태스크가 살아 있는데 URLError(.cancelled) 로 끝나면 스피너를 남기지 않는다")
    func urlCancelledDoesNotStick() async {
        let repository = FakeRideRecordRepository([.failure(URLError(.cancelled)), page([1])])
        let viewModel = RideHistoryViewModel(repository: repository)
        await settled(viewModel)

        #expect(!viewModel.uiState.loading)
        #expect(viewModel.uiState.failed)

        viewModel.refresh()
        await settled(viewModel)
        #expect(viewModel.uiState.records.map(\.partyId) == [1])
    }
}

/// PORTING §6: 서버 `Instant` 는 소수 초 유무를 모두 받아야 한다. 기대값은 JDK 25 의
/// `Instant.parse` → `OffsetDateTime.parse` 순서로 돌린 실제 결과다.
@Suite struct RideHistoryInstantParseTest {

    @Test(
        "원본이 받는 꼴을 같은 시각으로 받는다",
        arguments: [
            ("2026-10-31T19:15:17.571486Z", Int64(1_793_474_117), 571_486_000),
            ("2026-10-31T19:15:17Z", 1_793_474_117, 0),
            ("2026-10-31T19:15:17.5Z", 1_793_474_117, 500_000_000),
            ("2026-10-31T19:15:17.123456789Z", 1_793_474_117, 123_456_789),
            ("2026-10-31T19:15:17.Z", 1_793_474_117, 0),
            ("2026-10-31T19:15Z", 1_793_474_100, 0),
            ("2026-11-01T04:15:17+09:00", 1_793_474_117, 0),
            ("2026-11-01T04:15:17.571486+09:00", 1_793_474_117, 571_486_000),
            ("2026-11-01T04:15:17+09", 1_793_474_117, 0),
            ("2026-11-01T04:15+09:00", 1_793_474_100, 0),
            ("2026-10-31T19:15:17+09:00:30", 1_793_441_687, 0),
            ("2026-10-31t19:15:17z", 1_793_474_117, 0),
            ("2026-10-31T24:00:00Z", 1_793_491_200, 0),
            ("2026-10-31T23:59:60Z", 1_793_491_199, 0),
            ("+12026-10-31T19:15:17Z", 317_362_994_117, 0),
        ] as [(String, Int64, Int)]
    )
    func accepted(input: String, epochSecond: Int64, nano: Int) {
        #expect(input.toInstantOrNull() == RideHistoryInstant(epochSecond: epochSecond, nano: nano))
    }

    @Test(
        "원본이 거절하는 꼴은 nil 이다",
        arguments: [
            "2026-10-31T19:15:17.1234567891Z",
            "2026-10-31T24:00Z",
            "2026-10-31T19:15:17",
            "2026-10-31 19:15:17Z",
            "2026-02-30T00:00:00Z",
            "어제",
            "",
            " 2026-10-31T19:15:17Z",
            "2026-10-31T19:15:17Z ",
            "2026-10-31T19:15:17+19:00",
            "2026-10-31T19:15:60Z",
            "2026-10-31T19:15:17+0900",
        ]
    )
    func rejected(input: String) {
        #expect(input.toInstantOrNull() == nil)
    }

    @Test("소수 초가 없는 서버 시각도 날짜 줄을 그린다")
    func labelWithoutFraction() {
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_793_491_200)

        #expect(rideHistoryDateLabel(isoTime: "2026-10-31T19:15:17Z", now: now, zone: zone) == "11월 1일 오전 4:15")
        #expect(rideHistoryDateLabel(isoTime: "2026-10-31T19:15:17.5Z", now: now, zone: zone) == "11월 1일 오전 4:15")
    }

    @Test("연도는 UTC 가 아니라 기기 시간대로 가른다")
    func yearBoundaryUsesZone() {
        let zone = TimeZone(identifier: "Asia/Seoul")!
        // 2026-12-31T23:00:00Z 는 KST 로 2027년 1월 1일이고, 올해도 2027년이다
        let now = Date(timeIntervalSince1970: 1_798_758_000)

        #expect(rideHistoryDateLabel(isoTime: "2026-12-31T16:00:00Z", now: now, zone: zone) == "1월 1일 오전 1:00")
    }

    @Test("요금 표기는 세 자리마다 쉼표다")
    func wonGrouping() {
        #expect(wonLabel(amount: 0) == "0원")
        #expect(wonLabel(amount: 999) == "999원")
        #expect(wonLabel(amount: 1_000) == "1,000원")
        #expect(wonLabel(amount: 16_500) == "16,500원")
        #expect(wonLabel(amount: 1_234_567) == "1,234,567원")
        #expect(wonLabel(amount: -1_500) == "-1,500원")
    }

    @Test("도착 완료 요약은 값이 있는 칸만 만든다")
    func rideCompleteCells() {
        let both = rideCompleteSummaryCells(paidAmount: 4000, companionCount: 2)
        #expect(both.map(\.value) == ["4,000원", "2명"])
        #expect(both.map(\.label) == ["1인 부담", "함께 탄 사람"])

        #expect(rideCompleteSummaryCells(paidAmount: nil, companionCount: 2).map(\.label) == ["함께 탄 사람"])
        #expect(rideCompleteSummaryCells(paidAmount: nil, companionCount: nil).isEmpty)
    }
}
