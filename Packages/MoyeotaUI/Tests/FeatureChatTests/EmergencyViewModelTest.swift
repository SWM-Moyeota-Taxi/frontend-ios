import CoreGraphics
@testable import FeatureChat
import Foundation
import MoyeotaDomain
import Testing

/// **iOS 에서 추가한 테스트**다. 원본은 이 뷰모델을 실기 QA 로 확인했다.
///
/// 틀렸을 때의 대가가 큰 화면이라 상태 전이를 고정한다 — 다이얼로그에 갇히거나, 저장 실패를 숨겨
/// 「운영팀에 전달됐다」는 거짓말이 되거나, 3초를 못 채운 터치가 신고로 나간다.
@MainActor
struct EmergencyViewModelTest {
    private struct StubError: Error {}

    private final class FakeRepository: RideRepository, @unchecked Sendable {
        private let lock = NSLock()
        private var _reportPartyIds: [Int64?] = []
        private var _confirmValues: [Bool] = []
        private var _reportError: (any Error)?
        private var _confirmError: (any Error)?

        var reportPartyIds: [Int64?] { lock.withLock { _reportPartyIds } }
        var confirmValues: [Bool] { lock.withLock { _confirmValues } }

        func setReportError(_ error: (any Error)?) {
            lock.withLock { _reportError = error }
        }

        func setConfirmError(_ error: (any Error)?) {
            lock.withLock { _confirmError = error }
        }

        func reportEmergency(partyId: Int64?) async throws -> Int64 {
            let error: (any Error)? = lock.withLock {
                _reportPartyIds.append(partyId)
                return _reportError
            }
            if let error { throw error }
            return 1
        }

        func confirmEmergencyCall(called: Bool) async throws {
            let error: (any Error)? = lock.withLock {
                _confirmValues.append(called)
                return _confirmError
            }
            if let error { throw error }
        }

        func getNearbyParties() -> [Ride] { [] }
        func getParties() async throws -> [Ride] { throw StubError() }
        func getPartiesWithin(swLat: Double, swLng: Double, neLat: Double, neLng: Double) async throws -> [Ride] {
            throw StubError()
        }
        func getPartyDetail(partyId: Int64) async throws -> Ride { throw StubError() }
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
        func previewRoute(
            departureLat: Double,
            departureLng: Double,
            destinationLat: Double,
            destinationLng: Double
        ) async throws -> RouteEstimate { throw StubError() }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("홀드는 한 번만 발사되고 방 번호를 그대로 보낸다")
    func holdFiresOnce() async {
        let repository = FakeRepository()
        let viewModel = EmergencyViewModel(repository: repository, partyId: 7)
        viewModel.onEmergencyHold()
        viewModel.onEmergencyHold()
        #expect(viewModel.uiState.dialLaunched)
        #expect(await eventually { !repository.reportPartyIds.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(repository.reportPartyIds == [7])
        #expect(!viewModel.uiState.reportSaveFailed)
    }

    @Test("신고 저장 실패는 배너 플래그만 세우고 다이얼을 되돌리지 않는다")
    func reportFailureIsSurfaced() async {
        let repository = FakeRepository()
        repository.setReportError(StubError())
        let viewModel = EmergencyViewModel(repository: repository, partyId: nil)
        viewModel.onEmergencyHold()
        #expect(await eventually { viewModel.uiState.reportSaveFailed })
        #expect(viewModel.uiState.dialLaunched)
        #expect(repository.reportPartyIds == [nil])
    }

    @Test("재시도 - 실패가 없으면 보내지 않고, 성공하면 배너를 내리고, 실패하면 남긴다")
    func retryReport() async {
        let repository = FakeRepository()
        let viewModel = EmergencyViewModel(repository: repository, partyId: 7)

        viewModel.retryReport()
        #expect(!viewModel.uiState.reportRetrying)
        #expect(repository.reportPartyIds.isEmpty)

        repository.setReportError(StubError())
        viewModel.onEmergencyHold()
        #expect(await eventually { viewModel.uiState.reportSaveFailed })

        viewModel.retryReport()
        #expect(viewModel.uiState.reportRetrying)
        viewModel.retryReport() // 잠금
        #expect(await eventually { !viewModel.uiState.reportRetrying })
        #expect(viewModel.uiState.reportSaveFailed)
        #expect(repository.reportPartyIds.count == 2)

        repository.setReportError(nil)
        viewModel.retryReport()
        #expect(await eventually { !viewModel.uiState.reportSaveFailed })
        #expect(!viewModel.uiState.reportRetrying)
    }

