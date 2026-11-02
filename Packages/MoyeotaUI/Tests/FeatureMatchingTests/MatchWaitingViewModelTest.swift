@testable import FeatureMatching
import Foundation
import MoyeotaDomain
import Testing

/// 뷰모델의 수집 루프 — **iOS 에서 추가한 테스트**다.
///
/// 원본은 presentation 테스트 의존성이 junit 뿐이라 판정 함수만 고정하고 루프는 QA 의 logcat 계수에 맡겼다.
/// 여기서 루프까지 보는 이유는 Swift 의 `for try await` 가 취소돼도 오류 없이 끝나 원본에 없던 함정이 있기 때문이다
/// (PORTING 6장). 틀리면 화면이 한 번 가려질 때마다 SSE 를 영영 다시 붙이지 않는다.
@MainActor
struct MatchWaitingViewModelTest {
    private struct StubError: Error {}

    private final class FakeRepository: RideRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var _continuations: [AsyncThrowingStream<PartyEvent, any Error>.Continuation] = []
        private var _terminated = 0
        private var _detailReads = 0
        private var _detail: Result<PartyDetail, any Error>
        private var _hangDetail = false
        private var _detailCancelled = 0
        var leaveError: (any Error)?
        var finishError: (any Error)?
        private(set) var leaveCalls = 0

        init(detail: Result<PartyDetail, any Error>) {
            _detail = detail
        }

        var subscriptions: Int { lock.withLock { _continuations.count } }
        var terminated: Int { lock.withLock { _terminated } }
        var alive: Int { subscriptions - terminated }
        var detailReads: Int { lock.withLock { _detailReads } }
        var detailCancelled: Int { lock.withLock { _detailCancelled } }

        /// 상세 조회가 취소될 때까지 돌아오지 않게 한다 — 응답을 기다리는 도중의 이탈을 재현한다.
        func hangDetail() {
            lock.withLock { _hangDetail = true }
        }

        func setDetail(_ detail: Result<PartyDetail, any Error>) {
            lock.withLock { _detail = detail }
        }

        func latest() -> AsyncThrowingStream<PartyEvent, any Error>.Continuation? {
            lock.withLock { _continuations.last }
        }

