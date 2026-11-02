import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

// 와이어프레임 색 (core token 미정의 — 화면 재현용)
private let EmergencyBg = Color(argb: 0xFFF5F7FA)
private let EmMuteGray = Color(argb: 0xFF8A93A0)
private let EmAshGray = Color(argb: 0xFF9AA1AC)
private let EmTextMute = Color(argb: 0xFF6B7280)
private let EmCardShadow = Color(argb: 0x1A1B2A4A)

/// 다이얼 주소. 원본 `ACTION_DIAL` + `tel:112` 의 자리다.
let EMERGENCY_DIAL_URL = URL(string: "tel:112")!

/// 신고 버튼을 이만큼 누르고 있어야 발사된다 — 오작동 방지
let EMERGENCY_HOLD_MS: Int64 = 3_000

/// 27 · 긴급 신고 ViewModel [S17]
///
/// 새 흐름 (사유 선택 없음 — 서버 ReportRequest 는 partyId/위치뿐):
/// 3초 홀드 완료 → ①신고 저장 발사(reportEmergency — 실패해도 **통화는 막지 않는다**)
/// ②UI 가 즉시 112 다이얼(`tel:112`) → 앱 복귀(scenePhase `.active`) → "실제로 통화하셨나요?" 다이얼로그
/// → confirmEmergencyCall(called) 저장 성공 시 done → 26 복귀
///
/// **실패를 숨기지 않는다.** 신고 저장이 실패하면 화면이 그 사실을 배너로 말하고 재시도를 내놓는다
/// (`UiState.reportSaveFailed`) — 예전엔 이 플래그를 아무도 읽지 않아, 지하 주차장·터널에서 저장이
/// 실패해도 버튼 문구만 「112 통화 화면으로 연결했어요」로 바뀌었다. 사용자는 위치·운행 정보가
/// 운영팀에 전달됐다고 믿는다(화면 상단이 그렇게 약속한다).
@MainActor
@Observable
public final class EmergencyViewModel {
    public struct UiState: Equatable, Sendable {
        public var dialLaunched: Bool // 3초 홀드 완료 — 112 다이얼 발사됨
        /// 신고 저장(`reportEmergency`) 실패. **통화 흐름은 멈추지 않는다** — 통화가 최우선이라는
        /// 기존 설계는 그대로고, 달라진 건 이 사실을 **화면이 말한다**는 것뿐이다.
        public var reportSaveFailed: Bool
        /// 신고 저장 재시도 중 — 배너의 버튼을 잠그는 데만 쓴다
        public var reportRetrying: Bool
        public var showCallConfirm: Bool // 다이얼 복귀 후 통화 여부 다이얼로그
        public var confirmSaving: Bool
        public var confirmError: String? // call-result 저장 실패 안내 (재선택 가능)
        /// 통화 여부를 **아직 못 보냈고, 다이얼로그는 닫아 둔** 상태(「나중에」).
        ///
        /// 통화 여부는 운영팀 참고값이라 저장이 안 된다고 사용자를 잡아 둘 이유가 없다 — 예전에는
        /// 네트워크가 없으면 두 버튼이 둘 다 실패하고 다이얼로그가 back·바깥 탭 둘 다 막아서,
        /// 운행 중 화면·채팅으로 **돌아갈 길이 전혀 없었다**(실기 QA). 닫아 둔 뒤에도 사실은 남겨
        /// 두고(배너 + 「다시 선택」) 다시 고를 수 있게 한다.
        public var callConfirmPending: Bool
        public var done: Bool // call-result 저장 완료 → 26 복귀

        public init(
            dialLaunched: Bool = false,
            reportSaveFailed: Bool = false,
            reportRetrying: Bool = false,
            showCallConfirm: Bool = false,
            confirmSaving: Bool = false,
            confirmError: String? = nil,
            callConfirmPending: Bool = false,
            done: Bool = false
        ) {
            self.dialLaunched = dialLaunched
            self.reportSaveFailed = reportSaveFailed
            self.reportRetrying = reportRetrying
            self.showCallConfirm = showCallConfirm
            self.confirmSaving = confirmSaving
            self.confirmError = confirmError
            self.callConfirmPending = callConfirmPending
            self.done = done
        }
    }

