import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import Testing
@testable import FeatureHome

// 16 방 만들기가 핵심 퍼널 2단계(`request_match`)를 **서버가 받아 준 뒤에만** 기록하는지 본다.
// 눌렀다(`click_create_party`)와 됐다(`request_match`)를 가르지 않으면 실패한 신청이 전환으로 세어진다.

private struct NetworkFailure: Error {}

private final class AnalyticsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AnalyticsEvent] = []
    func add(_ event: AnalyticsEvent) { lock.withLock { entries.append(event) } }
    var seen: [AnalyticsEvent] { lock.withLock { entries } }
}

/// 이 테스트가 띄운 태스크의 기록만 받는다 — 같은 모듈의 다른 스위트가 동시에 방을 만들어도 섞이지 않는다.
private enum AnalyticsCapture {
    @TaskLocal static var current: AnalyticsRecorder?
}

private final class FakeRideRepository: RideRepository, @unchecked Sendable {
    var createResult: @Sendable (NewParty) async throws -> Ride = { request in
        Ride(
            id: "7", origin: request.departure, destination: request.destination, departureLabel: "",
            capacity: request.capacity, members: [], farePerPerson: 0, totalFare: 0, status: .recruiting,
            estimatedFare: 15_400
        )
    }

    func createParty(request: NewParty) async throws -> Ride { try await createResult(request) }
    func getNearbyParties() -> [Ride] { [] }
    func getParties() async throws -> [Ride] { throw NetworkFailure() }
    func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] { throw NetworkFailure() }
    func getPartyDetail(partyId: Int64) async throws -> Ride { throw NetworkFailure() }
    func getPartyDetailWithVersion(partyId: Int64) async throws -> PartyDetail { throw NetworkFailure() }
    func findRealtimeCandidates(departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double) async throws -> [MatchCandidate] { [] }
    func joinParty(partyId: Int64) async throws -> PartyStatus { throw NetworkFailure() }
    func leaveParty(partyId: Int64) async throws { throw NetworkFailure() }
    func finishParty(partyId: Int64) async throws { throw NetworkFailure() }
    func getAssignedDriver(partyId: Int64) async throws -> AssignedDriver { throw NetworkFailure() }
    func reportEmergency(partyId: Int64?) async throws -> Int64 { throw NetworkFailure() }
    func confirmEmergencyCall(called: Bool) async throws { throw NetworkFailure() }
    func previewRoute(departureLat: Double, departureLng: Double, destinationLat: Double, destinationLng: Double) async throws -> RouteEstimate { throw NetworkFailure() }
}

private let origin = Place(name: "서울대입구역", roadName: "서울 관악구 남부순환로 1820", latitude: 37.48, longitude: 126.95)
private let destination = Place(name: "강남역", roadName: "서울 강남구 강남대로 396", latitude: 37.49, longitude: 127.02)

@MainActor
@Suite(.serialized)
final class CreatePartyAnalyticsTest {
    private let recorder = AnalyticsRecorder()

    init() {
        Analytics.install { event in AnalyticsCapture.current?.add(event) }
    }

    deinit {
        Analytics.reset()
    }

    private func recording(_ body: @MainActor () async -> Void) async {
        await AnalyticsCapture.$current.withValue(recorder) { await body() }
    }

    @Test("성공하면 click → request_match 순서로 기록하고 지역은 시/구까지만 싣는다")
    func successTracksRequestWithAreas() async {
        let viewModel = CreatePartyViewModel(repository: FakeRideRepository())

        await recording {
            await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 3))?.value
        }

        #expect(recorder.seen == [
            .partyCreateClicked(capacity: 3),
            .matchRequested(
                method: .create,
                capacity: 3,
                originArea: "서울 관악구",
                destinationArea: "서울 강남구",
                estimatedFare: 15_400
            ),
        ])
        // 좌표·장소명·번지는 어느 프로퍼티에도 없다
        for event in recorder.seen {
            let values = event.properties.values.compactMap { if case .string(let s) = $0 { s } else { nil } }
            #expect(!values.contains { $0.contains("1820") || $0.contains("서울대입구역") || $0.contains("37.") })
        }
    }

    @Test("실패하면 request_match 대신 사유 상수가 붙은 fail_match_request 를 기록한다")
    func failureTracksReason() async {
        let repository = FakeRideRepository()
        repository.createResult = { _ in
            throw PartyOpenException(code: PartyJoinException.ALREADY_JOINED_OTHER_PARTY, serverMessage: nil, httpStatus: 409)
        }
        let viewModel = CreatePartyViewModel(repository: repository)

        await recording {
            await viewModel.createParty(origin: origin, destination: destination, conditions: MatchConditions(capacity: 2))?.value
        }

        #expect(recorder.seen == [
            .partyCreateClicked(capacity: 2),
            .matchRequestFailed(method: .create, reason: "already_in_party"),
        ])
    }

    @Test("사유 상수는 문구 분기와 1:1 이다")
    func reasonsMirrorMessages() {
        #expect(openFailureReason(e: PartyOpenException(code: PartyOpenException.SAME_DEPARTURE_DESTINATION, serverMessage: nil, httpStatus: 400)) == "same_departure_destination")
        #expect(openFailureReason(e: PartyOpenException(code: PartyOpenException.OUT_OF_SERVICE_AREA, serverMessage: nil, httpStatus: 400)) == "out_of_service_area")
        #expect(openFailureReason(e: PartyOpenException(code: PartyOpenException.INVALID_CAPACITY, serverMessage: nil, httpStatus: 400)) == "invalid_capacity")
        #expect(openFailureReason(e: PartyOpenException(code: nil, serverMessage: nil, httpStatus: 500)) == "unknown")
    }
}
