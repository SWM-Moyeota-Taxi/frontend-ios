@testable import FeatureMatching
import Foundation
import MoyeotaDomain
import Testing

/// 배차 폴링 루프 — **iOS 에서 추가한 테스트**다.
///
/// 원본은 판정 함수만 고정하고 루프는 QA 의 logcat 계수에 맡겼다. 여기서 루프까지 보는 이유는 가시성 게이트가
/// Swift 에서 `collectLatest` 자리의 직접 구현과 취소 전파에 기대기 때문이다 — 틀리면 복귀 뒤 폴링이 영영
/// 돌지 않아 26 운행 중으로 넘어가지 못한다.
@MainActor
struct DispatchStatusViewModelTest {
    private struct StubError: Error {}

    private final class FakeRepository: RideRepository, DispatchRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var _detail: Result<Ride, any Error>
        private var _detailReads = 0
        private var _driverReads = 0
        private var _locationReads = 0
        private var _hangDriver = false
        private var _driverCancelled = 0

        init(detail: Result<Ride, any Error>) {
            _detail = detail
        }

        var detailReads: Int { lock.withLock { _detailReads } }
        var driverReads: Int { lock.withLock { _driverReads } }
        var locationReads: Int { lock.withLock { _locationReads } }
        var driverCancelled: Int { lock.withLock { _driverCancelled } }

        /// 기사 정보 조회가 취소될 때까지 돌아오지 않게 한다 — 응답을 기다리는 도중의 이탈을 재현한다.
        func hangDriver() {
            lock.withLock { _hangDriver = true }
        }

        func setDetail(_ detail: Result<Ride, any Error>) {
            lock.withLock { _detail = detail }
        }

        func getPartyDetail(partyId: Int64) async throws -> Ride {
            let result = lock.withLock {
                _detailReads += 1
                return _detail
            }
            return try result.get()
        }

