import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import os
import PresentationCore
import SwiftUI

/// 배차 폴링 간격 — **7초**. 지도 마커 갱신 주기이자 **탑승 시작(IN_RIDE) 감지 지연**이다
/// (기사가 board 를 누른 뒤 최악의 경우 이만큼 기다렸다 26 으로 넘어간다).
///
/// 옛 5초에서 늘렸다. 매 주기 읽는 대상이 쿼리 1개짜리 상태 조회에서 **쿼리 3개짜리 방 상세**로
/// 바뀌었기 때문이다 — 서버가 `/status` 를 삭제했다(`04f6be7`). 5초를 그대로 두면 쿼리 부하가
/// 0.20 → 0.60 q/s 로 3배가 된다. 7초면 0.43 q/s 다.
///
/// 26 운행 중(8초)보다 **짧게** 두는 이유: 기사 위치 조회가 같은 루프에 얹혀 있어 이 값이 곧
/// 마커 갱신 주기다. 40km/h 로 오는 택시가 한 걸음에 약 78m 를 뛴다 — 더 벌리면 마커가 튄다.
/// 근거와 부하 표는 `PARTY_DETAIL_POLL_FLOOR_MS` 주석에 있다.
let DRIVER_POLL_INTERVAL_MS: Int64 = 7_000

private let logger = Logger(subsystem: "com.moyeota.presentation", category: "DispatchStatus")

@MainActor
@Observable
public final class DispatchStatusViewModel {
    public enum UiState: Equatable, Sendable {
        case loading
        case success(ride: Ride)
        case error(message: String)
    }

    public private(set) var uiState: UiState = .loading

    // 기사 정보·위치는 UiState 와 분리한다. 둘 다 "아직 없음"이 정상 상황이라
    // 실패가 화면 전체를 에러로 덮으면 안 된다 (01 보고서 7절).
    public private(set) var driver: AssignedDriver?

    public private(set) var driverLocation: DriverLocation?

    // 기사측 탑승 처리(IN_RIDE) 감지. 26 운행 중의 finished 와 같은 모양의 1회성 신호다 —
    // UiState 에 섞으면 화면 렌더와 네비게이션이 한 값에 묶여, 폴링 실패가 전이까지 막는다.
    public private(set) var rideStarted = false

    @ObservationIgnored private let rideRepository: any RideRepository
    @ObservationIgnored private let dispatchRepository: any DispatchRepository
    @ObservationIgnored private let partyId: Int64
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()

    /// 화면이 지금 **보이는가** — 배차 폴링의 스위치다(`shouldPollDispatch`).
    ///
    /// **뷰가 살아 있는 것만으로는 부족하다.** 원본의 이 루프는 Route 의 `LaunchedEffect` 스코프에서 돌았는데,
    /// `LaunchedEffect` 는 컴포지션 이탈에만 취소되고 **앱 백그라운드**에는 반응하지 않았다. 그래서 주머니 속에서도
    /// 7초마다 **호출 2건**(`GET /matching/rooms/{id}` + `GET /dispatch/rides/{id}`) = 분당 약 17건이 나갔다.
    /// SwiftUI `.task` 도 같다 — 앱을 내려놓아도 화면이 사라진 것이 아니라 취소되지 않는다.
    ///
    /// 21 대기(`MatchWaitingViewModel.visible`)·17 탐색·24 채팅방이 모두 같은 게이트를 쓰고 **25 만
    /// 빠져 있었다** — QA 123 D-3 으로 21 을 고칠 때 같이 고쳐지지 않은 자리다.
    ///
    /// ### 끊어도 안전한 근거
    /// 이 화면의 갱신 수단은 **폴링 하나**고 상태를 쌓지 않는다 — 매 주기 방 상세를 **통째로** 받아
    /// 교체하므로(그래서 멱등하다) 가려진 동안 건너뛴 주기를 따라잡을 필요가 없다. 복귀하면 그 패스가
    /// **곧바로 한 번 읽는다**(대기가 루프 끝에 있다) — 그래서 탑승 시작(IN_RIDE) 전이를 놓치지
    /// 않는다. 가려진 동안의 전이는 어차피 알려 봐야 띄울 화면이 없다.
    ///
    /// ### 기본값이 true 인 이유
    /// 이 값을 내려 주는 배선(`onScreenStart`·`onScreenStop`)은 Route 에 있다. 기본값을 false 로 두면
    /// 배선이 빠진 채 머지됐을 때 **배차가 영영 갱신되지 않는** 기능 손실이 된다 — true 면 최악이
    /// 「고쳐지지 않은 상태 유지」다(21·`ActivePartyViewModel` 이 같은 이유로 true 다).
    @ObservationIgnored private let visible = MutableStateFlow(true)

