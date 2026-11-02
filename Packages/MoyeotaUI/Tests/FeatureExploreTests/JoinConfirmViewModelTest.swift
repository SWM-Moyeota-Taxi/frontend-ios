@testable import FeatureExplore
import Foundation
import MoyeotaDomain
import Testing

// 원본에는 없는 테스트다. 원본의 `viewModelScope.launch` 는 메인 스레드에서 곧바로 돌아 첫 줄의 잠금이 동기로 걸리지만,
// iOS 의 태스크는 다음 차례에 돌기 때문에 잠금을 옮긴 자리가 맞는지, 실패 분기를 원본대로 따르는지 여기서 본다.

private struct TestFailure: Error {}

private func room(members: Int = 1) -> Ride {
    Ride(
        id: "7",
        origin: "부산대 정문",
        destination: "서면역",
        departureLabel: "",
        capacity: 3,
        members: (0..<members).map { User(id: "u-\($0)", nickname: "동승자", verifiedLabel: "", rating: 0, rideCount: 0) },
        farePerPerson: 0,
        totalFare: 0,
        status: .recruiting
    )
}

/// 상세·합류만 쓴다. 나머지는 이 화면이 부르지 않으므로 부르면 던진다.
private final class FakeRideRepository: RideRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var detailResults: [@Sendable () async throws -> Ride] = []
    private var joinResults: [@Sendable () async throws -> PartyStatus] = []
    private var detailCalls = 0
    private var joinCalls = 0

    var detailCount: Int { lock.withLock { detailCalls } }
    var joinCount: Int { lock.withLock { joinCalls } }

    func enqueueDetail(_ result: @escaping @Sendable () async throws -> Ride) {
        lock.withLock { detailResults.append(result) }
    }

    func enqueueJoin(_ result: @escaping @Sendable () async throws -> PartyStatus) {
        lock.withLock { joinResults.append(result) }
    }

    func getPartyDetail(partyId: Int64) async throws -> Ride {
        let next: (@Sendable () async throws -> Ride)? = lock.withLock {
            detailCalls += 1
            return detailResults.isEmpty ? nil : detailResults.removeFirst()
        }
        guard let next else { throw TestFailure() }
        return try await next()
    }

    func joinParty(partyId: Int64) async throws -> PartyStatus {
        let next: (@Sendable () async throws -> PartyStatus)? = lock.withLock {
            joinCalls += 1
            return joinResults.isEmpty ? nil : joinResults.removeFirst()
        }
        guard let next else { throw TestFailure() }
        return try await next()
    }

    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] {
        throw TestFailure()
    }
    func getNearbyParties() -> [Ride] { [] }
    func getParties() async throws -> [Ride] { throw TestFailure() }
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail { throw TestFailure() }
    func findRealtimeCandidates(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> [MatchCandidate] { throw TestFailure() }
    func observePartyEvents(partyId: Int64) -> AsyncThrowingStream<PartyEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: TestFailure()) }
    }
    func createParty(request: NewParty) async throws -> Ride { throw TestFailure() }
    func leaveParty(partyId: Int64) async throws { throw TestFailure() }
    func finishParty(partyId: Int64) async throws { throw TestFailure() }
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw TestFailure() }
    func reportEmergency(partyId: Int64?) async throws -> Int64 { throw TestFailure() }
    func confirmEmergencyCall(called: Bool) async throws { throw TestFailure() }
    func previewRoute(
        departureLat: Double,
        departureLng: Double,
        destinationLat: Double,
        destinationLng: Double
    ) async throws -> RouteEstimate { throw TestFailure() }
}

/// 시험이 쥐고 있다가 풀어 주는 합류 응답 — 제출 중 상태를 볼 때 쓴다.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func eventually(
    _ what: Comment,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("시간 안에 일어나지 않았다: \(what)", sourceLocation: sourceLocation)
}

@MainActor
@Suite(.serialized)
struct JoinConfirmViewModelTest {
    private let repository = FakeRideRepository()

    private func loaded() async -> JoinConfirmViewModel {
        repository.enqueueDetail { room() }
        let viewModel = JoinConfirmViewModel(repository: repository, partyId: 7)
        await eventually("상세를 읽었다") { viewModel.uiState == .success(ride: room()) }
        return viewModel
    }

    @Test("상세를 못 읽으면 오류 문구를 띄우고 다시 시도하면 다시 읽는다")
    func detailFailureThenRetry() async {
        let viewModel = JoinConfirmViewModel(repository: repository, partyId: 7)
        await eventually("오류로 떨어진다") { viewModel.uiState == .error(message: "동승 정보를 불러오지 못했어요") }

        repository.enqueueDetail { room() }
        viewModel.refresh()
        #expect(viewModel.uiState == .loading)
        await eventually("다시 읽었다") { viewModel.uiState == .success(ride: room()) }
    }

