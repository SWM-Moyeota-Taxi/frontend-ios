@testable import FeatureChat
import Foundation
import MoyeotaDomain
import Testing

/// **iOS 에서 추가한 테스트**다. 원본은 판정 함수만 고정했다.
///
/// 여기서 루프까지 보는 이유는 원본 `collectLatest` 를 손으로 옮겼기 때문이다 — 패스가 겹치거나
/// 취소 뒤 늦은 응답을 반영하면 화면에는 증상 없이 쿼리만 늘거나, 가려진 동안 33 으로 넘어간다.
@MainActor
struct RideOngoingViewModelTest {
    private struct StubError: Error {}

    /// 응답을 손으로 놓아주는 저장소.
    private final class FakeRepository: RideRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        private var _result: Result<Ride, any Error>
        private var _gate: CheckedContinuation<Void, Never>?
        private var _gated = false

        init(result: Result<Ride, any Error>) {
            _result = result
        }

        var reads: Int { lock.withLock { _reads } }

        func setResult(_ result: Result<Ride, any Error>) {
            lock.withLock { _result = result }
        }

        func holdResponses() {
            lock.withLock { _gated = true }
        }

        var isHolding: Bool { lock.withLock { _gate != nil } }

        func releaseResponse() {
            let gate = lock.withLock {
                _gated = false
                let current = _gate
                _gate = nil
                return current
            }
            gate?.resume()
        }

        func getPartyDetail(partyId: Int64) async throws -> Ride {
            lock.withLock { _reads += 1 }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let gated = lock.withLock {
                    if _gated { _gate = continuation }
                    return _gated
                }
                if !gated { continuation.resume() }
            }
            return try lock.withLock { _result }.get()
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
        func createParty(request: NewParty) async throws -> Ride { throw StubError() }
        func joinParty(partyId: Int64) async throws -> PartyStatus { throw StubError() }
        func leaveParty(partyId: Int64) async throws { throw StubError() }
        func finishParty(partyId: Int64) async throws { throw StubError() }
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

    private static func ride(status: RideStatus = .ongoing) -> Ride {
        Ride(
            id: "1", origin: "부산대", destination: "서면", departureLabel: "지금 출발",
            capacity: 2, members: [], farePerPerson: 0, totalFare: 0, status: status
        )
    }

    /// 주기가 저절로 돌지 않게 취소될 때까지 멈춰 있는 대기.
    private static let blockingSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test("첫 조회는 주기를 기다리지 않고 나가고 첫 진입의 onScreenStart 가 한 번 더 부르지 않는다")
    func firstReadIsImmediate() async {
        let repository = FakeRepository(result: .success(Self.ride()))
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1, sleep: Self.blockingSleep)
        viewModel.onScreenStart()
        #expect(await eventually { viewModel.ride != nil })
        await settle()
        #expect(repository.reads == 1)
        #expect(!viewModel.finished)
    }

    @Test("주기는 8초다")
    func pollIntervalIsEightSeconds() async {
        let durations = DurationLog()
        let repository = FakeRepository(result: .success(Self.ride()))
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1) { duration in
            durations.append(duration)
            try await Task.sleep(for: .seconds(3600))
        }
        #expect(await eventually { !durations.values.isEmpty })
        #expect(durations.values == [.milliseconds(8_000)])
        _ = viewModel
    }

    @Test("가려지면 멈추고 돌아오면 주기를 기다리지 않고 바로 읽는다")
    func resumeReadsImmediately() async {
        let repository = FakeRepository(result: .success(Self.ride()))
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1, sleep: Self.blockingSleep)
        #expect(await eventually { repository.reads == 1 })

        viewModel.onScreenStop()
        await settle()
        #expect(repository.reads == 1)

        viewModel.onScreenStart()
        #expect(await eventually { repository.reads == 2 })
    }

    @Test("가려진 동안 FINISHED 가 됐어도 돌아온 즉시 넘어간다")
    func finishedWhileHiddenIsSeenOnReturn() async {
        let repository = FakeRepository(result: .success(Self.ride()))
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1, sleep: Self.blockingSleep)
        #expect(await eventually { repository.reads == 1 })
        viewModel.onScreenStop()

        repository.setResult(.success(Self.ride(status: .completed)))
        await settle()
        #expect(!viewModel.finished)

        viewModel.onScreenStart()
        #expect(await eventually { viewModel.finished })
    }

    @Test("완료 뒤에는 복귀해도 다시 읽지 않는다")
    func finishedDoesNotRevive() async {
        let repository = FakeRepository(result: .success(Self.ride(status: .completed)))
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1, sleep: Self.blockingSleep)
        #expect(await eventually { viewModel.finished })

        viewModel.onScreenStop()
        viewModel.onScreenStart()
        await settle()
        #expect(repository.reads == 1)
    }

    @Test("조회 실패는 화면을 건드리지 않고 다음 주기에 복구한다")
    func failureKeepsHeldDetailAndRecovers() async {
        let repository = FakeRepository(result: .failure(StubError()))
        // 대기 없이 도는 주기 — 실패 뒤 다음 주기가 도는지 본다
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1) { _ in
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually { repository.reads >= 2 })
        #expect(viewModel.ride == nil)
        #expect(!viewModel.finished)

        let ride = Self.ride()
        repository.setResult(.success(ride))
        #expect(await eventually { viewModel.ride == ride })

        // 실패가 다시 와도 마지막 성공값을 유지한다 — 마커가 깜빡이면 "사라졌다"로 읽힌다
        repository.setResult(.failure(StubError()))
        let reads = repository.reads
        #expect(await eventually { repository.reads > reads + 1 })
        #expect(viewModel.ride == ride)
        viewModel.onScreenStop()
    }

    @Test("가려진 뒤 늦게 도착한 응답은 반영하지 않는다")
    func lateResponseAfterHideIsDropped() async {
        let repository = FakeRepository(result: .success(Self.ride(status: .completed)))
        repository.holdResponses()
        let viewModel = RideOngoingViewModel(repository: repository, partyId: 1, sleep: Self.blockingSleep)
        #expect(await eventually { repository.isHolding })

        viewModel.onScreenStop()
        repository.releaseResponse()
        await settle()
        #expect(viewModel.ride == nil)
        #expect(!viewModel.finished, "가려진 화면이 33 으로 넘어가면 안 된다")
    }

    @Test("뷰모델이 해제되면 폴링이 멈춘다")
    func deinitStopsPolling() async {
        let repository = FakeRepository(result: .success(Self.ride()))
        var viewModel: RideOngoingViewModel? = RideOngoingViewModel(repository: repository, partyId: 1) { _ in
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually { repository.reads >= 2 })
        weak let weakViewModel = viewModel
        viewModel = nil
        #expect(await eventually { weakViewModel == nil }, "폴링 태스크가 뷰모델을 잡고 있다")
        await settle()
        let reads = repository.reads
        await settle()
        #expect(repository.reads == reads)
    }

    private final class DurationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Duration] = []
        var values: [Duration] { lock.withLock { _values } }
        func append(_ value: Duration) { lock.withLock { _values.append(value) } }
    }
}