    /// 폴링이 **제 할 일을 끝냈다** — 탑승 시작을 잡아 26 운행 중으로 넘긴다.
    ///
    /// 가시성은 「멈췄다 다시 켜는」 스위치지만 이 값은 「끝났다」는 사실이라 복귀로 되돌아가지 않는다
    /// (21 의 `fallbackDone` 과 같은 자리·같은 이유). 게이트를 넣었다고 끝난 루프가 되살아나면 회귀다.
    @ObservationIgnored private var pollDone = false

    public init(
        rideRepository: any RideRepository,
        dispatchRepository: any DispatchRepository,
        partyId: Int64,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.rideRepository = rideRepository
        self.dispatchRepository = dispatchRepository
        self.partyId = partyId
        self.sleep = sleep
        refresh()
    }

    /// 화면이 보이기 시작했다 — 폴링을 재개하고 **즉시 한 주기**를 돈다(대기가 루프 끝에 있다).
    ///
    /// 이 길로 오는 것: 첫 진입, 앱 복귀, 위에 올라와 있던 화면(24 채팅방)의 pop.
    public func onScreenStart() {
        visible.value = true
    }

    /// 화면이 가려졌다 — 폴링을 멈춘다. 들고 있던 배차 상태는 **건드리지 않는다**: 돌아올 때 보던
    /// 화면을 먼저 보여주고 다음 주기로 덮는 것이 맞고, 로딩으로 깜빡이게 할 이유가 없다.
    ///
    /// 이 길로 오는 것: 앱 백그라운드, 위에 다른 화면이 올라옴.
    public func onScreenStop() {
        visible.value = false
    }

    public func refresh() {
        uiState = .loading
        let repository = rideRepository
        let partyId = self.partyId
        scope.launch { [weak self] in
            do {
                let ride = try await repository.getPartyDetail(partyId: partyId)
                // 기사 조회 왕복 동안에도 뷰모델을 잡지 않는다. `loadDriverIfAssigned` 를 부르면 호출 내내 `self` 가
                // 살아 있어, 화면을 떠나도 해제되지 않고 스코프 취소도 오지 않는다(원본 `viewModelScope` 는 이때 끊는다).
                guard let alreadyLoaded = self.map({ $0.driver != nil }) else { return }
                if shouldFetchDriverInfo(ride: ride, alreadyLoaded: alreadyLoaded),
                   let loaded = try? await repository.getAssignedDriver(partyId: partyId),
                   !Task.isCancelled {
                    self?.driver = loaded
                }
                self?.markStartedIfInRide(ride: ride)
                self?.uiState = .success(ride: ride)
            } catch {
                self?.uiState = .error(message: "배차 정보를 불러오지 못했어요")
            }
        }
    }

