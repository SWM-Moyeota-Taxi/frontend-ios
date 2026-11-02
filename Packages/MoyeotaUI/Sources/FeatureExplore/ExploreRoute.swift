import Foundation
import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI

/// 카메라가 멈춘 뒤 조회까지 두는 여유.
///
/// 팬·줌을 연타하면 idle 이 연달아 들어오는데, 중간 범위마다 서버를 때릴 이유가 없다.
/// 손을 뗀 직후의 체감 지연으로 느껴지지 않을 만큼만 둔다.
private let BOUNDS_DEBOUNCE_MS = 400

/// 같은 범위 재조회 주기 — 방은 다른 사람의 생성·합류·나가기로 계속 바뀐다.
///
/// **이 주기는 화면이 보이는 동안에만 돈다**(`ExploreViewModel.onScreenStart`). 탐색은 하단탭이라
/// 다른 화면이 위에 올라와도 뷰모델이 살아 있어서, 게이트가 없으면 21 매칭 대기·채팅에
/// 머무는 내내 4초마다 범위 조회가 나갔다(QA D-1: 21 체류 135초에 34회).
private let NEARBY_POLL_INTERVAL_MS = 4_000

/// 몇 번 연속으로 갱신에 실패하면 「최신 정보를 받지 못했어요」를 띄우는가 (`staleAfterPollFailures`).
///
/// **3회 = 12초**(`NEARBY_POLL_INTERVAL_MS` × 3). 1회로 두면 터널·엘리베이터처럼 금방 복구되는
/// 끊김마다 경고가 깜빡이고, 그러면 사용자가 곧 무시하게 된다. 반대로 상한이 **아예 없으면**
/// (고치기 전의 동작) 실패가 조용히 버려져 낡은 마커가 **영구히** 남고, 사용자는 이미 사라진 방의
/// 「합류」를 눌러 20 에서야 「사라진 방이에요」를 본다.
///
/// 12초는 「탭했을 때 이미 틀린 목록일 수 있다」를 의심하기 시작할 만한 시간이고(방이 차고 비는 주기가
/// 분 단위다), 지하철 역 사이 터널(보통 1~2분)보다는 짧아 **진짜 끊김은 반드시 드러난다.**
let STALE_NOTICE_FAILURES = 3

@MainActor
@Observable
public final class ExploreViewModel {
    public enum UiState: Equatable, Sendable {
        case loading

        /// 그릴 목록 하나. `stale` 은 「보여 주고는 있지만 갱신이 연속 실패했다」는 뜻이다
        /// (`STALE_NOTICE_FAILURES`) — 목록을 **치우지 않고** 화면이 비차단 표시만 올린다.
        /// 조회가 한 번이라도 성공하면 그 결과로 교체되므로 자동으로 false 로 돌아온다.
        case success(parties: [Ride], stale: Bool = false)
        case error(message: String)
    }

    /// 조회 요청 1건.
    ///
    /// `seq` 는 「같은 범위를 다시 읽어라」(재시도)를 구분하기 위한 것이다.
    private struct LoadRequest {
        var bounds: MapBounds
        var manual: Bool
        var seq: Int
    }

    public private(set) var uiState: UiState = .loading

    @ObservationIgnored private let repository: any RideRepository
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()

    @ObservationIgnored private var request: LoadRequest?
    @ObservationIgnored private var seq = 0

    /// 화면이 지금 **보이는가** — 조회·폴링의 유일한 스위치다(`nearbyPollStep`).
    ///
    /// 탭 뷰모델은 다른 화면이 위에 올라와도 살아 있고, `ViewModelScope` 는 화면이 보이는지 보지 않는다.
    /// 그래서 신호 없이는 21 매칭 대기·채팅에 머무는 동안에도 범위 조회가 계속 나간다 — 「평상시 네트워크 0」을
    /// 그 루프가 상쇄했다(QA D-1).
    ///
    /// 바뀌면 곧바로 **요청과 같은 패스를 다시 시작한다**(`restartPass`): 가려지는 순간 그 범위의 폴링이 함께
    /// 취소되고, 다시 보이면 같은 요청으로 패스가 새로 시작돼 **즉시 1회** 조회된다. 21 매칭 대기가
    /// `realtimeAlive` 로 폴백을 켜고 끄는 것과 같은 모양이다 — 판정을 순수 함수 한 곳에 모으고 루프는
    /// 그 결과만 따른다.
    @ObservationIgnored private var visible = false