        func observePartyEvents(partyId: Int64) -> AsyncThrowingStream<PartyEvent, any Error> {
            AsyncThrowingStream { continuation in
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.withLock { self._terminated += 1 }
                }
                lock.withLock { _continuations.append(continuation) }
            }
        }

        func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail {
            let (result, hang) = lock.withLock {
                _detailReads += 1
                return (_detail, _hangDetail)
            }
            if hang {
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    lock.withLock { _detailCancelled += 1 }
                    throw error
                }
            }
            return try result.get()
        }

        func leaveParty(partyId: Int64) async throws {
            leaveCalls += 1
            if let leaveError { throw leaveError }
        }

        func finishParty(partyId: Int64) async throws {
            if let finishError { throw finishError }
        }

        func getNearbyParties() -> [Ride] { [] }
        func getParties() async throws -> [Ride] { throw StubError() }
        func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] {
            throw StubError()
        }
        func getPartyDetail(partyId: Int64) async throws -> Ride { throw StubError() }
        func findRealtimeCandidates(
            departureLat: Double,
            departureLng: Double,
            destinationLat: Double,
            destinationLng: Double
        ) async throws -> [MatchCandidate] { throw StubError() }
        func createParty(request: NewParty) async throws -> Ride { throw StubError() }
        func joinParty(partyId: Int64) async throws -> PartyStatus { throw StubError() }
        func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw StubError() }
        func reportEmergency(partyId: Int64?) async throws -> Int64 { throw StubError() }
        func confirmEmergencyCall(called: Bool) async throws { throw StubError() }
        func previewRoute(
            departureLat: Double,
            departureLng: Double,
            destinationLat: Double,
            destinationLng: Double
        ) async throws -> RouteEstimate { throw StubError() }
    }

    private static let me = User(id: "me", nickname: "나", verifiedLabel: "", rating: 0, rideCount: 0, isMe: true)
    private static let other = User(id: "u2", nickname: "남", verifiedLabel: "", rating: 0, rideCount: 0)

    private static func ride(members: [User] = [me], status: RideStatus = .recruiting) -> Ride {
        Ride(
            id: "1",
            origin: "부산대",
            destination: "서면",
            departureLabel: "지금 출발",
            capacity: 3,
            members: members,
            farePerPerson: 0,
            totalFare: 0,
            status: status
        )
    }

    private static func okDetail(ride: Ride = ride(), version: Int64? = 1) -> Result<PartyDetail, any Error> {
        .success(PartyDetail(ride: ride, version: version))
    }

    /// 폴백 주기가 저절로 돌지 않게 취소될 때까지 멈춰 있는 대기.
    private static let blockingSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }

    /// 조건이 설 때까지 기다린다. 시간 안에 안 서면 false.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// 지금 쌓인 태스크들이 돌 틈을 준다 — 「일어나지 않아야 하는 일」을 볼 때 쓴다.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func make(
        _ repository: FakeRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void = blockingSleep
    ) -> MatchWaitingViewModel {
        MatchWaitingViewModel(repository: repository, partyId: 1, sleep: sleep)
    }

    /// 원본 `viewModelScope` 는 엔트리가 빠지면 진행 중인 조회를 끊는다. 태스크가 왕복 동안 뷰모델을 잡으면
    /// 해제되지 않아 취소도 오지 않고, 응답이나 타임아웃(20초)까지 요청과 뷰모델이 함께 남는다.
    @Test("refresh - 첫 조회 도중 화면을 떠나면 뷰모델이 해제되고 조회가 취소된다")
    func refreshReleasesViewModelWhileLoading() async {
        let repository = FakeRepository(detail: Self.okDetail())
        repository.hangDetail()
        weak var released: MatchWaitingViewModel?
        do {
            let viewModel = make(repository)
            released = viewModel
            #expect(await eventually { repository.detailReads == 1 })
        }
        #expect(await eventually { released == nil }, "조회가 뷰모델을 잡고 있다")
        #expect(await eventually { repository.detailCancelled == 1 }, "뷰모델이 해제됐는데 조회가 끊기지 않았다")
    }

    /// 쪼갠 뒤에도 원본 규칙이 그대로다 — 실패는 에러 화면, 다시 시도의 성공은 방 표시.
    @Test("refresh - 실패하면 에러를 띄우고 다시 시도가 성공하면 방을 그린다")
    func refreshPublishesResult() async {
        let repository = FakeRepository(detail: .failure(StubError()))
        let viewModel = make(repository)
        #expect(await eventually { viewModel.uiState == .error(message: "매칭 정보를 불러오지 못했어요") })

        repository.setDetail(Self.okDetail())
        viewModel.refresh()
        #expect(await eventually { viewModel.uiState == .success(ride: Self.ride()) })
    }

    /// **PORTING 6장의 그 규칙.** 가려져서 취소된 수집은 종결이 아니다 — 복귀하면 다시 붙어야 한다.
    @Test("streamEnded - 가려져서 끊긴 구독은 종결로 적히지 않고 복귀 때 다시 붙는다")
    func hiddenStreamIsNotTerminal() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)
        #expect(await eventually { repository.subscriptions == 1 })

        viewModel.onScreenStop()
        #expect(await eventually { repository.terminated == 1 })
        await settle()
        #expect(repository.subscriptions == 1, "가려진 동안 다시 붙으면 안 된다")

        viewModel.onScreenStart()
        #expect(await eventually { repository.subscriptions == 2 }, "복귀해도 SSE 를 다시 붙이지 않는다")
        #expect(repository.alive == 1, "살아 있는 수집은 하나뿐이어야 한다")
    }

    /// 빠르게 토글해도 겹치지 않는다 — 겹치면 서버가 서로의 연결을 끊는 무한 재연결이 된다.
    @Test("수집은 어느 순간에도 하나뿐이다 - 가시성이 빠르게 토글돼도")
    func rapidToggleSingleCollector() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)
        #expect(await eventually { repository.subscriptions == 1 })

        for _ in 0..<5 {
            viewModel.onScreenStop()
            viewModel.onScreenStart()
            await settle()
            #expect(repository.alive <= 1)
        }
        #expect(await eventually { repository.alive == 1 })
    }

    /// 스스로 끝난 스트림은 종결이다 — 복귀해도 붙지 않고, 폴백이 6초를 기다리지 않고 바로 읽는다.
    @Test("streamEnded - 스스로 끝난 스트림은 다시 붙지 않고 폴백이 즉시 읽는다")
    func finishedStreamIsTerminal() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)
        #expect(await eventually { repository.subscriptions == 1 && repository.detailReads == 1 })

        repository.latest()?.finish()
        #expect(await eventually { repository.detailReads == 2 }, "READ_NOW 로 즉시 읽어야 한다")

        viewModel.onScreenStop()
        await settle()
        viewModel.onScreenStart()
        await settle()
        #expect(repository.subscriptions == 1, "종결로 끝난 스트림을 다시 붙였다")
    }

    /// 403 — 화면을 떠나게 하고 내가 없는 방을 더 읽지 않는다.
    @Test("403 - 멤버십 상실이 서고 폴백이 읽지 않는다")
    func membershipLostStops() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)
        #expect(await eventually { repository.subscriptions == 1 && repository.detailReads == 1 })

        repository.latest()?.finish(throwing: PartyMembershipLostException(partyId: 1))
        #expect(await eventually { viewModel.membershipLost })
        await settle()

        #expect(repository.detailReads == 1, "내가 없는 방을 읽었다")
        #expect(!viewModel.partyClosed, "방이 닫힌 것과 뭉개면 안 된다")
    }

    /// 화면을 떠나 뷰모델이 해제되면 연결도 끊긴다. 태스크가 뷰모델을 강하게 잡으면 영영 남는다.
    @Test("뷰모델이 해제되면 SSE 수집도 끝난다")
    func deinitCancelsStream() async {
        let repository = FakeRepository(detail: Self.okDetail())
        var viewModel: MatchWaitingViewModel? = make(repository)
        weak let released = viewModel
        #expect(await eventually { repository.subscriptions == 1 && repository.detailReads == 1 })

        viewModel = nil

        #expect(await eventually { released == nil }, "뷰모델이 해제되지 않았다")
        #expect(await eventually { repository.terminated == 1 }, "연결이 남았다")
    }

    @Test("스냅샷으로 방을 그리고, 살아 있는 동안 폴백은 읽지 않는다")
    func snapshotAndNoPolling() async {
        let repository = FakeRepository(detail: .failure(StubError()))
        // 대기가 곧바로 끝나 폴백이 빠르게 돈다 — 살아 있으면 그래도 읽지 않아야 한다.
        let viewModel = make(repository, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        #expect(await eventually { repository.subscriptions == 1 })

        let ride = Self.ride(members: [Self.me, Self.other])
        repository.latest()?.yield(.snapshot(ride: ride, version: 3))
        #expect(await eventually { viewModel.uiState == .success(ride: ride) })

        let reads = repository.detailReads
        await settle()
        #expect(repository.detailReads == reads, "SSE 가 살아 있는데 상세를 읽었다")

        repository.latest()?.yield(.disconnected)
        #expect(await eventually { repository.detailReads > reads }, "끊겼는데 폴백이 돌지 않았다")
    }

    @Test("closed 신호를 받으면 방이 닫혔다고 알린다")
    func closedSignal() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)
        #expect(await eventually { repository.subscriptions == 1 })

        repository.latest()?.yield(.closed)

        #expect(await eventually { viewModel.partyClosed })
        #expect(!viewModel.membershipLost)
    }

    /// 재연결 스냅샷이 낡았으면 반영한 합류를 지우지 않는다.
    @Test("낡은 스냅샷이 반영한 합류를 지우지 않는다")
    func staleSnapshotDropped() async {
        let repository = FakeRepository(detail: .failure(StubError()))
        let viewModel = make(repository)
        #expect(await eventually { repository.subscriptions == 1 })

        repository.latest()?.yield(.snapshot(ride: Self.ride(), version: 1))
        repository.latest()?.yield(.memberJoined(member: Self.other, status: .recruiting, version: 2))
        let joined = Self.ride(members: [Self.me, Self.other])
        #expect(await eventually { viewModel.uiState == .success(ride: joined) })

        repository.latest()?.yield(.snapshot(ride: Self.ride(), version: 1))
        await settle()
        #expect(viewModel.uiState == .success(ride: joined))
    }

    @Test("첫 조회가 실패하면 에러 문구를 띄우고, 다시 시도하면 방을 그린다")
    func refreshErrorThenRetry() async {
        let repository = FakeRepository(detail: .failure(StubError()))
        let viewModel = make(repository)
        #expect(await eventually { viewModel.uiState == .error(message: "매칭 정보를 불러오지 못했어요") })

        repository.setDetail(Self.okDetail())
        viewModel.refresh()

        #expect(await eventually { viewModel.uiState == .success(ride: Self.ride()) })
    }

    @Test("상세의 목록에서 내가 사라지면 멤버십 상실이 선다")
    func detailDetectsLostMembership() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)
        #expect(await eventually { viewModel.uiState == .success(ride: Self.ride()) })

        repository.setDetail(Self.okDetail(ride: Self.ride(members: [Self.other]), version: 2))
        viewModel.refresh()

        #expect(await eventually { viewModel.membershipLost })
    }

    @Test("나가기 - 성공하면 left 가 서고 진행 표시가 내려간다")
    func leaveSuccess() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)

        viewModel.leaveParty()
        #expect(viewModel.actionState.inProgress, "두 번째 탭을 막으려면 바로 서야 한다")
        viewModel.leaveParty()

        #expect(await eventually { viewModel.actionState.left && !viewModel.actionState.inProgress })
        #expect(repository.leaveCalls == 1, "중복 실행 차단이 듣지 않았다")
    }

    @Test("나가기·합승 완료 실패는 사유별 문구로 옮긴다")
    func actionFailureMessages() async {
        let repository = FakeRepository(detail: Self.okDetail())
        let viewModel = make(repository)

        repository.leaveError = PartyLeaveException(
            code: PartyLeaveException.PARTY_NOT_RECRUITING,
            serverMessage: nil,
            httpStatus: 409
        )
        viewModel.leaveParty()
        #expect(await eventually { viewModel.actionState.errorMessage == "매칭이 시작돼 지금은 나갈 수 없어요" })
        #expect(!viewModel.actionState.inProgress)
        #expect(!viewModel.actionState.left)

        repository.leaveError = StubError()
        viewModel.leaveParty()
        #expect(await eventually { viewModel.actionState.errorMessage == "방에서 나가지 못했어요" })

        repository.finishError = PartyFinishException(
            code: PartyFinishException.NOT_PARTY_HOST,
            serverMessage: nil,
            httpStatus: 403
        )
        viewModel.finishParty()
        #expect(await eventually {
            viewModel.actionState.errorMessage == "방장만 합승을 완료할 수 있어요. 가장 먼저 참여한 분에게 부탁해 주세요"
        })

        repository.finishError = StubError()
        viewModel.finishParty()
        #expect(await eventually { viewModel.actionState.errorMessage == "합승을 완료하지 못했어요" })
        #expect(!viewModel.actionState.finished)
    }
}