    /// 방 상세·기사 정보·기사 위치 폴링. **호출자(Route)의 태스크에서 돌린다** —
    /// `.task` 가 화면이 사라질 때 이 함수를 취소해 폴링이 함께 멈춘다.
    ///
    /// **그 이탈만으로는 부족하다.** `.task` 는 앱이 백그라운드로 가도 취소되지 않는다 — 그래서 원본은 주머니
    /// 속에서도 7초마다 호출 2건, 분당 약 17건이 나갔다. 그래서 `visible` 로 한 번 더 막는다: `collectLatest` 가
    /// 가려지는 순간 **진행 중인 조회와 대기를 함께 취소**하고, 다시 보이면 같은 패스를 새로 시작한다(21 대기의
    /// `observeFallbackPolling`·17 탐색 `ExploreViewModel.observeRequests` 와 같은 모양).
    ///
    /// 복귀 첫 주기는 **즉시** 돈다 — 대기가 루프 **끝**에 있어, 패스가 다시 시작되면 방 상세를
    /// 그 자리에서 읽는다. 그래서 가려진 동안 일어난 탑승 시작(IN_RIDE)도 복귀와 거의 동시에 잡힌다.
    ///
    /// **동승 모드에서는 이 루프가 한 번도 돌지 않는다** — 서버가 `DISPATCHING` 을 내지 않아 25 에
    /// 닿을 길이 없다(`docs/MODE-ROUTES.md`). 택시 모드 전용이다.
    ///
    /// 매 주기 읽는 건 **방 상세**(`RideRepository.getPartyDetail`, 서버 쿼리 3개)다. 예전에는 가벼운
    /// 상태 조회(`/status`, 쿼리 1개)를 읽고 지문이 달라진 주기에만 상세를 읽었지만, 그 엔드포인트와
    /// 지문이 백엔드에서 사라졌다(`04f6be7`). 그래서 **「안 바뀌었으면 상세 재조회 생략」은 원리적으로
    /// 불가능하다** — 바뀌었는지 알려면 상세를 받아야 한다. 대신 두 가지로 비용을 눌렀다:
    /// 1. 간격을 5초 → `DRIVER_POLL_INTERVAL_MS`(7초)로 늘렸다.
    /// 2. 받은 상세가 들고 있던 것과 같으면 **화면 상태를 갱신하지 않는다**(`shouldPublishDetail`) —
    ///    7초마다 지도·기사 카드가 다시 그려지지 않게.
    ///
    /// 수단을 바꾸면서 **옛 예외 조건 하나가 통째로 없어졌다**: 지문이 없는 서버에서는 요약만으로
    /// `MATCHING`(기사 찾는 중)과 `DRIVER_ASSIGNED`(배정 완료)를 가를 수 없어(앱에서는 둘 다
    /// `RideStatus.dispatching`, 인원도 같다) 「미배정인 동안에는 매 주기 상세를 읽는다」는 단서가
    /// 붙어 있었다. 이제는 매 주기가 상세라 `Ride.driverId` 가 그 자리에서 들어온다.
    ///
    /// 기사 **정보** 조회는 이미 받아온 뒤 건너뛴다 — 그 값은 배차 동안 바뀌지 않는다.
    /// 기사 **위치**(`GET /dispatch/rides/{id}`)는 방 상세가 아닌 별도 API 라 매 주기 묻는다
    /// — 택시가 오는 동안 마커가 움직여야 한다. 그래서 이 간격이 마커 갱신 주기도 된다.
    ///
    /// 조회 실패(네트워크·기사 미배정·위치 미보고)는 삼키고 **들고 있던 값을 유지한 채** 다음 주기를
    /// 기다린다 — 한 번의 실패로 화면이 깜빡이거나 에러로 덮이면 안 된다.
    public func pollDriver() async {
        await collectLatest(visible.values()) { [weak self] shown in
            await self?.pollPass(shown: shown)
        }
    }

    /// 가시성 값 하나에 대응하는 패스. 다음 값이 오면 `collectLatest` 가 취소한다.
    private func pollPass(shown: Bool) async {
        if !shouldPollDispatch(visible: shown, pollDone: pollDone) { return }
        logger.debug("배차 폴링 시작 partyId=\(self.partyId)")
        defer { logger.debug("배차 폴링 중단 partyId=\(self.partyId)") }
        while !Task.isCancelled {
            let held: Ride? = if case .success(let ride) = uiState { ride } else { nil }
            // 실패하면(nil) 들고 있던 값으로 이 주기를 넘긴다 — 깜빡임도 에러 화면도 없다.
            let fetched = try? await rideRepository.getPartyDetail(partyId: partyId)
            // 원본 `runCatching` 도 취소를 삼키지만 곧바로 `delay` 가 던져 루프를 끝낸다. 여기서는 멈춘 패스가
            // 쓰지 못하게 먼저 나간다 — 복귀 패스가 곧바로 다시 읽으므로 이 응답을 버려도 잃는 것이 없다.
            if Task.isCancelled { return }
            if let fetched, shouldPublishDetail(held: held, fetched: fetched) {
                uiState = .success(ride: fetched)
            }
            // 전이 판정은 **이번 주기에 받은 값**으로만 한다 — 실패한 주기(nil)는 "아직 아니다"다.
            // 끝난 루프는 복귀로 되살아나지 않는다(pollDone) — 가시성은 스위치, 이건 종결이다.
            if markStartedIfInRide(ride: fetched) {
                pollDone = true
                return
            }
            // 기사 조회 게이트는 반대로 **마지막으로 아는 값**을 쓴다 — 한 주기 실패했다고 마커
            // 갱신을 멈추면 택시가 오는 동안 지도가 굳는다.
            let ride = fetched ?? held
            await loadDriverIfAssigned(ride: ride)
            // 기사 위치는 배정된 뒤에만 묻는다 — 배정 전 호출은 서버가 DRIVER_NOT_ASSIGNED 로 거절하며
            // 폴링 주기마다 서버 WARN 로그만 쌓는다. 조회 주체는 Bearer 토큰이 정한다(22 보고서 §2).
            if shouldFetchDriverLocation(ride: ride),
               let location = try? await dispatchRepository.getDriverLocation(partyId: partyId),
               !Task.isCancelled {
                driverLocation = location
            }
            do {
                try await sleep(.milliseconds(DRIVER_POLL_INTERVAL_MS))
            } catch {
                // 대기가 던지는 것은 취소뿐이다 — 패스를 끝낸다.
                return
            }
        }
    }