    public private(set) var uiState = UiState()

    @ObservationIgnored private let repository: any RideRepository
    @ObservationIgnored private let partyId: Int64?
    @ObservationIgnored private let scope = ViewModelScope()

    public init(repository: any RideRepository, partyId: Int64?) {
        self.repository = repository
        self.partyId = partyId
    }

    /// 3초 홀드 완료 — 신고 저장을 발사한다. 실패해도 다이얼은 이미 열리므로 **통화를 막지 않고**
    /// `UiState.reportSaveFailed` 만 세운다. 그 플래그는 화면의 배너가 읽는다.
    public func onEmergencyHold() {
        if uiState.dialLaunched { return }
        uiState.dialLaunched = true
        let repository = self.repository
        let partyId = self.partyId
        scope.launch { [weak self] in
            do {
                _ = try await repository.reportEmergency(partyId: partyId)
            } catch {
                self?.uiState.reportSaveFailed = true
            }
        }
    }

    /// 운영팀 전달(신고 저장) **재시도**. 통화와 무관하게 언제든 누를 수 있다 —
    /// 지하 주차장·터널을 벗어난 뒤 한 번 더 보내는 게 이 버튼의 쓸모다.
    public func retryReport() {
        if uiState.reportRetrying || !uiState.reportSaveFailed { return }
        uiState.reportRetrying = true
        let repository = self.repository
        let partyId = self.partyId
        scope.launch { [weak self] in
            do {
                _ = try await repository.reportEmergency(partyId: partyId)
                self?.uiState.reportRetrying = false
                self?.uiState.reportSaveFailed = false
            } catch {
                self?.uiState.reportRetrying = false
                self?.uiState.reportSaveFailed = true
            }
        }
    }

    /// 다이얼에서 앱 복귀(scenePhase `.active`) — 홀드 이후라면 통화 여부 다이얼로그를 띄운다.
    ///
    /// 「나중에」로 닫아 둔 뒤(`UiState.callConfirmPending`)에는 **다시 띄우지 않는다** — 복귀마다
    /// 되살아나면 닫을 길을 만든 의미가 없다(앱을 전환할 때마다 같은 자리에 갇힌다).
    /// 다시 고르는 길은 화면의 「다시 선택」이다(`reopenCallConfirm`).
    public func onResumedFromDial() {
        let current = uiState
        if current.dialLaunched && !current.done && !current.showCallConfirm && !current.callConfirmPending {
            uiState.showCallConfirm = true
        }
    }

    /// 「나중에」 — 통화 여부를 **보류**하고 다이얼로그를 닫는다. 저장 중에는 무시한다(응답을 기다린다).
    /// 성공 경로는 건드리지 않는다 — 저장이 되면 `UiState.done` 으로 26 에 돌아간다.
    ///
    /// `UiState.confirmError` 는 **지우지 않는다.** 그 값이 다이얼로그의 탈출구를 여는 조건이라,
    /// 지워 버리면 「다시 선택」으로 열었을 때 다시 갇힌다(한 번 더 실패해야 탈출구가 돌아온다).
    public func dismissCallConfirm() {
        if uiState.confirmSaving { return }
        uiState.showCallConfirm = false
        uiState.callConfirmPending = true
    }

    /// 보류해 둔 통화 여부를 다시 고른다 — 화면 배너의 「다시 선택」
    public func reopenCallConfirm() {
        if uiState.done { return }
        uiState.showCallConfirm = true
        uiState.callConfirmPending = false
    }

    /// 「통화했어요」/「통화 안 했어요」 선택 — 저장 성공 시 done, 실패 시 안내 후 재선택
    public func onCallConfirm(called: Bool) {
        if uiState.confirmSaving { return }
        // 태스크를 띄우기 전에 세운다. Swift 태스크는 다음 차례에 돌아, 안에서 세우면 연타가 위 검사를 지나간다.
        uiState.confirmSaving = true
        uiState.confirmError = nil
        let repository = self.repository
        scope.launch { [weak self] in
            do {
                try await repository.confirmEmergencyCall(called: called)
                self?.uiState.confirmSaving = false
                self?.uiState.showCallConfirm = false
                self?.uiState.callConfirmPending = false
                self?.uiState.confirmError = nil
                self?.uiState.done = true
            } catch {
                self?.uiState.confirmSaving = false
                self?.uiState.confirmError = "통화 여부 저장에 실패했어요. 다시 선택해 주세요"
            }
        }
    }
}

