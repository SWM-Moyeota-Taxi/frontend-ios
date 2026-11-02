import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 34 지난 탑승 기록의 상태·조회.
///
/// 목록을 화면(`@State`)이 아니라 여기에 두는 이유: 커서 페이징이라 **이미 받은 페이지와
/// 다음 커서가 함께 보존돼야** 한다. 화면이 들고 있으면 뷰가 다시 만들어질 때 어긋나
/// 같은 페이지를 다시 받아 목록이 중복된다(36 이 입력값을 여기 두는 것과 같은 결의 이유).
///
/// 원본 `viewModelScope` 는 `Main.immediate` 라 `launch` 의 첫 줄이 호출 자리에서 바로 돈다. `Task` 는 다음 차례에야
/// 돌므로, 첫 중단점 앞의 상태 변경은 `launch` **앞에** 둔다.
@MainActor
@Observable
public final class RideHistoryViewModel {

    public struct UiState: Equatable, Sendable {
        public var records: [RideRecord]
        /// 첫 페이지 조회 중. 목록이 비어 있을 때만 화면 전체 스피너가 된다.
        public var loading: Bool
        /// 다음 페이지 조회 중. 목록 맨 아래 스피너다.
        public var loadingMore: Bool
        /// 다음 페이지 커서. **`hasNext` 가 true 일 때만 값이 있다** — 서버가 그렇게 준다.
        /// 화면에 내보내지 않는다(화면이 판정에 쓰는 것은 `hasNext` 하나다).
        public var nextCursor: Int64?
        public var hasNext: Bool
        /// 조회가 실패했는가. 사유를 구분하지 않는다 — 네트워크든 5xx 든 사용자가 할 일은
        /// 「다시 시도」 하나다. 다음 페이지 실패도 같은 플래그를 쓰지만, 목록이 이미 있으면
        /// 화면은 전면 오류로 바꾸지 않고 바닥 스피너만 거둔다.
        public var failed: Bool

        public init(
            records: [RideRecord] = [],
            loading: Bool = false,
            loadingMore: Bool = false,
            nextCursor: Int64? = nil,
            hasNext: Bool = false,
            failed: Bool = false
        ) {
            self.records = records
            self.loading = loading
            self.loadingMore = loadingMore
            self.nextCursor = nextCursor
            self.hasNext = hasNext
            self.failed = failed
        }
    }

    public private(set) var uiState = UiState()

    @ObservationIgnored private let repository: any RideRecordRepository
    @ObservationIgnored private let scope = ViewModelScope()

    /// 진행 중인 조회. 같은 커서로 두 번 나가는 것을 막는다 — 스크롤 트리거는 쉽게 두 번 불린다.
    /// `Task` 에는 `isActive` 가 없어 끝났는지를 `loadInFlight` 로 따로 든다.
    /// 테스트가 조회가 끝나기를 기다리는 손잡이이기도 하다(원본 테스트의 `advanceUntilIdle` 자리).
    @ObservationIgnored private(set) var loadJob: Task<Void, Never>?
    @ObservationIgnored private var loadInFlight = false

    public init(repository: any RideRecordRepository) {
        self.repository = repository
        refresh()
    }

    /// 첫 페이지부터 다시 받는다. 재시도 버튼과 진입이 같은 경로를 쓴다.
    public func refresh() {
        if loadInFlight { return }
        uiState.loading = true
        uiState.failed = false
        loadInFlight = true
        let repository = self.repository
        loadJob = scope.launch { [weak self] in
            do {
                let page = try await repository.getMyRecords(cursor: nil)
                guard let self else { return }
                self.loadInFlight = false
                var state = self.uiState
                state.records = page.records
                state.loading = false
                state.nextCursor = page.nextCursor
                state.hasNext = page.hasNext
                state.failed = false
                self.uiState = state
            } catch {
                guard !Task.isCancelled else { return }
                // 태스크는 살아 있는데 취소로 끝난 것(`URLError(.cancelled)`)이면 report 가 되던진다. 그 응답도
                // 못 받은 건 같으므로 실패로 그린다 — 안 그러면 스피너가 영영 돈다.
                try? Diagnostics.report(site: .rideHistory, throwable: error)
                guard let self else { return }
                self.loadInFlight = false
                // 실패해도 이전 목록은 남긴다 — 2페이지를 보던 사용자의 화면이 비지 않게.
                self.uiState.loading = false
                self.uiState.failed = true
            }
        }
    }

