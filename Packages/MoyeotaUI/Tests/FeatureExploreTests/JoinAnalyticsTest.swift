@testable import FeatureExplore
import Foundation
import MoyeotaDomain
import Testing

// 20 합류 확인이 핵심 퍼널 2단계(`request_match`, method=join)를 **합류가 받아들여진 뒤에만** 기록하는지 본다.
// 「이미 이 방 멤버」로 복구된 경우도 서버에 내 자리가 있다는 뜻이라 같은 길이다.

private struct TestFailure: Error {}

private final class AnalyticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AnalyticsEvent] = []
    func add(_ event: AnalyticsEvent) { lock.withLock { entries.append(event) } }
    var seen: [AnalyticsEvent] { lock.withLock { entries } }
}

private enum AnalyticsCapture {
    @TaskLocal static var current: AnalyticsRecorder?
}

private func room() -> Ride {
    Ride(
        id: "7", origin: "부산대 정문", destination: "서면역", departureLabel: "", capacity: 3,
        members: [User(id: "u-1", nickname: "동승자", verifiedLabel: "", rating: 0, rideCount: 0)],
        farePerPerson: 0, totalFare: 0, status: .recruiting, estimatedFare: 9_800
    )
}

private final class FakeRideRepository: RideRepository, @unchecked Sendable {
    var joinResult: @Sendable () async throws -> PartyStatus = { PartyStatus(status: .recruiting, currentMembers: 2) }

    func getPartyDetail(partyId: Int64) async throws -> Ride { room() }
    func joinParty(partyId: Int64) async throws -> PartyStatus { try await joinResult() }
    func getNearbyParties() -> [Ride] { [] }
    func getParties() async throws -> [Ride] { throw TestFailure() }
    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] { throw TestFailure() }
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail { throw TestFailure() }
    func findRealtimeCandidates(departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double) async throws -> [MatchCandidate] { throw TestFailure() }
    func createParty(request: NewParty) async throws -> Ride { throw TestFailure() }
    func leaveParty(partyId: Int64) async throws { throw TestFailure() }
    func finishParty(partyId: Int64) async throws { throw TestFailure() }
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw TestFailure() }
    func reportEmergency(partyId: Int64?) async throws -> Int64 { throw TestFailure() }
    func confirmEmergencyCall(called: Bool) async throws { throw TestFailure() }
    func previewRoute(departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double) async throws -> RouteEstimate { throw TestFailure() }
}

@MainActor
@Suite(.serialized)
final class JoinAnalyticsTest {
    private let recorder = AnalyticsRecorder()
    private let repository = FakeRideRepository()

    init() {
        Analytics.install { event in AnalyticsCapture.current?.add(event) }
    }

    deinit {
        Analytics.reset()
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// 상세가 떠 있는 뷰모델. 합류 버튼은 그 상태에서만 눌릴 수 있다.
    private func loaded() async -> JoinConfirmViewModel {
        let viewModel = JoinConfirmViewModel(repository: repository, partyId: 7)
        #expect(await eventually { viewModel.uiState == .success(ride: room()) })
        return viewModel
    }

    @Test("합류가 받아들여지면 click → request_match(join) 를 기록하고 정원·요금은 상세에서 가져온다")
    func joinTracksRequest() async {
        let viewModel = await loaded()

        await AnalyticsCapture.$current.withValue(recorder) {
            viewModel.join()
            #expect(await eventually { viewModel.joinState.joinedPartyId == 7 })
        }

        #expect(recorder.seen == [
            .partyJoinClicked,
            .matchRequested(method: .join, capacity: 3, originArea: nil, destinationArea: nil, estimatedFare: 9_800),
        ])
    }

    @Test("이미 이 방 멤버였던 복구도 매칭 신청으로 센다")
    func alreadyInThisPartyCounts() async {
        let viewModel = await loaded()
        repository.joinResult = {
            throw PartyJoinException(
                code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY, serverMessage: nil, httpStatus: 409,
                joinedStatus: PartyStatus(status: .recruiting, currentMembers: 2)
            )
        }

        await AnalyticsCapture.$current.withValue(recorder) {
            viewModel.join()
            #expect(await eventually { viewModel.joinState.joinedPartyId == 7 })
        }

        #expect(recorder.seen.map(\.name) == ["click_join_party", "request_match"])
    }

    @Test("거절되면 request_match 는 없고 사유 상수가 붙은 fail_match_request 만 남는다")
    func rejectionTracksReason() async {
        let viewModel = await loaded()
        repository.joinResult = { throw PartyJoinException(code: "PARTY_FULL", serverMessage: nil, httpStatus: 409) }

        await AnalyticsCapture.$current.withValue(recorder) {
            viewModel.join()
            #expect(await eventually { viewModel.joinState.errorMessage != nil })
        }

        #expect(recorder.seen == [
            .partyJoinClicked,
            .matchRequestFailed(method: .join, reason: "party_full"),
        ])
    }

    @Test("사유 상수는 문구 분기와 1:1 이다")
    func reasonsMirrorMessages() {
        #expect(joinFailureReason(e: PartyJoinException(code: "PARTY_CLOSED", serverMessage: nil)) == "party_closed")
        #expect(joinFailureReason(e: PartyJoinException(code: nil, serverMessage: nil, httpStatus: 404)) == "party_not_found")
        #expect(joinFailureReason(e: PartyJoinException(code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY, serverMessage: nil)) == "already_in_party")
        #expect(joinFailureReason(e: PartyJoinException(code: nil, serverMessage: nil, isNetwork: true)) == "network")
        #expect(joinFailureReason(e: PartyJoinException(code: nil, serverMessage: nil, httpStatus: 500)) == "unknown")
    }
}