/// 27 · 긴급 신고 진입점 — 서버 연동(신고 저장 + 통화 여부)
///
/// 이동:
/// - 뒤로(X) → 26 운행 중 (onBack)
/// - 3초 홀드 완료 → 신고 저장 발사 + 즉시 112 다이얼(`tel:112` — 발신은 사용자)
/// - 다이얼 복귀 → 통화 여부 다이얼로그 → 저장 성공 시 26 복귀 (onReportSubmitted)
public struct EmergencyRoute: View {
    @HostedViewModel private var viewModel: EmergencyViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private let rideSummary: String?
    private let onBack: () -> Void
    private let onReportSubmitted: () -> Void

    /// - Parameters:
    ///   - rideSummary: 「지금 타고 있는 차」 카드에 보일 「출발지 → 목적지」. nil 이면 카드를 숨긴다(진행 중 운행을 모를 때).
    ///     번호판은 모델에 없어 넣지 않는다.
    public init(
        repository: any RideRepository,
        partyId: Int64?,
        rideSummary: String? = nil,
        onBack: @escaping () -> Void = {},
        onReportSubmitted: @escaping () -> Void = {}
    ) {
        _viewModel = HostedViewModel(wrappedValue: EmergencyViewModel(repository: repository, partyId: partyId))
        self.rideSummary = rideSummary
        self.onBack = onBack
        self.onReportSubmitted = onReportSubmitted
    }

    public var body: some View {
        let viewModel = self.viewModel
        let state = viewModel.uiState
        ZStack {
            EmergencyScreen(
                rideSummary: rideSummary,
                dialLaunched: state.dialLaunched,
                // 운영팀 전달 실패·통화 여부 보류는 **숨기지 않고** 비차단 배너로 알린다 (통화는 막지 않는다)
                reportSaveFailed: state.reportSaveFailed,
                reportRetrying: state.reportRetrying,
                callConfirmPending: state.callConfirmPending,
                onRetryReport: { viewModel.retryReport() },
                onReopenCallConfirm: { viewModel.reopenCallConfirm() },
                onBack: onBack,
                onHoldCompleted: {
                    // ①신고 저장 발사 (실패해도 통화는 계속) ②즉시 112 다이얼 — 통화가 최우선
                    viewModel.onEmergencyHold()
                    openURL(EMERGENCY_DIAL_URL)
                }
            )

            if state.showCallConfirm {
                CallConfirmDialog(
                    saving: state.confirmSaving,
                    errorText: state.confirmError,
                    onCalled: { viewModel.onCallConfirm(called: true) },
                    onNotCalled: { viewModel.onCallConfirm(called: false) },
                    onLater: { viewModel.dismissCallConfirm() }
                )
            }
        }
        // 112 다이얼에서 앱 복귀 감지 — 홀드 이후 첫 복귀에 통화 여부 다이얼로그.
        //
        // `lifecycleEffect` 를 쓰지 않는 이유: 그쪽은 `.inactive` 를 전면으로 본다(원본 STARTED).
        // `tel:` 의 시스템 확인창·통화 화면에서 돌아오는 건 `.inactive → .active` 라 그 경계로는 잡히지 않는다.
        // 여기서 필요한 건 원본 ON_RESUME 이고, 그 자리가 `.active` 다.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.onResumedFromDial() }
        }
        // call-result 저장 완료 → 26 운행 중 복귀
        .task(id: state.done) {
            if state.done { onReportSubmitted() }
        }
    }
}

/// 신고 버튼 위 손가락의 상태. 원본 `detectTapGestures` 의 판정을 값으로 옮겼다.
enum EmergencyHoldPress: Equatable, Sendable {
    /// 누르고 있지 않다
    case idle
    /// 버튼 안에서 누르고 있다 — 시간이 흐른다
    case pressing
    /// 누른 채로 버튼 밖으로 나갔다. **손을 뗄 때까지 다시 시작하지 않는다**
    /// (원본 `waitForUpOrCancellation` 이 밖으로 나가면 취소하고, 다음 `awaitFirstDown` 은 손을 뗀 뒤다)
    case abandoned
}