    /// 다음 페이지. **`hasNext` 가 false 면 아무것도 하지 않는다** — 서버는 그때 `nextCursor` 를
    /// 항상 nil 로 주므로, 커서 없이 부르면 **첫 페이지를 다시 받아** 목록이 무한히 중복된다.
    ///
    /// 커서가 nil 인데 `hasNext` 가 true 인 응답은 서버가 주지 않지만, 그때도 부르지 않는다 —
    /// 보낼 커서가 없으면 그 호출은 첫 페이지 재조회와 같다.
    public func loadMore() {
        let state = uiState
        guard let cursor = state.nextCursor else { return }
        if !shouldLoadMore(hasNext: state.hasNext, loading: state.loadingMore || state.loading) { return }
        if loadInFlight { return }

        uiState.loadingMore = true
        uiState.failed = false
        loadInFlight = true
        let repository = self.repository
        loadJob = scope.launch { [weak self] in
            do {
                let page = try await repository.getMyRecords(cursor: cursor)
                guard let self else { return }
                self.loadInFlight = false
                var next = self.uiState
                let known = Set(next.records.map(\.partyId))
                // 서버 정렬이 `dropoffTime desc, matchId desc` 라 뒤에 붙이면 된다.
                // 같은 방이 두 번 들어오는 것만 막는다 — 목록의 `ForEach` id 가 partyId 라
                // 중복 id 가 들어오면 어느 카드가 그려질지 정해지지 않는다.
                next.records += page.records.filter { !known.contains($0.partyId) }
                next.loadingMore = false
                next.nextCursor = page.nextCursor
                next.hasNext = page.hasNext
                next.failed = false
                self.uiState = next
            } catch {
                guard !Task.isCancelled else { return }
                try? Diagnostics.report(site: .rideHistory, throwable: error)
                guard let self else { return }
                self.loadInFlight = false
                self.uiState.loadingMore = false
                self.uiState.failed = true
            }
        }
    }
}

/// 34 지난 탑승 기록 — `GET /api/v1/users/me/parties` 진입점.
///
/// 진입 즉시 첫 페이지를 받는다(`RideHistoryViewModel` 의 init). 실패하면 화면이 재시도를 그린다.
///
/// **`ActivePartyRepository` 를 받지 않는다.** 이 엔드포인트에는
/// 진행 중인 방이 들어오지 않아(실측 2026-11-01, 로컬 `:8080`) 둘은 서로를 대체하지 않는다 —
/// 진행 중인 방은 14 홈·17 탐색의 배너가 보여 준다.
public struct RideHistoryRoute: View {
    private let onBack: () -> Void

    @HostedViewModel private var viewModel: RideHistoryViewModel

    public init(
        repository: any RideRecordRepository,
        onBack: @escaping () -> Void = {}
    ) {
        self.onBack = onBack
        _viewModel = HostedViewModel(wrappedValue: RideHistoryViewModel(repository: repository))
    }

    public var body: some View {
        let state = viewModel.uiState
        RideHistoryScreen(
            records: state.records,
            loading: state.loading,
            loadingMore: state.loadingMore,
            hasNext: state.hasNext,
            failed: state.failed,
            onLoadMore: { viewModel.loadMore() },
            onRetry: { viewModel.refresh() },
            onBack: onBack
        )
    }
}