    @Test("복귀 - 홀드 전에는 다이얼로그를 띄우지 않고 홀드 뒤 첫 복귀에 띄운다")
    func resumeShowsDialogOnlyAfterHold() {
        let viewModel = EmergencyViewModel(repository: FakeRepository(), partyId: 7)
        viewModel.onResumedFromDial()
        #expect(!viewModel.uiState.showCallConfirm)

        viewModel.onEmergencyHold()
        #expect(!viewModel.uiState.showCallConfirm)
        viewModel.onResumedFromDial()
        #expect(viewModel.uiState.showCallConfirm)
    }

    @Test("통화 여부 저장 성공 - done 으로 복귀한다")
    func confirmSuccess() async {
        let repository = FakeRepository()
        let viewModel = EmergencyViewModel(repository: repository, partyId: 7)
        viewModel.onEmergencyHold()
        viewModel.onResumedFromDial()

        viewModel.onCallConfirm(called: true)
        #expect(viewModel.uiState.confirmSaving)
        viewModel.onCallConfirm(called: false) // 연타 — 저장 중에는 무시
        #expect(await eventually { viewModel.uiState.done })
        #expect(repository.confirmValues == [true])
        #expect(!viewModel.uiState.confirmSaving)
        #expect(!viewModel.uiState.showCallConfirm)
        #expect(!viewModel.uiState.callConfirmPending)

        // done 뒤에는 복귀해도, 다시 선택해도 열리지 않는다
        viewModel.onResumedFromDial()
        viewModel.reopenCallConfirm()
        #expect(!viewModel.uiState.showCallConfirm)
    }

    @Test("통화 여부 저장 실패 - 안내를 띄우고 다이얼로그를 유지한다")
    func confirmFailure() async {
        let repository = FakeRepository()
        repository.setConfirmError(StubError())
        let viewModel = EmergencyViewModel(repository: repository, partyId: 7)
        viewModel.onEmergencyHold()
        viewModel.onResumedFromDial()

        viewModel.onCallConfirm(called: false)
        #expect(await eventually { viewModel.uiState.confirmError != nil })
        #expect(viewModel.uiState.confirmError == "통화 여부 저장에 실패했어요. 다시 선택해 주세요")
        #expect(viewModel.uiState.showCallConfirm)
        #expect(!viewModel.uiState.done)
        #expect(!viewModel.uiState.confirmSaving)
    }

    @Test("나중에 - 복귀로 되살아나지 않고 다시 선택으로만 열리며 탈출구 조건은 남는다")
    func laterIsSticky() async {
        let repository = FakeRepository()
        repository.setConfirmError(StubError())
        let viewModel = EmergencyViewModel(repository: repository, partyId: 7)
        viewModel.onEmergencyHold()
        viewModel.onResumedFromDial()
        viewModel.onCallConfirm(called: true)
        #expect(await eventually { viewModel.uiState.confirmError != nil })

        viewModel.dismissCallConfirm()
        #expect(!viewModel.uiState.showCallConfirm)
        #expect(viewModel.uiState.callConfirmPending)

        viewModel.onResumedFromDial()
        #expect(!viewModel.uiState.showCallConfirm)

        viewModel.reopenCallConfirm()
        #expect(viewModel.uiState.showCallConfirm)
        #expect(!viewModel.uiState.callConfirmPending)
        // 지워 버리면 「다시 선택」으로 열었을 때 다시 갇힌다
        #expect(viewModel.uiState.confirmError != nil)
    }

    @Test("저장 중에는 나중에를 무시한다")
    func laterIgnoredWhileSaving() async {
        let viewModel = EmergencyViewModel(repository: FakeRepository(), partyId: 7)
        viewModel.onEmergencyHold()
        viewModel.onResumedFromDial()
        viewModel.onCallConfirm(called: true)
        viewModel.dismissCallConfirm()
        #expect(!viewModel.uiState.callConfirmPending)
        #expect(await eventually { viewModel.uiState.done })
    }

    @Test("다이얼 주소와 홀드 시간")
    func dialConstants() {
        #expect(EMERGENCY_DIAL_URL.absoluteString == "tel:112")
        #expect(EMERGENCY_HOLD_MS == 3_000)
    }

    @Test("홀드 - 버튼 밖으로 나가면 손을 뗄 때까지 되살아나지 않는다")
    func holdPressLeavesBounds() {
        let size = CGSize(width: 300, height: 56)
        let inside = CGPoint(x: 150, y: 28)
        let outside = CGPoint(x: 150, y: 80)
        #expect(nextEmergencyHoldPress(current: .idle, location: inside, size: size) == .pressing)
        #expect(nextEmergencyHoldPress(current: .pressing, location: inside, size: size) == .pressing)
        #expect(nextEmergencyHoldPress(current: .pressing, location: outside, size: size) == .abandoned)
        #expect(nextEmergencyHoldPress(current: .abandoned, location: inside, size: size) == .abandoned)
        #expect(nextEmergencyHoldPress(current: .idle, location: CGPoint(x: -1, y: 28), size: size) == .abandoned)
    }
}