    /// **보이는 상태에서 조회를 시작한** 마지막 요청의 `LoadRequest.seq`.
    ///
    /// 같은 seq 로 패스가 다시 들어왔다면 조회 범위가 바뀐 게 아니라 **화면이 다시 보이기 시작한 것**이다.
    /// 그때는 디바운스 없이 곧바로 읽는다(`nearbyPollStep`) — 돌아왔는데 주기만큼 옛 목록이 남아 있으면
    /// 이미 사라진 방의 「합류」를 누르게 된다.
    @ObservationIgnored private var shownSeq = 0

    @ObservationIgnored private var pass: Task<Void, Never>?

    public convenience init(repository: any RideRepository) {
        self.init(repository: repository, sleep: { try await Task.sleep(for: $0) })
    }

    init(
        repository: any RideRepository,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.repository = repository
        self.sleep = sleep
    }

    /// 화면이 보이기 시작했다 — **즉시 1회 조회**하고 주기 갱신을 재개한다.
    ///
    /// 탭 복귀·앱 복귀·위에 있던 화면의 pop 이 모두 이 길로 온다(`lifecycleEffect`).
    /// 숨어 있던 동안 보던 목록은 그대로 두고 그 위에 새 결과를 덮으므로 로딩으로 깜빡이지 않는다(`load`).
    /// 첫 조회가 실패해 에러 화면이던 경우도 여기서 함께 복구된다(목록이 없으면 즉시 조회 대상이다).
    public func onScreenStart() {
        guard !visible else { return }
        visible = true
        restartPass()
    }

    /// 화면이 가려졌다(탭 이동·다른 화면 진입·앱 백그라운드) — 주기 조회를 멈춘다.
    ///
    /// 들고 있던 목록·지도 카메라는 건드리지 않는다. 돌아올 때 그 목록을 그대로 보여주고
    /// 새로 읽은 결과로 덮는 게 맞기 때문이다.
    public func onScreenStop() {
        guard visible else { return }
        visible = false
        restartPass()
    }

    /// 지도에 보이는 영역이 바뀌었다(카메라 idle). 첫 진입 시에는 기준점 범위로 한 번 호출한다.
    ///
    /// 지도 마커와 시트 목록은 **여기서 받아온 하나의 목록**에서 나온다 — 화면 밖 방이
    /// 리스트에만 남아 있는 상태를 만들지 않는다.
    public func onVisibleBoundsChange(_ bounds: MapBounds) {
        if request?.bounds == bounds { return } // idle 이 같은 범위로 다시 와도 재조회하지 않는다
        seq += 1
        request = LoadRequest(bounds: bounds, manual: false, seq: seq)
        restartPass()
    }

    /// 지도가 범위를 알려주기 전의 **기준 범위** — 아직 어떤 범위도 받지 못했을 때만 쓴다.
    ///
    /// Route 의 진입 이펙트는 탭을 다녀오면 **다시 실행된다**. 그때도 기준 범위를 밀어 넣으면
    /// ① 복원된 카메라와 **다른 동네의 목록**이 잠깐 보이고(지도는 보던 자리에 있는데
    /// 리스트·마커만 기준점 주변으로 바뀐다) ② 복귀 즉시 조회가 그 엉뚱한 범위로 가 버린다.
    /// 그래서 「첫 범위」라는 뜻을 여기서 지킨다 — 복귀는 `onScreenStart` 가 마지막 범위로 처리한다.
    public func onInitialBounds(_ bounds: MapBounds) {
        if request != nil { return }
        onVisibleBoundsChange(bounds)
    }

    /// 에러 화면의 「다시 시도」 — 마지막으로 본 범위를 그대로 다시 읽는다.
    public func refresh() {
        guard var current = request else { return } // 아직 범위조차 못 받은 상태면 재시도할 대상이 없다
        seq += 1
        current.manual = true
        current.seq = seq
        request = current
        restartPass()
    }

