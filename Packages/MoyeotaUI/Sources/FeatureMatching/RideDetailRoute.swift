import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

@MainActor
@Observable
public final class RideDetailViewModel {
    public enum UiState: Equatable, Sendable {
        case loading
        case success(ride: Ride)
        case error(message: String)
    }

    public private(set) var uiState: UiState = .loading

    public private(set) var left = false

    @ObservationIgnored private let repository: any RideRepository
    @ObservationIgnored private let partyId: Int64
    @ObservationIgnored private let scope = ViewModelScope()

    public init(repository: any RideRepository, partyId: Int64) {
        self.repository = repository
        self.partyId = partyId
        refresh()
    }

    public func refresh() {
        uiState = .loading
        let repository = self.repository
        let partyId = self.partyId
        scope.launch { [weak self] in
            do {
                let ride = try await repository.getPartyDetail(partyId: partyId)
                self?.uiState = .success(ride: ride)
            } catch {
                self?.uiState = .error(message: "탑승 정보를 불러오지 못했어요")
            }
        }
    }

    // 나가기 실패 시 화면을 넘기지 않고 재시도 가능한 에러 상태로 떨어뜨린다.
    public func leave() {
        let repository = self.repository
        let partyId = self.partyId
        scope.launch { [weak self] in
            do {
                // 나가는 주체는 Bearer 토큰이 정한다 — memberId 를 넘기지 않는다 (22 보고서 §2)
                try await repository.leaveParty(partyId: partyId)
                self?.left = true
            } catch {
                self?.uiState = .error(message: "탑승에서 나가지 못했어요")
            }
        }
    }
}

// 22 탑승 상세 — 서버 상세 연동 진입점. partyId 없으면 오류 안내 후 되돌린다.
//
// UserSession 을 더 이상 받지 않는다: 「나」 판정이 매퍼(publicId == 세션 uuid)로 내려가
// 화면은 User.isMe 만 보면 된다. 예전에는 여기서 고정 memberId 1 을 내려보내야 했다.
public struct RideDetailRoute: View {
    private let repository: any RideRepository
    private let partyId: Int64?
    private let taxiEnabled: Bool
    private let onBack: () -> Void
    private let onPartnerClick: (User) -> Void
    private let onLeave: () -> Void

    /// - Parameter taxiEnabled: 택시 모드(서버 설정). 정원 안내 문구가 갈린다 — 기본값은 동승(모르면 동승)
    public init(
        repository: any RideRepository,
        partyId: Int64?,
        taxiEnabled: Bool = false,
        onBack: @escaping () -> Void = {},
        onPartnerClick: @escaping (User) -> Void = { _ in },
        onLeave: @escaping () -> Void = {}
    ) {
        self.repository = repository
        self.partyId = partyId
        self.taxiEnabled = taxiEnabled
        self.onBack = onBack
        self.onPartnerClick = onPartnerClick
        self.onLeave = onLeave
    }

    public var body: some View {
        // 방 id 없이 닿을 길은 없다. 그래도 nil 이면 예시 방을 그리는 대신 사실대로 말하고 되돌린다.
        if let partyId {
            // `.id` 가 원본의 뷰모델 키(`party-{partyId}`) 자리다 — 방이 바뀌면 뷰모델도 새로 만든다.
            RideDetailContent(
                repository: repository,
                partyId: partyId,
                taxiEnabled: taxiEnabled,
                onBack: onBack,
                onPartnerClick: onPartnerClick,
                onLeave: onLeave
            )
            .id(partyId)
        } else {
            BackStateScaffold(title: "탑승 상세", onBack: onBack) {
                ErrorBox(message: "탑승 정보를 불러오지 못했어요", onRetry: onBack)
            }
        }
    }
}

/// 방 id 를 아는 Route 본체. 뷰모델은 id 가 있어야 만들 수 있어 나눴다.
private struct RideDetailContent: View {
    @HostedViewModel private var viewModel: RideDetailViewModel

    // 「내 위치에서 약 N m」용 좌표. 20 합류 확인과 같은 이유로 권한을 자동 요청하지 않는다.
    @RememberMyLocationState(autoRequestPermission: false) private var myLocation

    private let taxiEnabled: Bool
    private let onBack: () -> Void
    private let onPartnerClick: (User) -> Void
    private let onLeave: () -> Void

    init(
        repository: any RideRepository,
        partyId: Int64,
        taxiEnabled: Bool,
        onBack: @escaping () -> Void,
        onPartnerClick: @escaping (User) -> Void,
        onLeave: @escaping () -> Void
    ) {
        _viewModel = HostedViewModel(wrappedValue: RideDetailViewModel(repository: repository, partyId: partyId))
        self.taxiEnabled = taxiEnabled
        self.onBack = onBack
        self.onPartnerClick = onPartnerClick
        self.onLeave = onLeave
    }

    var body: some View {
        let viewModel = self.viewModel
        let left = viewModel.left

        // 효과는 바뀌지 않는 바깥 컨테이너에 건다. 상태 분기(switch)마다 걸면 로딩→성공 전환에서
        // 사라짐·나타남이 불려 위치 구독을 괜히 끊었다 다시 붙인다.
        ZStack {
            // 탭바가 없는 화면 — 로딩·에러에서도 뒤로가기를 남긴다 (QA F-1 동류)
            switch viewModel.uiState {
            case .loading:
                BackStateScaffold(title: "탑승 상세", onBack: onBack) {
                    LoadingBox()
                }
            case .error(let message):
                BackStateScaffold(title: "탑승 상세", onBack: onBack) {
                    ErrorBox(message: message, onRetry: { viewModel.refresh() })
                }
            case .success(let ride):
                RideDetailScreen(
                    ride: ride,
                    pickupDistanceMeters: pickupDistanceMeters(ride: ride, myLocation: myLocation.coordinates),
                    taxiEnabled: taxiEnabled,
                    onBack: onBack,
                    onPartnerClick: onPartnerClick,
                    onLeave: { viewModel.leave() } // 나가기 성공 후 onLeave 로 화면 전환
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .myLocationEffect($myLocation)
        .task(id: left) {
            if left { onLeave() }
        }
    }
}