/// 손가락이 움직일 때의 다음 상태. 3초 유지 실패(중도 이탈) 시 미전송 — 오작동 방지.
func nextEmergencyHoldPress(current: EmergencyHoldPress, location: CGPoint, size: CGSize) -> EmergencyHoldPress {
    if current == .abandoned { return .abandoned }
    let inside = location.x >= 0 && location.x <= size.width && location.y >= 0 && location.y <= size.height
    return inside ? .pressing : .abandoned
}

/// 27 · 긴급 신고 [S17] — 순수 UI
///
/// - 뒤로(X) → 26 운행 중 (onBack)
/// - 「3초간 길게 눌러 신고」 3초 유지 성공 → onHoldCompleted (신고 발사 + 112 다이얼)
///   · 3초 롱프레스 유지 실패 시 미전송 (오작동 방지)
/// - 사유 선택 없음 — 서버가 사유를 받지 않는다 (partyId/위치만 전송)
/// - 「지금 타고 있는 차」 카드는 `rideSummary` 가 있을 때만 보인다(번호판 표기 없음)
/// - `reportSaveFailed`·`callConfirmPending` 이면 상단에 **비차단 배너**가 뜬다 — 통화는 막지 않는다
///
/// Safety500/600 색상은 이 화면(신고) 전용.
public struct EmergencyScreen: View {
    private let rideSummary: String?
    private let dialLaunched: Bool
    private let reportSaveFailed: Bool
    private let reportRetrying: Bool
    private let callConfirmPending: Bool
    private let onRetryReport: () -> Void
    private let onReopenCallConfirm: () -> Void
    private let onBack: () -> Void
    private let onHoldCompleted: () -> Void

    @State private var holding = false
    @State private var holdButtonSize = CGSize.zero
    // 시간이 다 찼다는 표시. 콜백을 태스크에서 바로 부르지 않고 이 값의 변화로 부른다 —
    // 태스크는 **누른 순간**의 뷰를 잡고 있어 3초 뒤의 콜백이 아닐 수 있다(원본 `rememberUpdatedState` 자리).
    @State private var holdCompletedCount = 0
    // 손을 떼거나 **시스템이 제스처를 끊으면**(전화 수신·알림 센터) 저절로 `.idle` 로 돌아간다.
    // `onEnded` 는 시스템 취소에 불리지 않아, 거기에 맡기면 손을 뗐는데도 3초 뒤 신고가 발사된다.
    @GestureState private var holdPress = EmergencyHoldPress.idle

    /// - Parameters:
    ///   - reportSaveFailed: 운영팀 전달(신고 저장)이 실패했다. 화면 상단이 「현재 위치와 운행 정보가 운영팀에 전달되고」라고
    ///     약속하므로 **이 실패를 숨기면 거짓말이 된다** — 지하 주차장·터널에서 실제로 일어난다.
    ///   - callConfirmPending: 통화 여부를 「나중에」로 보류했다 — 다시 고를 수 있게 안내만 남긴다
    public init(
        rideSummary: String? = nil,
        dialLaunched: Bool = false,
        reportSaveFailed: Bool = false,
        reportRetrying: Bool = false,
        callConfirmPending: Bool = false,
        onRetryReport: @escaping () -> Void = {},
        onReopenCallConfirm: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onHoldCompleted: @escaping () -> Void = {}
    ) {
        self.rideSummary = rideSummary
        self.dialLaunched = dialLaunched
        self.reportSaveFailed = reportSaveFailed
        self.reportRetrying = reportRetrying
        self.callConfirmPending = callConfirmPending
        self.onRetryReport = onRetryReport
        self.onReopenCallConfirm = onReopenCallConfirm
        self.onBack = onBack
        self.onHoldCompleted = onHoldCompleted
    }