        func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver {
            let hang = lock.withLock {
                _driverReads += 1
                return _hangDriver
            }
            if hang {
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    lock.withLock { _driverCancelled += 1 }
                    throw error
                }
            }
            return AssignedDriver(seats: 4, plateNumber: "12가 3456", vehicleType: "쏘나타")
        }

        func getDriverLocation(partyId: Int64) async throws -> DriverLocation {
            lock.withLock { _locationReads += 1 }
            return DriverLocation(latitude: 35.2, longitude: 129.0)
        }

        func getNearbyParties() -> [Ride] { [] }
        func getParties() async throws -> [Ride] { throw StubError() }
        func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] {
            throw StubError()
        }
        func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail { throw StubError() }
        func findRealtimeCandidates(
            departureLat: Double,
            departureLng: Double,
            destinationLat: Double,
            destinationLng: Double
        ) async throws -> [MatchCandidate] { throw StubError() }
        func observePartyEvents(partyId: Int64) -> AsyncThrowingStream<PartyEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func createParty(request: NewParty) async throws -> Ride { throw StubError() }
        func joinParty(partyId: Int64) async throws -> PartyStatus { throw StubError() }
        func leaveParty(partyId: Int64) async throws { throw StubError() }
        func finishParty(partyId: Int64) async throws { throw StubError() }
        func reportEmergency(partyId: Int64?) async throws -> Int64 { throw StubError() }
        func confirmEmergencyCall(called: Bool) async throws { throw StubError() }
        func previewRoute(
            departureLat: Double,
            departureLng: Double,
            destinationLat: Double,
            destinationLng: Double
        ) async throws -> RouteEstimate { throw StubError() }
    }

    private static func ride(status: RideStatus = .dispatching, driverId: Int64? = nil) -> Ride {
        Ride(
            id: "1",
            origin: "부산대",
            destination: "서면",
            departureLabel: "지금 출발",
            capacity: 2,
            members: [],
            farePerPerson: 0,
            totalFare: 0,
            status: status,
            driverId: driverId
        )
    }

    /// 주기가 저절로 돌지 않게 취소될 때까지 멈춰 있는 대기.
    private static let blockingSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }

    private func make(_ repository: FakeRepository) -> DispatchStatusViewModel {
        DispatchStatusViewModel(
            rideRepository: repository,
            dispatchRepository: repository,
            partyId: 1,
            sleep: Self.blockingSleep
        )
    }

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

    /// 원본 `viewModelScope` 는 엔트리가 빠지면 진행 중인 조회를 끊는다. 태스크가 왕복 동안 뷰모델을 잡으면
    /// 해제되지 않아 취소도 오지 않고, 응답이나 타임아웃(20초)까지 요청과 뷰모델이 함께 남는다.
    @Test("refresh - 기사 정보 조회 도중 화면을 떠나면 뷰모델이 해제되고 조회가 취소된다")
    func refreshReleasesViewModelWhileLoadingDriver() async {
        let repository = FakeRepository(detail: .success(Self.ride(driverId: 7)))
        repository.hangDriver()
        weak var released: DispatchStatusViewModel?
        do {
            let viewModel = make(repository)
            released = viewModel
            #expect(await eventually { repository.driverReads == 1 })
        }
        #expect(await eventually { released == nil }, "조회가 뷰모델을 잡고 있다")
        #expect(await eventually { repository.driverCancelled == 1 }, "뷰모델이 해제됐는데 조회가 끊기지 않았다")
    }

    /// 쪼갠 뒤에도 원본 순서가 그대로다 — 기사 정보를 받은 뒤 방을 그리고, 이미 받았으면 다시 묻지 않는다.
    @Test("refresh - 기사 정보를 채운 뒤 방을 그리고 다시 불러도 기사는 다시 묻지 않는다")
    func refreshLoadsDriverOnce() async {
        let ride = Self.ride(driverId: 7)
        let repository = FakeRepository(detail: .success(ride))
        let viewModel = make(repository)
        #expect(await eventually { viewModel.uiState == .success(ride: ride) })
        #expect(viewModel.driver != nil)
        #expect(repository.driverReads == 1)

        viewModel.refresh()
        #expect(await eventually { repository.detailReads == 2 && viewModel.uiState == .success(ride: ride) })
        #expect(repository.driverReads == 1)
    }

    @Test("복귀하면 패스가 곧바로 한 번 읽는다 - 가려진 동안에는 읽지 않는다")
    func visibilityGate() async {
        let repository = FakeRepository(detail: .success(Self.ride()))
        let viewModel = make(repository)
        #expect(await eventually { repository.detailReads == 1 }) // init 의 refresh

        let poll = Task { await viewModel.pollDriver() }
        #expect(await eventually { repository.detailReads == 2 })

        viewModel.onScreenStop()
        await settle()
        #expect(repository.detailReads == 2)

        viewModel.onScreenStart()
        #expect(await eventually { repository.detailReads == 3 })

        poll.cancel()
        await poll.value
    }

    @Test("탑승 시작을 잡으면 신호를 올리고 복귀해도 다시 읽지 않는다")
    func rideStartedEndsLoop() async {
        let repository = FakeRepository(detail: .success(Self.ride(driverId: 7)))
        let viewModel = make(repository)
        #expect(await eventually { repository.detailReads == 1 })
        #expect(await eventually {
            if case .success = viewModel.uiState { return true }
            return false
        })
        #expect(!viewModel.rideStarted)

        repository.setDetail(.success(Self.ride(status: .ongoing, driverId: 7)))
        let poll = Task { await viewModel.pollDriver() }
        #expect(await eventually { viewModel.rideStarted })
        let reads = repository.detailReads

        viewModel.onScreenStop()
        viewModel.onScreenStart()
        await settle()
        #expect(repository.detailReads == reads)

        poll.cancel()
        await poll.value
    }

    @Test("기사 정보는 한 번만 받고 위치는 매 패스 묻는다 - 미배정이면 둘 다 묻지 않는다")
    func driverGate() async {
        let repository = FakeRepository(detail: .success(Self.ride()))
        let viewModel = make(repository)
        let poll = Task { await viewModel.pollDriver() }
        #expect(await eventually { repository.detailReads >= 2 })
        await settle()
        #expect(repository.driverReads == 0)
        #expect(repository.locationReads == 0)

        repository.setDetail(.success(Self.ride(driverId: 7)))
        viewModel.onScreenStop()
        viewModel.onScreenStart()
        #expect(await eventually { repository.locationReads == 1 })
        #expect(viewModel.driver?.plateNumber == "12가 3456")
        #expect(viewModel.driverLocation != nil)
        #expect(repository.driverReads == 1)

        viewModel.onScreenStop()
        await settle()
        viewModel.onScreenStart()
        #expect(await eventually { repository.locationReads == 2 })
        #expect(repository.driverReads == 1)

        poll.cancel()
        await poll.value
    }

    @Test("주기 조회가 실패해도 들고 있던 화면을 에러로 덮지 않는다")
    func pollFailureKeepsScreen() async {
        let ride = Self.ride(driverId: 7)
        let repository = FakeRepository(detail: .success(ride))
        let viewModel = make(repository)
        #expect(await eventually { viewModel.uiState == .success(ride: ride) })

        repository.setDetail(.failure(StubError()))
        let poll = Task { await viewModel.pollDriver() }
        #expect(await eventually { repository.locationReads == 1 })
        #expect(viewModel.uiState == .success(ride: ride))
        #expect(!viewModel.rideStarted)

        poll.cancel()
        await poll.value
    }

    @Test("첫 조회가 실패하면 에러 화면이고 다음 주기에 복구된다")
    func firstLoadFailure() async {
        let repository = FakeRepository(detail: .failure(StubError()))
        let viewModel = make(repository)
        #expect(await eventually { viewModel.uiState == .error(message: "배차 정보를 불러오지 못했어요") })

        let ride = Self.ride()
        repository.setDetail(.success(ride))
        let poll = Task { await viewModel.pollDriver() }
        #expect(await eventually { viewModel.uiState == .success(ride: ride) })

        poll.cancel()
        await poll.value
    }
}