    @Test("연타해도 합류 요청은 한 번만 나간다")
    func doubleTapJoinsOnce() async {
        let viewModel = await loaded()
        let gate = Gate()
        repository.enqueueJoin {
            await gate.wait()
            return PartyStatus(status: .recruiting, currentMembers: 2)
        }

        viewModel.join()
        // 태스크가 돌기 전에도 잠겨 있어야 한다 — 연타한 두 번째 호출이 이 사이에 들어온다.
        #expect(viewModel.joinState.joining)
        viewModel.join()

        await eventually("요청이 나갔다") { repository.joinCount == 1 }
        await gate.open()
        await eventually("합류했다") { viewModel.joinState.joinedPartyId == 7 }
        #expect(!viewModel.joinState.joining)
        #expect(repository.joinCount == 1)
    }

    @Test("이미 이 방 멤버면 성공과 같은 길로 간다")
    func alreadyInThisPartyGoesToSuccess() async {
        let viewModel = await loaded()
        repository.enqueueJoin {
            throw PartyJoinException(
                code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY,
                serverMessage: nil,
                httpStatus: 409,
                joinedStatus: PartyStatus(status: .recruiting, currentMembers: 2)
            )
        }

        viewModel.join()

        await eventually("합류로 처리했다") { viewModel.joinState.joinedPartyId == 7 }
        #expect(viewModel.joinState.errorMessage == nil)
        #expect(!viewModel.joinState.joining)
    }

    @Test("가득 찬 방이면 문구를 남긴 채 상세만 조용히 다시 읽는다")
    func fullPartyRefreshesQuietly() async {
        let viewModel = await loaded()
        repository.enqueueJoin { throw PartyJoinException(code: "PARTY_FULL", serverMessage: nil, httpStatus: 409) }
        repository.enqueueDetail { room(members: 3) }

        viewModel.join()

        await eventually("지금 인원으로 바뀌었다") { viewModel.uiState == .success(ride: room(members: 3)) }
        #expect(viewModel.joinState.errorMessage == "방이 가득 찼어요. 다른 방을 찾아 주세요")
        #expect(viewModel.joinState.joinedPartyId == nil)
    }

    @Test("조용한 재조회가 실패하면 보던 상세를 그대로 둔다")
    func quietRefreshFailureKeepsRide() async {
        let viewModel = await loaded()
        repository.enqueueJoin { throw PartyJoinException(code: "PARTY_CLOSED", serverMessage: nil, httpStatus: 409) }

        viewModel.join()

        await eventually("재조회까지 끝났다") { repository.detailCount == 2 }
        await eventually("문구가 떴다") { viewModel.joinState.errorMessage == "모집이 끝난 방이에요. 다른 방을 찾아 주세요" }
        #expect(viewModel.uiState == .success(ride: room()))
    }

    @Test("그 밖의 실패는 재조회 없이 재시도 안내로 떨어진다")
    func otherFailureHasNoRefresh() async {
        let viewModel = await loaded()
        repository.enqueueJoin { throw TestFailure() }

        viewModel.join()

        await eventually("문구가 떴다") { viewModel.joinState.errorMessage == "합류하지 못했어요. 잠시 후 다시 시도해 주세요" }
        #expect(!viewModel.joinState.joining)
        #expect(repository.detailCount == 1)
    }

    @Test("다시 제출하면 앞 실패 문구가 지워진다")
    func resubmitClearsMessage() async {
        let viewModel = await loaded()
        repository.enqueueJoin { throw TestFailure() }
        viewModel.join()
        await eventually("문구가 떴다") { viewModel.joinState.errorMessage != nil }

        let gate = Gate()
        repository.enqueueJoin {
            await gate.wait()
            return PartyStatus(status: .recruiting, currentMembers: 2)
        }
        viewModel.join()
        #expect(viewModel.joinState.errorMessage == nil)

        await gate.open()
        await eventually("합류했다") { viewModel.joinState.joinedPartyId == 7 }
    }

    /// 원본은 OkHttp `IOException("Canceled")` 이 `isNetwork` 인 `PartyJoinException` 이 되어 재시도를 안내한다.
    /// 문구 없이 잠금만 풀면 합류를 눌렀는데 아무 일도 없는 화면이 된다.
    @Test("살아 있는 태스크의 URLError(.cancelled) 는 네트워크 문구를 띄우고 잠금을 푼다")
    func liveUrlCancelShowsNetworkMessage() async {
        let viewModel = await loaded()
        repository.enqueueJoin { throw URLError(.cancelled) }

        viewModel.join()

        await eventually("잠금이 풀렸다") { !viewModel.joinState.joining }
        #expect(viewModel.joinState.errorMessage == "네트워크가 불안정해요. 연결을 확인하고 다시 시도해 주세요")
        #expect(viewModel.joinState.joinedPartyId == nil)
    }

    @Test("요금은 천 단위로 끊어 쓴다")
    func wonGroupsThousands() {
        #expect(won(amount: 12_700, locale: Locale(identifier: "ko_KR")) == "12,700원")
        #expect(won(amount: 700, locale: Locale(identifier: "ko_KR")) == "700원")
    }
}