    /// 요청 하나를 조회 + 주기 갱신 루프로 처리한다 — **보이는 동안만.**
    ///
    /// 범위(`request`)와 가시성(`visible`) 중 **어느 쪽이 바뀌어도** 앞 패스를 취소하므로 세 가지가 한꺼번에 성립한다.
    ///
    /// | 바뀐 것 | 일어나는 일 |
    /// |---|---|
    /// | 새 범위(카메라 idle) | 앞 범위의 조회·폴링이 취소되고 새 범위로 다시 시작 — 낡은 결과가 남지 않는다 |
    /// | 가려짐 | 진행 중인 조회와 폴링이 **함께 죽는다**(다음 신호까지 아무것도 하지 않는다) |
    /// | 다시 보임 | 같은 요청으로 패스가 새로 시작 → **즉시 1회 조회** 후 주기 재개 |
    ///
    /// 가려진 동안에는 대기조차 돌지 않는다 — 깨어나 아무 일도 하지 않는 주기 자체가 없어진다.
    ///
    /// 판정은 태스크를 띄우기 전에 동기로 끝낸다. 태스크 첫 줄에서 하면 곧바로 취소될 패스가 `shownSeq` 를
    /// 건드려, 뒤따르는 패스가 새 범위를 복귀로 오해할 수 있다.
    private func restartPass() {
        pass?.cancel()
        pass = nil
        guard let req = request else { return }
        let step = nearbyPollStep(
            visible: visible,
            manual: req.manual,
            hasParties: hasParties(),
            requestSeq: req.seq,
            shownSeq: shownSeq
        )
        if step == .stop { return }
        // 디바운스 **전에** 적어 둔다 — 기다리는 동안 가려졌다 돌아오면 그때는 복귀로 보고
        // 또 기다리지 않게 한다(카메라는 이미 멈춰 있다).
        shownSeq = req.seq

        let repository = repository
        let sleep = sleep
        // 대기 중에 self 를 강하게 잡지 않는다 — 잡고 있으면 뷰모델이 해제되지 않아 폴링이 영영 끝나지 않는다.
        pass = scope.launch { [weak self] in
            do {
                if step == .debounceThenQuery {
                    try await sleep(.milliseconds(BOUNDS_DEBOUNCE_MS))
                }
                try await self?.load(req.bounds)
                // 연속 실패 횟수는 **패스마다 0 에서 시작한다** — 범위가 바뀌거나 화면이 다시 보이면
                // 새 패스이고, 그때는 직전 범위에서의 실패를 이어 셈할 이유가 없다.
                var failures = 0
                while !Task.isCancelled {
                    try await sleep(.milliseconds(NEARBY_POLL_INTERVAL_MS))
                    let parties: [Ride]
                    do {
                        parties = try await req.bounds.query(repository)
                    } catch {
                        // 원본 `runCatching` 은 취소까지 실패로 세지만 곧바로 루프가 끝나 뜻이 없다.
                        // 취소가 실패 횟수에 들어가 「낡음」을 켜지 않게 먼저 빠져나간다.
                        if Task.isCancelled { return }
                        // 실패해도 보던 목록은 그대로 둔다(지도를 에러 화면으로 바꾸지 않는다).
                        // 다만 **버리지 않고 세어 둔다** — 상한이 없던 동안 낡은 마커가 영구히 남았다.
                        failures += 1
                        if staleAfterPollFailures(consecutiveFailures: failures) { self?.markStale() }
                        continue
                    }
                    // 코루틴은 취소되면 대기 지점에서 던져 여기까지 오지 않는다. URLSession 은 취소와 응답이
                    // 엇갈릴 수 있어 직접 본다 — 앞 범위의 결과가 새 범위 위에 덮이면 안 된다.
                    try Task.checkCancellation()
                    failures = 0
                    self?.setState(.success(parties: parties))
                }
            } catch {
                // 여기로 오는 것은 이 태스크의 취소뿐이다(`sleep`·`load`·`checkCancellation`). 실패는 위에서 처리했다.
            }
        }
    }