    // 기사 미배정(taxiDriverId == nil)이면 서버가 거절하므로, 배정된 뒤에만 호출한다.
    // 이미 받아온 뒤에는 다시 부르지 않는다 — 차량 정보는 배차 동안 바뀌지 않는다.
    private func loadDriverIfAssigned(ride: Ride?) async {
        if !shouldFetchDriverInfo(ride: ride, alreadyLoaded: driver != nil) { return }
        if let loaded = try? await rideRepository.getAssignedDriver(partyId: partyId), !Task.isCancelled {
            driver = loaded
        }
    }

    /// 탑승 시작(`isRideStarted`)을 감지하면 1회성 신호를 올리고 true 를 돌려줘 폴링을 끝낸다.
    /// 판정 자체는 순수 함수로 빼 두었다 — 폴링 루프와 테스트가 같은 규칙을 본다.
    @discardableResult
    private func markStartedIfInRide(ride: Ride?) -> Bool {
        if !isRideStarted(ride: ride) { return false }
        if !rideStarted { logger.debug("탑승 시작 감지 partyId=\(self.partyId) → 26 운행 중") }
        rideStarted = true
        return true
    }
}

/// 배차 단계 — 하나의 라우트가 서버 status 에 따라 세 화면을 갈아 끼운다.
///
/// | 서버 status | 화면 |
/// |---|---|
/// | `MATCHING` (기사 미배정) | 25b `DriverSearchScreen` — 레이더 |
/// | `CANCELED` (3분 타임아웃) | 25b-실패 `DriverSearchFailedScreen` |
/// | `DRIVER_ASSIGNED` 첫 감지 | 25c `DriverAssignedScreen` — 1회성 확인 |
/// | 그 이후 | 25 `DispatchStatusScreen` — 지도·기사 마커 |
///
/// 별도 네비게이션 목적지를 만들지 않는다. 단계는 **서버 상태의 함수**라, 뒤로가기로 되돌릴 수 있는
/// 스택으로 쌓으면 상태와 화면이 어긋난다(이미 배정됐는데 「찾는 중」으로 돌아가는 식).
///
/// MATCHING 과 DRIVER_ASSIGNED 는 도메인에서 둘 다 `RideStatus.dispatching` 이라
/// **`Ride.driverId` 유무로 가른다** — 배정되면 서버가 taxiDriverId 를 채운다.
///
/// 26 운행 중으로의 전이 신호는 **서버 status IN_RIDE**(기사측 board) **하나뿐**이다(`isRideStarted`).
/// `DispatchStatusScreen` 에는 `onStartRide` 를 부르는 수동 트리거가 없다 — 이 Route 의 폴링이 유일한 발화점이다.
/// partyId 가 없으면 조회할 방이 없어 오류 안내 후 되돌린다(20·21·22·23 과 같은 방식).
///
/// **이 화면은 택시 모드에서만 보인다** — 동승 모드 서버는 `DISPATCHING` 을 내지 않는다
/// (`docs/MODE-ROUTES.md`). 그래서 `DispatchStatusViewModel.pollDriver` 의 상세 폴링도 택시 모드에서만 돈다.
public struct DispatchStatusRoute: View {
    private let rideRepository: any RideRepository
    private let dispatchRepository: any DispatchRepository
    private let partyId: Int64?
    private let onStartRide: () -> Void
    private let onRetryMatching: () -> Void
    private let onBack: () -> Void
    private let onOpenChat: (() -> Void)?