    // 다이얼 발사 후에는 중복 홀드 방지
    private var holdEnabled: Bool { !dialLaunched }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBarSpacer()
            // 닫기(X) → 26 운행 중
            Button(action: onBack) {
                CloseIcon()
                    .frame(width: 28, height: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NoIndicationStyle())
            .padding(.leading, 24)
            .padding(.top, 14)

            ScrollView {
                scrollContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 하단 고정: 안내 + 신고 버튼 + 푸터
            VStack(spacing: 0) {
                Text("3초를 채우면 즉시 112 통화 화면이 열려요")
                    .moyeotaText(bodyLargeText(12, .medium), color: EmAshGray)
                Spacer().frame(height: 10)
                holdButton
                Spacer().frame(height: 14)
                Text("허위 신고 시 이용이 제한될 수 있어요")
                    // 11 은 표(`hangulTrackingExtra`)에 없다(시각·날짜 크기). 이 줄은 한글뿐이라 따로 맞춘다.
                    .moyeotaText(bodyLargeText(11, .regular).copy(letterSpacing: 0.62), color: EmAshGray)
                Spacer().frame(height: 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            // 홈 인디케이터 목업 대신 실제 제스처 인셋 여백
            NavigationBarSpacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(EmergencyBg)
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 14)
            Text("괜찮으세요?")
                .moyeotaText(bodyLargeText(26, .bold), color: MoyeotaColor.InkPrimary)
            Spacer().frame(height: 10)
            Text("신고하면 현재 위치와 운행 정보가 운영팀에 전달되고,\n바로 112 통화 화면으로 연결돼요")
                .moyeotaText(bodyLargeText(14, .regular), color: EmTextMute)

            // 운영팀 전달 실패 — **이 실패가 통화를 막지 않는다**는 것만 말한다. 이 배너 때문에
            // 사용자가 통화를 멈추면 더 나쁘다. 재시도는 터널·지하를 벗어난 뒤를 위한 길이다.
            //
            // 「112 통화는 정상 진행됩니다」라고 **단정하지 않는다.** 앱은 통화 여부를 모른다 —
            // `tel:` 로 시스템 발신 확인을 열 뿐 발신은 사용자가 하고, 이 화면은 돌아온 뒤에
            // 「112와 실제로 통화하셨나요?」라고 되묻는다. 모른다고 적어 둔 값을 배너가
            // 「정상 진행」으로 말하면, 통화가 안 된 사용자에게 됐다고 알리는 꼴이다.
            if reportSaveFailed {
                Spacer().frame(height: 18)
                EmergencyNotice(
                    text: "운영팀에 전달하지 못했어요. 112 통화에는 지장이 없어요\n통신이 되는 곳에서 다시 시도해 주세요",
                    actionLabel: reportRetrying ? "보내는 중…" : "다시 시도",
                    actionEnabled: !reportRetrying,
                    onAction: onRetryReport
                )
            }

            // 통화 여부를 「나중에」로 닫아 둔 상태 — 사실은 남기고 다시 고를 길을 준다
            if callConfirmPending {
                Spacer().frame(height: 18)
                EmergencyNotice(
                    text: "통화 여부를 아직 보내지 못했어요. 운영팀 참고용이라 안 보내도 괜찮아요",
                    actionLabel: "다시 선택",
                    actionEnabled: true,
                    onAction: onReopenCallConfirm
                )
            }

            if let rideSummary {
                Spacer().frame(height: 22)
                // 지금 타고 있는 차 카드 — 운행 정보를 모르면 숨긴다
                rideCard(rideSummary)
            }
            Spacer().frame(height: 16)
        }
    }

    private func rideCard(_ rideSummary: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .circular)
        return VStack(alignment: .leading, spacing: 0) {
            Text("지금 타고 있는 차")
                .moyeotaText(bodyLargeText(12, .medium), color: EmMuteGray)
            Spacer().frame(height: 4)
            Text(rideSummary)
                .moyeotaText(bodyLargeText(15, .bold), color: MoyeotaColor.InkPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoyeotaColor.SurfaceCanvas)
        .clipShape(shape)
        .moyeotaShadow(elevation: 4, shape: shape, spotColor: EmCardShadow)
    }

    // 3초 롱프레스 신고 버튼 — Safety500 (이 화면 전용)
    private var holdButton: some View {
        let background: Color = if !holdEnabled {
            MoyeotaColor.SurfaceSoft
        } else if holding {
            MoyeotaColor.Safety600
        } else {
            MoyeotaColor.Safety500
        }
        let label = if !holdEnabled {
            "112 통화 화면으로 연결했어요"
        } else if holding {
            "계속 누르고 계세요…"
        } else {
            "3초간 길게 눌러 신고"
        }
        let size = holdButtonSize
        let holdRunning = holdPress == .pressing && holdEnabled
        let gesture = DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($holdPress) { value, press, _ in
                press = nextEmergencyHoldPress(current: press, location: value.location, size: size)
            }
        return Text(label)
            .moyeotaText(
                bodyLargeText(17, .bold),
                color: holdEnabled ? MoyeotaColor.TextOnDark : MoyeotaColor.TextAsh
            )
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .circular))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .circular))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { holdButtonSize = $0 }
            .gesture(gesture, including: holdEnabled ? .all : .subviews)
            // 3초 유지 실패(중도 해제) 시 미전송 — 값이 바뀌는 순간 진행 중인 대기가 취소된다.
            // 화면을 떠나도 함께 취소된다.
            .task(id: holdRunning) {
                guard holdRunning else {
                    holding = false
                    return
                }
                holding = true
                do {
                    try await Task.sleep(for: .milliseconds(EMERGENCY_HOLD_MS))
                } catch {
                    return
                }
                holding = false
                holdCompletedCount += 1
            }
            .onChange(of: holdCompletedCount) { _, _ in
                onHoldCompleted() // 신고 발사 + 112 다이얼
            }
    }
}