    /// 들고 있는 목록은 그대로 두고 「낡음」만 켠다 — 화면이 그 사실을 비차단으로 알린다.
    ///
    /// 목록이 없는 상태(Loading·Error)에서는 아무것도 하지 않는다: 보여 줄 게 없으면 「낡았다」가
    /// 아니라 첫 조회 실패이고, 그쪽은 `load` 가 에러 화면으로 다룬다.
    private func markStale() {
        if case .success(let parties, stale: false) = uiState {
            setState(.success(parties: parties, stale: true))
        }
    }

    private func load(_ bounds: MapBounds) async throws {
        let hadParties = hasParties()
        // 이미 목록이 있으면 Loading 으로 덮지 않는다. 지도가 화면에서 사라졌다 돌아오면
        // 카메라가 초기 위치로 되돌아가고, 그 idle 이 또 조회를 부르는 되먹임이 생긴다.
        if !hadParties { setState(.loading) }
        do {
            let parties = try await bounds.query(repository)
            try Task.checkCancellation()
            setState(.success(parties: parties))
        } catch {
            // 범위가 바뀌었거나 **화면이 가려져** 취소된 것 — 실패가 아니므로 에러 화면으로 바꾸지 않는다.
            // 가시성 게이트가 생긴 뒤로는 이 길을 자주 지난다(첫 조회 중에 탭을 옮기면 매번).
            //
            // 판정은 **이 태스크가 취소됐는가**만 본다(`isCancellation` 을 쓰지 않는다). 태스크가 살아 있는데 온
            // `URLError(.cancelled)` 는 시스템이 전송을 끊은 것으로, 원본에서는 OkHttp 의 `IOException` 이라
            // 아래 실패 경로로 간다. 이걸 되던지면 패스가 끝나 폴링에 들어가지 못하고, 첫 조회였다면
            // 재시도 버튼도 없는 로딩에 멈춘다.
            if Task.isCancelled { throw error }
            // 갱신 실패로 지도를 통째로 에러 화면으로 바꾸지 않는다(21 대기 화면과 같은 판단) —
            // 보던 목록을 남기고 다음 주기에 다시 읽는다. 처음부터 실패한 경우만 에러 화면.
            // 이 실패가 계속되면 주기 루프가 연속 횟수를 세어 「낡음」을 알린다(`markStale`) —
            // 목록을 남기는 것과 **아무 말도 안 하는 것**은 다르다.
            if hadParties { return }
            setState(.error(message: "동승 목록을 불러오지 못했어요"))
        }
    }

    /// `MutableStateFlow` 처럼 같은 값은 내보내지 않는다 — 폴링 결과가 그대로일 때 화면을 다시 그리지 않는다.
    private func setState(_ next: UiState) {
        if uiState != next { uiState = next }
    }

    private func hasParties() -> Bool {
        if case .success = uiState { return true }
        return false
    }
}

private extension MapBounds {
    // 인자 순서(남서 위도 → 남서 경도 → 북동 위도 → 북동 경도)를 한 곳에서만 쓴다.
    // 뒤바뀌면 서버가 오류 대신 빈 목록을 돌려주므로 호출부마다 풀어 쓰면 눈에 띄지 않는 버그가 된다.
    // 가시 영역보다 넓게 묻는다 — 경계에 걸친 방이 카메라가 조금 움직일 때마다 빠졌다 들어오며
    // 마커가 깜빡이는 것을 막는다(`MapBounds.expanded` 설명 참고).
    func query(_ repository: any RideRepository) async throws -> [Ride] {
        let area = expanded()
        return try await repository.getPartiesWithin(
            swLat: area.swLat,
            swLng: area.swLng,
            neLat: area.neLat,
            neLng: area.neLng
        )
    }
}

// 17–19 합승 탐색 — 서버 목록 연동 진입점
public struct ExploreRoute: View {
    /// 지금 진행 중인 내 방(`ActivePartyViewModel.resolve` 결과). nil 이면 상단 배너를 그리지 않는다
    private let activeRide: Ride?
    private let onJoinParty: (Ride) -> Void
    private let onOngoingRideClick: () -> Void
    private let onCreateRoomClick: () -> Void
    private let onTabSelect: (MoyeotaTab) -> Void