    /// - Parameters:
    ///   - onRetryMatching: 매칭 실패 후 「다시 찾기」. 취소된 방은 되살릴 수 없어 홈으로 보낸다
    ///   - onOpenChat: 이 방의 채팅방을 여는 길. 채팅방이 아직 없으면 nil — 화면이 버튼을 그리지 않는다
    public init(
        rideRepository: any RideRepository,
        dispatchRepository: any DispatchRepository,
        partyId: Int64?,
        onStartRide: @escaping () -> Void = {},
        onRetryMatching: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {},
        onOpenChat: (() -> Void)? = nil
    ) {
        self.rideRepository = rideRepository
        self.dispatchRepository = dispatchRepository
        self.partyId = partyId
        self.onStartRide = onStartRide
        self.onRetryMatching = onRetryMatching
        self.onBack = onBack
        self.onOpenChat = onOpenChat
    }

    public var body: some View {
        // 방 id 없이 닿을 길은 없다(21 의 status 전이 · 홈 배너가 모두 id 를 넘긴다). 그래도 nil 이면
        // 예시 방을 그리는 대신 사실대로 말하고 되돌린다 — 20·22·23 과 같은 방식이다.
        //
        // 예전에는 여기서 `DispatchStatusScreen` 을 `ride` 없이 불러 **예시 방**(번호판도 없는 배차
        // 현황)을 그렸다. 21 과 같은 사고였다 — 구성 변경에 방 id 가 날아가면 진짜 배차를 기다리던
        // 사용자에게 남의 가짜 방이 떴다. 화면 쪽 `ride` 기본값도 함께 걷어내 그 길을 막았다.
        //
        // 되돌아갈 곳은 `onBack` — 이 단계에는 나가기가 없어(서버가 막는다) 호출자가 방을 그대로 둔 채
        // 홈으로만 보낸다. 홈 배너가 그 방으로 다시 들어갈 길이다.
        if let partyId {
            // `.id` 가 원본의 뷰모델 키(`dispatch-{partyId}`) 자리다 — 방이 바뀌면 뷰모델도 새로 만든다.
            DispatchStatusContent(
                rideRepository: rideRepository,
                dispatchRepository: dispatchRepository,
                partyId: partyId,
                onStartRide: onStartRide,
                onRetryMatching: onRetryMatching,
                onBack: onBack,
                onOpenChat: onOpenChat
            )
            .id(partyId)
        } else {
            BackStateScaffold(title: "배차 현황", onBack: onBack) {
                ErrorBox(
                    message: "어느 방의 배차인지 알 수 없어요. 홈에서 진행 중인 방으로 다시 들어가 주세요",
                    onRetry: onBack,
                    actionLabel: "홈으로 가기"
                )
            }
        }
    }
}

/// 방 id 를 아는 Route 본체. 뷰모델은 id 가 있어야 만들 수 있어 나눴다.
private struct DispatchStatusContent: View {
    @HostedViewModel private var viewModel: DispatchStatusViewModel

    // 내 현재 위치 — 25c·25 지도의 파란 점. 권한 다이얼로그는 새로 띄우지 않는다(배차 흐름을 끊지 않게,
    // 26 RideOngoingRoute 와 같은 이유). 15~19 에서 이미 허용한 사용자라면 점이 뜨고, 아니면 마커만 그린다.
    @RememberMyLocationState(autoRequestPermission: false) private var myLocation

    // 25c 를 이미 봤는가. 배정 확인은 **한 번이면 충분**하고, 매 재진입마다 다시 띄우면
    // 지도(25)로 가려는 사용자를 계속 가로막는다. 위에 24 채팅방이 올라와도 살아남고
    // 프로세스 재시작에는 사라진다 — 그때는 25 직행이 자연스럽다(이미 배정을 알고 있는 사용자다).
    @State private var assignedSeen = false

    private let onStartRide: () -> Void
    private let onRetryMatching: () -> Void
    private let onBack: () -> Void
    private let onOpenChat: (() -> Void)?

    init(
        rideRepository: any RideRepository,
        dispatchRepository: any DispatchRepository,
        partyId: Int64,
        onStartRide: @escaping () -> Void,
        onRetryMatching: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onOpenChat: (() -> Void)?
    ) {
        _viewModel = HostedViewModel(
            wrappedValue: DispatchStatusViewModel(
                rideRepository: rideRepository,
                dispatchRepository: dispatchRepository,
                partyId: partyId
            )
        )
        self.onStartRide = onStartRide
        self.onRetryMatching = onRetryMatching
        self.onBack = onBack
        self.onOpenChat = onOpenChat
    }