/// 비차단 안내 배너 — 신고 저장 실패·통화 여부 보류를 **감추지 않고** 알린다.
///
/// 다이얼로그가 아니라 배너인 게 요점이다: 이 화면의 본업(112 통화)을 한 순간도 막지 않는다.
/// 문구는 「무슨 일이 일어났고 / 통화는 어떻게 되는지 / 사용자가 할 수 있는 일」 순서로 적는다.
private struct EmergencyNotice: View {
    let text: String
    let actionLabel: String
    let actionEnabled: Bool
    let onAction: () -> Void

    var body: some View {
        let buttonShape = RoundedRectangle(cornerRadius: 10, style: .circular)
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .moyeotaText(bodyLargeText(13, .medium), color: MoyeotaColor.Danger600)
            Spacer().frame(height: 10)
            Button(action: onAction) {
                Text(actionLabel)
                    .moyeotaText(
                        bodyLargeText(13, .bold),
                        color: actionEnabled ? MoyeotaColor.Danger600 : MoyeotaColor.TextAsh
                    )
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(actionEnabled ? MoyeotaColor.SurfaceCanvas : MoyeotaColor.SurfaceSoft, in: buttonShape)
            }
            .buttonStyle(PressOverlayStyle(shape: buttonShape))
            .disabled(!actionEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MoyeotaColor.Danger50, in: RoundedRectangle(cornerRadius: 14, style: .circular))
    }
}

/// "112와 실제로 통화하셨나요?" — 다이얼 복귀 후 통화 여부 확인.
///
/// 성공 경로는 예전과 같다: 둘 중 하나를 고르고 저장이 되면 26 으로 복귀한다. 바깥 탭으로는 여전히
/// 닫히지 않는다 — 실수로 흘려 보내지 않게.
///
/// **저장이 실패한 뒤에는 탈출구를 연다**(`errorText` != nil → back 허용 + 「나중에」).
/// 예전에는 네트워크가 없으면 두 버튼이 둘 다 실패해 `done` 이 서지 않고, back·바깥 탭·X 버튼(이
/// 다이얼로그에 가려진다)이 전부 막혀 **운행 중 화면·채팅으로 돌아갈 길이 없었다**(실기 QA).
/// 통화 여부는 운영팀 참고값이라 그걸로 사용자를 잡아 둘 근거가 없다 — 보류해 두고 배너로 남긴다.
/// 통화 여부 다이얼로그 카드의 폭. 값의 근거는 `CallConfirmDialog.body` 주석.
let CallConfirmDialogWidth: CGFloat = 320

struct CallConfirmDialog: View {
    let saving: Bool
    let errorText: String?
    let onCalled: () -> Void
    let onNotCalled: () -> Void
    let onLater: () -> Void