    @HostedViewModel private var viewModel: ExploreViewModel

    // 지도가 화면의 본체라 탭 진입 시 권한을 요청한다.
    // 목록 로딩·에러 분기 **밖**에서 잡아야 조회가 실패해도 권한 흐름이 죽지 않는다.
    @RememberMyLocationState private var myLocation

    @Environment(\.tabSavedState) private var tabSavedState

    public init(
        repository: any RideRepository,
        activeRide: Ride? = nil,
        onJoinParty: @escaping (Ride) -> Void = { _ in },
        onOngoingRideClick: @escaping () -> Void = {},
        onCreateRoomClick: @escaping () -> Void = {},
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in }
    ) {
        _viewModel = HostedViewModel(wrappedValue: ExploreViewModel(repository: repository))
        self.activeRide = activeRide
        self.onJoinParty = onJoinParty
        self.onOngoingRideClick = onOngoingRideClick
        self.onCreateRoomClick = onCreateRoomClick
        self.onTabSelect = onTabSelect
    }

    /// 호스트가 뷰모델을 들고 있는 경로 — 원본 `viewModel(factory = …)` 이 돌려주는 **백스택 엔트리의 뷰모델** 자리.
    ///
    /// 원본은 `popUpTo(HOME) { saveState = true }` + `restoreState = true` 로 탭을 떠나도 뷰모델이 남는다.
    /// 그 전제 위에서 `onInitialBounds` 가 복귀 때의 기준 범위를 무시하고 `onScreenStart` 가 마지막 범위로 바로
    /// 읽는다. 탭을 `switch` 로 갈아 끼우는 호스트는 뷰가 없어지므로, 위의 `init(repository:…)` 를 쓰면 복귀할
    /// 때마다 새 뷰모델이 로딩부터 다시 시작하고 기준 범위로 조회가 나간다. 그런 호스트는 탭 바깥에서
    /// `ExploreViewModel` 을 하나 들고 여기로 넘기고, 로그아웃 때 버린다(`clearBackStack` 자리).
    /// `TabView` 처럼 뷰를 살려 두는 호스트는 `init(repository:…)` 로 충분하다.
    ///
    /// 뷰 수명 동안 처음 받은 인스턴스를 쓴다.
    public init(
        viewModel: ExploreViewModel,
        activeRide: Ride? = nil,
        onJoinParty: @escaping (Ride) -> Void = { _ in },
        onOngoingRideClick: @escaping () -> Void = {},
        onCreateRoomClick: @escaping () -> Void = {},
        onTabSelect: @escaping (MoyeotaTab) -> Void = { _ in }
    ) {
        _viewModel = HostedViewModel(wrappedValue: viewModel)
        self.activeRide = activeRide
        self.onJoinParty = onJoinParty
        self.onOngoingRideClick = onOngoingRideClick
        self.onCreateRoomClick = onCreateRoomClick
        self.onTabSelect = onTabSelect
    }

    public var body: some View {
        let viewModel = viewModel
        let location = myLocation
        // 좌표·오차·방향을 한 덩어리로 넘긴다 — 지도가 파란 점과 오차 원을 같은 fix 로 그려야 한다
        let myFix = location.coordinates.map {
            MyLocationFix(
                position: LatLng($0.latitude, $0.longitude),
                accuracyMeters: $0.accuracyMeters,
                bearingDegrees: $0.bearingDegrees
            )
        }

        // 분기를 `ZStack` 하나로 감싼다. 아래 이펙트가 상태 분기마다 따로 걸리면(`Group`) 로딩 → 목록 전환이
        // 사라짐·나타남으로 읽혀 가시성이 끊겼다 이어지고, 그때마다 조회가 한 번 더 나간다.
        ZStack {
            // 로딩·에러에서도 하단탭은 남긴다 — 조회 실패로 탭 이동이 막히면 안 된다 (QA F-1)
            switch viewModel.uiState {
            case .loading:
                TabStateScaffold(selectedTab: .explore, onTabSelect: onTabSelect) {
                    LoadingBox()
                }
            case .error(let message):
                TabStateScaffold(selectedTab: .explore, onTabSelect: onTabSelect) {
                    ErrorBox(message: message, onRetry: { viewModel.refresh() })
                }
            case .success(let parties, let stale):
                // 내가 이미 참여 중인 방은 목록·마커에서 뺀다(`exploreList`).
                //
                // **뷰모델이 아니라 여기서** 거르는 이유:
                // ① `activeRide` 는 `ActivePartyViewModel`(앱 전체가 공유하는 홀더)이 들고 있는 값이고
                //    이 뷰모델은 그걸 모른다. 넘겨주려면 탐색 뷰모델에 두 번째 데이터 출처가 생기고,
                //    그 출처가 바뀔 때마다 상태를 다시 만들어야 한다.
                // ② `UiState.success(parties, stale)` 는 **서버가 말한 것**이어야 한다. 거기서 걸러
                //    버리면 `stale`(갱신 연속 실패 표시)과 목록이 다른 뜻을 갖게 된다 — 「서버 목록은
                //    낡지 않았는데 내가 뺀 탓에 비었다」를 구분할 수 없고, `hasParties` 같은 폴링 판정이
                //    표시용 목록을 보게 된다.
                // 거르는 층이 화면 쪽이라도 **마커·카드·헤더 N 은 어긋나지 않는다** — 셋 다
                // `ExploreScreen` 의 `parties` **한 파라미터**에서 나온다(지도는 `rides = parties`).
                let list = exploreList(parties: parties, myPartyId: activeRide?.id)
                ExploreScreen(
                    parties: list.parties,
                    activeRide: activeRide,
                    myPartyHidden: list.myPartyHidden,
                    stale: stale,
                    locationGranted: location.isGranted,
                    myLocation: myFix,
                    initialSheetState: tabSavedState?.value(ExploreSheetStateKey) ?? .peek,
                    onJoinParty: onJoinParty,
                    onOngoingRideClick: onOngoingRideClick,
                    onCreateRoomClick: onCreateRoomClick,
                    onRequestLocationPermission: { location.onRequestPermission() },
                    onVisibleBoundsChange: { viewModel.onVisibleBoundsChange($0) },
                    onTabSelect: onTabSelect
                )
            }
        }
        .myLocationEffect($myLocation)
        // 화면이 보이는 동안만 조회·폴링한다 — 탭을 옮기거나 다른 화면이 위에 올라오거나 앱이 백그라운드로
        // 가면 즉시 멈추고, 돌아오면 그 자리에서 1회 조회한 뒤 주기를 재개한다 (24 채팅방과 같은 배치).
        .lifecycleEffect(
            onStart: { viewModel.onScreenStart() },
            onStop: { viewModel.onScreenStop() }
        )
        // 첫 조회는 지도를 기다리지 않고 기준 범위로 먼저 쏜다.
        // 지도는 목록 상태에서만 붙으므로(로딩 화면에는 지도가 없다) 지도의 첫 idle 을
        // 기다리면 로딩에서 영영 못 나온다. 권한을 거부해 지도가 아예 없는 경로도 같다.
        // 실좌표가 뒤늦게 잡히면 지도 카메라가 그리로 옮겨가며 idle → 실제 범위로 다시 조회된다.
        //
        // 탭을 다녀오면 이 이펙트가 **다시** 실행되지만, 그때 쓸 범위는 기준점이 아니라
        // 보던 카메라다 — `ExploreViewModel.onInitialBounds` 가 이미 범위를 받은 뒤의 호출을 무시한다.
        .task {
            viewModel.onInitialBounds(defaultExploreBounds(center: myFix?.position))
        }
    }
}