/// 시트 문구와 카메라 판정. 원본에 테스트가 없는 순수 함수라 iOS 에서 더했다.
struct RideOngoingTextTest {
    @Test("목적지를 모르면 일반 문구")
    func headlineWithoutDestination() {
        #expect(ongoingHeadline(destination: nil, estimatedMinutes: 12) == "목적지로 이동 중")
        #expect(ongoingHeadline(destination: "  ", estimatedMinutes: 12) == "목적지로 이동 중")
    }

    @Test("소요가 있으면 까지 약 N분, 없거나 0 이하면 이동 중")
    func headlineWithDestination() {
        #expect(ongoingHeadline(destination: "서면역", estimatedMinutes: 12) == "서면역까지 약 12분")
        #expect(ongoingHeadline(destination: "서면역", estimatedMinutes: nil) == "서면역으로 이동 중")
        #expect(ongoingHeadline(destination: "서면역", estimatedMinutes: 0) == "서면역으로 이동 중")
        #expect(ongoingHeadline(destination: "부산대", estimatedMinutes: -1) == "부산대로 이동 중")
    }

    @Test("받침 없음·ㄹ 받침·한글 아님은 로, 그 외 받침은 으로")
    func directionParticle() {
        #expect(withDirectionParticle(word: "부산대") == "부산대로")
        #expect(withDirectionParticle(word: "서울") == "서울로")
        #expect(withDirectionParticle(word: "서면역") == "서면역으로")
        #expect(withDirectionParticle(word: "KTX") == "KTX로")
        #expect(withDirectionParticle(word: "") == "")
        #expect(withDirectionParticle(word: "   ") == "   ")
    }

    @Test("뒤 공백은 판정에서 빼되 원문은 그대로 붙인다")
    func directionParticleKeepsTrailingSpace() {
        #expect(withDirectionParticle(word: "서면역 ") == "서면역 으로")
    }

    @Test("자모로 풀어 쓴 글자(NFD)는 한글 완성형이 아니라 로")
    func directionParticleDecomposed() {
        // 원본 문자 판정은 UTF-16 한 칸이라 마지막 칸(종성 자모)이 완성형 범위 밖이다
        let decomposed = "\u{1109}\u{1165}\u{1106}\u{1167}\u{11AB}" // 서면
        #expect(withDirectionParticle(word: decomposed) == "\(decomposed)로")
    }

    @Test("카메라 - fitBounds 가 이기고 맞춘 뒤로는 움직이지 않는다")
    func cameraSteps() {
        #expect(rideOngoingCameraStep(boundsFitted: false, centeredOnMe: false, hasBothEndpoints: true, hasMyPosition: true) == .fitBounds)
        #expect(rideOngoingCameraStep(boundsFitted: false, centeredOnMe: true, hasBothEndpoints: true, hasMyPosition: true) == .fitBounds)
        #expect(rideOngoingCameraStep(boundsFitted: false, centeredOnMe: false, hasBothEndpoints: false, hasMyPosition: true) == .centerOnMe)
        #expect(rideOngoingCameraStep(boundsFitted: false, centeredOnMe: true, hasBothEndpoints: false, hasMyPosition: true) == .stay)
        #expect(rideOngoingCameraStep(boundsFitted: false, centeredOnMe: false, hasBothEndpoints: false, hasMyPosition: false) == .stay)
        #expect(rideOngoingCameraStep(boundsFitted: true, centeredOnMe: false, hasBothEndpoints: true, hasMyPosition: true) == .stay)
    }
}