    // 저장이 한 번이라도 실패한 뒤에만 열어 준다. 저장 중에는 응답을 기다린다(연타 방지).
    private var escapable: Bool { errorText != nil && !saving }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .circular)
        let buttonShape = RoundedRectangle(cornerRadius: 14, style: .circular)
        ZStack {
            // 안드로이드 대화상자 창의 기본 어둡기(0.6)다. 바깥 탭은 계속 막는다 —
            // 실패했다고 실수로 흘려 보낼 길까지 열 이유는 없다.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

            // 원본 `Dialog` 의 기본 폭은 화면 411.4dp·401.9dp 에서 모두 320dp 다(렌더에서 잼). 내용은 `fillMaxWidth` 라
            // 그 폭을 다 쓴다. 창은 시스템 바를 뺀 영역의 가운데에 놓이므로 이 오버레이는 두 바의 높이를 직접 뺀다.
            VStack(spacing: 0) {
                StatusBarSpacer()
                card(shape: shape, buttonShape: buttonShape)
                    .frame(width: CallConfirmDialogWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NavigationBarSpacer()
            }
        }
        .ignoresSafeArea(.keyboard)
        // 뒤로가기는 `escapable` 일 때만 닫는다. 아니면 먹고 끝낸다(원본 `dismissOnBackPress = false`).
        // 핸들러는 켜질 때의 동작을 들고 있어 하나로 두면 분기가 낡는다 — 켜고 끄는 둘로 나눈다.
        .moyeotaBackHandler(enabled: !escapable) {}
        .moyeotaBackHandler(enabled: escapable, action: onLater)
    }

    private func card(shape: RoundedRectangle, buttonShape: RoundedRectangle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("112와 실제로 통화하셨나요?")
                .moyeotaText(bodyLargeText(18, .bold), color: MoyeotaColor.InkPrimary)
            Spacer().frame(height: 8)
            Text("실제 통화 여부는 운영팀 대응에 사용돼요")
                .moyeotaText(bodyLargeText(13, .regular), color: EmTextMute)
            if let errorText {
                Spacer().frame(height: 10)
                Text(errorText)
                    .moyeotaText(bodyLargeText(12, .medium), color: MoyeotaColor.Safety500)
            }
            Spacer().frame(height: 20)
            HStack(spacing: 10) {
                // 「통화 안 했어요」 — 보조
                Button(action: onNotCalled) {
                    Text("통화 안 했어요")
                        .moyeotaText(
                            bodyLargeText(15, .bold),
                            color: saving ? MoyeotaColor.TextAsh : MoyeotaColor.InkPrimary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(MoyeotaColor.SurfaceSoft, in: buttonShape)
                }
                .buttonStyle(PressOverlayStyle(shape: buttonShape))
                .disabled(saving)

                // 「통화했어요」 — 주 액션 (Safety500 — 신고 화면 전용색)
                Button(action: onCalled) {
                    Text(saving ? "저장 중…" : "통화했어요")
                        .moyeotaText(
                            bodyLargeText(15, .bold),
                            color: saving ? MoyeotaColor.TextAsh : MoyeotaColor.TextOnDark
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(saving ? MoyeotaColor.SurfaceSoft : MoyeotaColor.Safety500, in: buttonShape)
                }
                .buttonStyle(PressOverlayStyle(shape: buttonShape))
                .disabled(saving)
            }
            // 저장이 실패한 뒤의 탈출구. 성공 경로에는 나타나지 않는다 — 평상시엔 둘 중 하나를 고르는 게 맞다.
            if escapable {
                Spacer().frame(height: 14)
                Button(action: onLater) {
                    Text("나중에 하기")
                        .moyeotaText(bodyLargeText(14, .bold), color: EmTextMute)
                }
                .buttonStyle(NoIndicationStyle())
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .background(MoyeotaColor.SurfaceCanvas, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// ─── 아이콘 (material-icons 미사용 — Canvas 직접 드로잉) ─────────────────────

private struct CloseIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            path.move(to: CGPoint(x: w * 0.18, y: h * 0.18))
            path.addLine(to: CGPoint(x: w * 0.82, y: h * 0.82))
            path.move(to: CGPoint(x: w * 0.82, y: h * 0.18))
            path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.82))
            context.stroke(
                path,
                with: .color(MoyeotaColor.InkPrimary),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
        }
        .frame(width: 24, height: 24)
    }
}