/// 17 이 실제로 그릴 목록 — 서버 목록에서 **내가 이미 참여 중인 방**을 뺀 결과.
///
/// - Parameters:
///   - parties: 서버가 지도 범위로 돌려준 목록(`status = ACTIVE` 인 방만 온다)
///   - myPartyHidden: 이 범위의 목록에서 **내 방을 실제로 빼냈는가**. 빈 목록 문구가 이 값으로
///     갈린다 — 내 방 하나뿐인 동네에서 「이 근처엔 동승이 없어요」는 거짓말이 된다
struct ExploreList: Equatable {
    var parties: [Ride]
    var myPartyHidden: Bool
}

/// 내가 참여 중인 방을 17 목록·마커에서 **뺀다.**
///
/// **왜 빼는가.** 서버 목록은 내 방을 빼지 않아서, 내가 속한 방이 남의 방과 **똑같은 「합류」 카드**로
/// 섞여 보였다. 그 카드는 거짓말을 한다 — 「합류」 버튼이 활성이고 인원 배지는 내가 들어가기 **전**의
/// 수처럼 읽힌다. 눌러서 20 합류 확인에 가면 `joinGate` 가 `ALREADY_JOINED` 로 받아 「이미 참여
/// 중인 방이에요」 + 「방으로 돌아가기」를 주므로 막힌 길은 아니지만, **같은 화면 맨 위에 진행 중 방
/// 배너가 이미 있다**(`ExploreScreen` 의 `ActiveRideBanner` → `onOngoingRideClick`): 한 번 눌러
/// 21/25/26 으로 바로 간다. 20 을 거치는 카드는 탭이 한 번 더 들고 방 상세를 한 번 더 읽는 **더 긴
/// 우회로**이며, 그 사이 화면은 내가 합류할 수 있는 방처럼 보인다. 돌아가는 길이 이미 더 짧게 있으니
/// 그 카드는 소음이다.
///
/// **20 의 `ALREADY_JOINED` 분기는 그대로 남는다** — 이 필터는 17 의 **표시**만 바꾼다. 목록이
/// 낡아 내 방이 아직 섞여 있는 순간, 알림으로 20 에 바로 들어오는 경우, 그리고 `activeRide` 홀더가
/// 아직 비어 있는 순간(앱 시작 직후 첫 `resolve` 전)이 모두 그 분기로 간다.
///
/// **판정은 `activeRide` 의 id 하나로 한다.** `ride.members.contains { $0.isMe }` 는 이 데이터로는
/// **영원히 false** 다 — 목록 응답에는 멤버 식별자가 없어 매퍼가 자리 표시용 멤버를 만들고
/// (`PartyMappers.placeholderMembers`) 그 멤버에는 `publicId` 가 없어 `User.isMe` 가 늘 false 다.
/// 즉 목록 데이터만으로는 「내가 그 방에 있는가」를 알 수 없고, 알고 있는 쪽은 방 상세를 읽어 둔
/// `ActivePartyViewModel` 뿐이다.
///
/// id 비교는 **Int64 로 먼저** 본다(`needsDetailAfterRemember` 와 같은 이유): 두 값은 서로 다른
/// 응답에서 왔고(목록 `partyId`, 상세 `id`) 문자열 모양이 어긋날 수 있다. 숫자로 안 읽히는 id 는
/// 문자열로 비교한다.
///
/// `activeRide` 의 단계는 보지 않는다. 끝난 방(COMPLETED·CANCELED)은 `status = ACTIVE` 목록에
/// 아예 오지 않아 id 가 걸릴 일이 없고, 「어느 단계부터 거른다」는 조건을 두면 그 조건이 배너를
/// 그리는 조건(nil 이 아니면 그린다)과 갈릴 수 있다.
func exploreList(parties: [Ride], myPartyId: String?) -> ExploreList {
    guard let myPartyId, !myPartyId.isBlank else {
        return ExploreList(parties: parties, myPartyHidden: false)
    }
    let remaining = parties.filter { !samePartyId($0.id, myPartyId) }
    return ExploreList(
        parties: remaining,
        myPartyHidden: remaining.count != parties.count
    )
}