    var body: some View {
        let viewModel = self.viewModel
        let rideStarted = viewModel.rideStarted

        // 효과는 바뀌지 않는 바깥 컨테이너에 건다. 상태 분기(switch)마다 걸면 단계가 바뀔 때
        // 사라짐·나타남이 불려 폴링을 괜히 끊었다 다시 시작한다.
        ZStack {
            switch viewModel.uiState {
            case .loading:
                BackStateScaffold(title: "배차 준비 중", onBack: onBack) {
                    LoadingBox()
                }
            case .error(let message):
                BackStateScaffold(title: "배차 준비 중", onBack: onBack) {
                    ErrorBox(message: message, onRetry: { viewModel.refresh() })
                }
            case .success(let ride):
                stage(ride: ride, viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .myLocationEffect($myLocation)
        // 화면이 **보이는 동안만** 폴링한다. 두 겹이다:
        // ① `.task` — 화면이 사라지면(다른 화면으로 이동) 루프가 취소된다.
        // ② `lifecycleEffect` — **앱 백그라운드**를 잡는다. ①만으로는 부족하다: `.task` 는 앱을 내려놓아도
        //    취소되지 않아, 주머니 속에서 7초마다 호출 2건(방 상세 + 기사 위치) = 분당 약 17건이 계속 나간다.
        //    21 대기·17 탐색·24 채팅방은 이미 이 게이트를 쓰고 있었고 25 만 빠져 있었다(QA 123 D-3 을 고칠 때 놓친 자리).
        .lifecycleEffect(
            onStart: { viewModel.onScreenStart() },
            onStop: { viewModel.onScreenStop() }
        )
        .topEntryTask {
            await viewModel.pollDriver()
        }
        // 기사측 탑승 처리를 잡으면 26 운행 중으로 자동 전이한다 (26→33 의 onRideFinished 와 같은 모양)
        .task(id: rideStarted) {
            if rideStarted { onStartRide() }
        }
    }

    @ViewBuilder
    private func stage(ride: Ride, viewModel: DispatchStatusViewModel) -> some View {
        let assigned = ride.driverId != nil
        // 3분 타임아웃 — 서버가 방을 스스로 취소했다. 되살릴 방이 없어 재시도 = 새 방 만들기
        if ride.status == .canceled {
            DriverSearchFailedScreen(onRetry: onRetryMatching, onBack: onBack)
        } else if !assigned {
            DriverSearchScreen(ride: ride, onOpenChat: onOpenChat, onBack: onBack)
        } else if !assignedSeen {
            DriverAssignedScreen(
                ride: ride,
                driver: viewModel.driver,
                driverLocation: viewModel.driverLocation,
                myLocation: myLocation.coordinates,
                pickupEtaMinutes: pickupEtaMinutes(
                    distanceMeters: pickupDistanceMeters(ride: ride, location: viewModel.driverLocation)
                ),
                onSeeDispatch: { assignedSeen = true },
                onOpenChat: onOpenChat,
                onBack: onBack
            )
        } else {
            DispatchStatusScreen(
                ride: ride,
                driver: viewModel.driver,
                driverLocation: viewModel.driverLocation,
                myLocation: myLocation.coordinates,
                onOpenChat: onOpenChat,
                onBack: onBack
            )
        }
    }
}

/// 기사가 탑승 처리를 마쳤는가 — 25 가 26 운행 중으로 넘어갈 **유일한** 신호.
///
/// 서버 status `IN_RIDE`(`RideStatus.ongoing`) 하나만 참이다. `DispatchStatusScreen` 에는 수동
/// 트리거가 없어 이 판정이 전이의 발화점 전부다(26 의 `isRideFinished` 와 같은 모양).
///
/// 입력이 `RideStatus` 가 아니라 `Ride` 인 이유: 폴링이 받는 게 **방 상세뿐**이 됐다(가벼운 상태
/// 조회가 서버에서 삭제됐다 — `04f6be7`). 두 종류의 응답으로 똑같이 판정할 일이 없어졌으니, 들고
/// 있는 값 그대로 받는다. 조회가 실패한 주기(nil)는 "아직 아니다"로 본다 — 한 번의 네트워크
/// 오류로 화면을 넘기지 않는다.
func isRideStarted(ride: Ride?) -> Bool {
    ride?.status == .ongoing
}

/// 배차 폴링을 지금 돌려야 하는가 — **가시성 게이트의 판정**(`DispatchStatusViewModel.pollDriver`).
///
/// | 판정 | 조건 | 왜 |
/// |---|---|---|
/// | 돌리지 않는다 | `visible` 이 false | **이 함수의 존재 이유.** 뷰 수명은 앱 백그라운드에 반응하지 않는다 — 주머니 속에서 7초마다 호출 2건(분당 약 17건)이 나갔다 |
/// | 돌리지 않는다 | `pollDone` 이 true | 탑승 시작을 잡아 루프가 **끝났다**(26 으로 넘어간다). 복귀로 되살아나면 회귀다 |
/// | 돌린다 | 그 밖 | 보이고, 아직 전이를 못 잡았다 |
///
/// 가시성이 **앞**인 게 요점이다(21 의 `fallbackPollStep` 과 같은 순서) — 보이지 않는 동안에는
/// 나머지 조건을 보지 않는다. 반대로 `pollDone` 은 「끝났다」는 사실이라 복귀해도 되돌아가지 않는다.
///
/// 끊어도 안전한 근거: 이 화면은 상태를 쌓지 않고 **매 주기 방 상세를 통째로 교체**하므로 건너뛴
/// 주기를 따라잡을 필요가 없고, 복귀하면 그 패스가 곧바로 한 번 읽는다(대기가 루프 끝이다).
///
/// - Parameters:
///   - visible: 화면이 사용자에게 보이는가(`lifecycleEffect` 로 받는다)
///   - pollDone: 탑승 시작(`isRideStarted`)을 잡아 루프가 끝났는가
func shouldPollDispatch(visible: Bool, pollDone: Bool) -> Bool {
    visible && !pollDone
}

/// 기사 **정보**(`GET /matching/rooms/{id}/driver`)를 물어도 되는가.
///
/// 판정 기준은 **`Ride.driverId` 하나**다. status 로 가르면 안 된다 — 서버 `MATCHING`(기사 없음)과
/// `DRIVER_ASSIGNED`(기사 있음)가 앱에서는 둘 다 `RideStatus.dispatching` 으로 접히기 때문에,
/// status 만 보면 「기사 찾는 중」에도 참이 되어 5초마다 서버가 `DRIVER_NOT_ASSIGNED` 409 를 던지고
/// WARN 로그를 쌓는다(실제로 있었던 결함 — 위치 조회만 driverId 로 막고 이 호출은 놓쳤었다).
///
/// - Parameter alreadyLoaded: 이미 받아온 뒤면 다시 묻지 않는다 — 차량 정보는 배차 동안 바뀌지 않는다
func shouldFetchDriverInfo(ride: Ride?, alreadyLoaded: Bool) -> Bool {
    !alreadyLoaded && shouldFetchDriverLocation(ride: ride)
}

/// 기사 **위치**(`GET /dispatch/rides/{id}`)를 물어도 되는가. 위와 같은 이유로 `Ride.driverId` 만 본다.
/// 정보 게이트가 이 함수를 재사용하므로 "배정됨"의 정의는 **여기 한 곳**에만 있다 — 두 게이트가 따로
/// 갈리면서 한쪽만 고쳐지는 일(이번 결함의 원인)이 다시 생기지 않게.
func shouldFetchDriverLocation(ride: Ride?) -> Bool {
    ride?.driverId != nil
}

/// 기사 현재 위치 → 탑승지 **직선거리**(m). 둘 중 하나라도 못 쓸 좌표면 nil.
///
/// 좌표 검증을 `latLngOrNull` 에 맡기는 이유는 지도와 같다 — 서버가 위경도를 뒤바꿔 주는 결함(QA D-1)이
/// 있어, 범위를 벗어난 값으로 거리를 재면 「약 9,000분 뒤 도착」 같은 숫자가 나온다.
private func pickupDistanceMeters(ride: Ride, location: DriverLocation?) -> Double? {
    guard let pickup = latLngOrNull(latitude: ride.originLat, longitude: ride.originLng),
          let driverAt = latLngOrNull(latitude: location?.latitude, longitude: location?.longitude)
    else { return nil }
    return pickup.distanceTo(driverAt)
}