/// 같은 방인가. 숫자로 읽히면 숫자로, 아니면 문자열로 본다(`exploreList` 설명).
private func samePartyId(_ a: String, _ b: String) -> Bool {
    let left = Int64(a)
    let right = Int64(b)
    return left != nil || right != nil ? left == right : a == b
}

/// 수집 패스 한 번이 할 일 — `nearbyPollStep` 의 판정 결과.
enum NearbyPollStep {
    /// 아무것도 하지 않고 다음 신호를 기다린다(화면이 보이지 않는다)
    case stop

    /// 지금 바로 조회하고 주기 갱신을 시작한다
    case queryNow

    /// 팬·줌 중간 범위다 — 잠깐 기다린 뒤 조회한다
    case debounceThenQuery
}

/// 탐색 목록 조회를 **지금 할지, 기다릴지, 아예 하지 않을지.**
///
/// 폴링을 화면 가시성에 묶는 판정을 이 한 곳에 모은다(21 매칭 대기의 `shouldPollFallback` 과 같은 자리).
/// 위에서부터 읽는다 — 앞의 조건이 뒤를 가린다.
///
/// | 판정 | 조건 | 이유 |
/// |---|---|---|
/// | `stop` | `visible` 이 false | **이 함수의 존재 이유.** 보이지 않는 화면이 서버를 부를 이유가 없다 |
/// | `queryNow` | `manual` (「다시 시도」) | 사용자가 방금 누른 것이다. 기다리면 버튼이 먹지 않은 것처럼 보인다 |
/// | `queryNow` | `hasParties` 가 false | 첫 조회이거나 에러 화면이다 — 보여줄 게 없으니 늦출 이득이 없다 |
/// | `queryNow` | `requestSeq` == `shownSeq` | **탭 복귀**(범위는 그대로인데 패스가 다시 들어왔다). 숨어 있던 동안의 변화를 주기만큼 미루면 이미 사라진 방에 합류를 누르게 된다 |
/// | `debounceThenQuery` | 그 밖(새 범위 + 목록 있음) | 팬·줌을 연타하면 idle 이 연달아 온다. 중간 범위마다 서버를 때리지 않는다 |
///
/// 숨어 있는 동안 지도 카메라가 바뀌는 일은 없다(가려진 화면에는 idle 이 오지 않는다).
/// 그래도 바뀐 범위가 들어와 있었다면 그 요청은 **새 seq** 라 복귀 때 디바운스 한 번 뒤에 그 범위로 조회된다 —
/// 어느 쪽이든 돌아온 뒤에는 보이는 범위로 다시 읽는다.
///
/// - Parameters:
///   - visible: 화면이 사용자에게 보이는가(`lifecycleEffect` 로 받는다)
///   - manual: 에러 화면의 「다시 시도」로 생긴 요청인가
///   - hasParties: 지금 화면에 그릴 목록을 들고 있는가
///   - requestSeq: 이번 패스가 처리할 요청의 순번
///   - shownSeq: 보이는 상태에서 마지막으로 조회를 시작한 요청의 순번
func nearbyPollStep(
    visible: Bool,
    manual: Bool,
    hasParties: Bool,
    requestSeq: Int,
    shownSeq: Int
) -> NearbyPollStep {
    if !visible { return .stop }
    if manual || !hasParties || requestSeq == shownSeq { return .queryNow }
    return .debounceThenQuery
}

/// 갱신 실패를 **사용자에게 알릴 때인가** — `nearbyPollStep` 과 같은 자리의 판정이다(순수 함수 한 곳에
/// 모으고 루프는 결과만 따른다).
///
/// 한 번의 실패는 알리지 않는다(지도 앱의 흔한 일시 끊김이다). 연속 `STALE_NOTICE_FAILURES` 회부터
/// 알린다 — 임계값의 근거는 그 상수에 적어 두었다. **성공 한 번이 카운터를 0 으로 돌린다**(호출부)
/// 이므로, 이 함수는 「지금까지 연속 몇 번 실패했는가」만 보면 된다.
///
/// - Parameter consecutiveFailures: 마지막 성공 이후 연속 실패 횟수(성공하면 0 으로 돌아간다)
func staleAfterPollFailures(consecutiveFailures: Int) -> Bool {
    consecutiveFailures >= STALE_NOTICE_FAILURES
}
