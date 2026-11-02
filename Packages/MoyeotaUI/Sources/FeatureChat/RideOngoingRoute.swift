import MoyeotaDesignSystem
import MoyeotaDomain
import Observation
import PresentationCore
import SwiftUI
import os

/// 운행 완료 폴링 간격 — **8초**. 기사가 운행을 끝낸 뒤 최악의 경우 이만큼 기다렸다 33 으로 넘어간다.
///
/// 옛 4초에서 늘렸다. 매 주기 읽는 대상이 쿼리 1개짜리 상태 조회에서 **쿼리 3개짜리 방 상세**로
/// 바뀌었기 때문이다 — 서버가 `/status` 를 삭제했다(`04f6be7`). 4초를 그대로 두면 쿼리 부하가
/// 0.25 → 0.75 q/s 로 3배가 된다. 8초면 0.38 q/s 로 옛 구조와 비슷하다.
///
/// 25 배차 상태(7초)보다 **길게** 두는 이유: 이 화면이 기다리는 전이는 운행 완료 하나뿐이고, 지도에
/// 주기마다 움직일 마커가 없다(출발·도착·경로는 방 생성 시 확정된 값이고 내 위치는 단말이 1초마다
/// 직접 갱신한다). 그래서 범위에서 가장 낮은 부하를 고를 수 있다.
/// 근거와 부하 표는 `PARTY_DETAIL_POLL_FLOOR_MS` 설명에 있다.
let RIDE_POLL_INTERVAL_MS: Int64 = 8_000

private let logger = Logger(subsystem: "com.moyeota.presentation", category: "RideOngoing")

@MainActor
@Observable
public final class RideOngoingViewModel {
    // 관찰 대상은 status 하나뿐이라 Loading/Error/Success 3상태를 두지 않고 "완료됐는가"만 내보낸다
    // — 폴링이 실패해도 화면은 그대로 살아있어야 한다.
    public private(set) var finished = false

    // 지도(출발·도착 마커, 경로)와 시트 문구용 방 상세. 폴링이 돌려주는 값이 그대로 들어온다.
    // 여기서 쓰는 값(출발·도착 좌표, routePolyline, 목적지명, 예상 소요시간)은 방 생성 시 서버가
    // 확정해 박아두는 값이라 운행 중에 바뀌지 않는다 — 그래서 같은 값이 다시 와도 흘려보낸다
    // (shouldPublishDetail). 지도는 부가 정보라 UiState 를 만들지 않고, 못 받은 동안(nil)에는
    // 마커 없는 지도를 그린다.
    public private(set) var ride: Ride?

    /// 화면이 지금 **보이는가** — 완료 폴링의 스위치. Route 의 `lifecycleEffect` 가 내려 준다
    /// (`onScreenStart`·`onScreenStop`).
    ///
    /// ### 왜 필요한가
    /// 예전에는 Route 의 `LaunchedEffect` 가 이 루프를 들고 있었다. 그건 **컴포지션 이탈**에만 취소되고
    /// **앱 백그라운드**에는 반응하지 않아, 홈 버튼을 눌러도 8초마다 쿼리 3개짜리 방 상세가 계속 나갔다
    /// — 30분 운행이면 승객 1명당 약 225회다. 같은 레포의 다른 폴링은 전부 같은 경계를 쓴다
    /// (21 매칭 대기·17 탐색·24 채팅방·호스트 폴링).
    ///
    /// ### 왜 끊어도 안전한가
    /// 이 루프가 기다리는 전이는 **운행 완료 하나**고, 그건 서버 status 에 남아 있다 — 놓치는 게 아니라
    /// **늦게 보는** 것뿐이다. 그래서 복귀하면 주기를 기다리지 않고 **그 자리에서 한 번 읽는다**
    /// (루프 본문이 조회 → 판정 → 대기 순서라 다시 시작하는 순간 첫 조회가 나간다).
    /// 가려진 동안 FINISHED 가 됐더라도 복귀 즉시 33 으로 넘어간다.
    ///
    /// ### 기본값이 true 인 이유
    /// 배선이 빠진 채 머지되면 최악이 「고쳐지지 않은 상태 유지」여야 한다 — false 면 화면이 영영
    /// 33 으로 넘어가지 않는 기능 손실이 된다(`MatchWaitingViewModel.visible` 과 같은 이유).
    @ObservationIgnored private var visible = true

    @ObservationIgnored private let repository: any RideRepository
    @ObservationIgnored private let partyId: Int64
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let scope = ViewModelScope()
    @ObservationIgnored private var pass: Task<Void, Never>?

    public init(
        repository: any RideRepository,
        partyId: Int64,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.repository = repository
        self.partyId = partyId
        self.sleep = sleep
        observeRideFinish()
    }

    /// 화면이 보이기 시작했다(첫 진입·앱 복귀·위에 올라온 27 신고의 pop) — 폴링을 즉시 재개한다
    public func onScreenStart() {
        setVisible(true)
    }

    /// 화면이 가려졌다(앱 백그라운드·27 신고가 위에 올라옴) — 폴링을 멈춘다. 들고 있던 상세는 그대로 둔다
    public func onScreenStop() {
        setVisible(false)
    }

    private func setVisible(_ shown: Bool) {
        // `MutableStateFlow` 처럼 같은 값은 흘려보낸다 — 패스를 다시 시작하면 조회가 한 번 더 나간다.
        // 첫 진입의 onScreenStart 가 init 의 패스를 건드리지 않는 것도 이 덕분이다.
        if visible == shown { return }
        visible = shown
        observeRideFinish()
    }

    /// 방 상세(`RideRepository.getPartyDetail`, `GET /matching/rooms/{id}`)를 주기적으로 읽어
    /// 기사측 운행 종료(`POST /dispatch/rides/{id}/complete`)를 따라잡는다.
    /// 서버 status IN_RIDE → FINISHED 전이가 `RideStatus.ongoing` → `RideStatus.completed` 로 매핑된다.
    ///
    /// **동승 모드에서는 이 루프가 한 번도 돌지 않는다** — 서버가 `ONGOING` 을 내지 않아 26 에 닿을
    /// 길이 없다(`docs/MODE-ROUTES.md`). 택시 모드 전용이다.
    ///
    /// **상세를 읽는 이유**: 이 루프가 기다리는 건 status 하나뿐이라 예전에는 가벼운 상태 조회
    /// (`/status`, 쿼리 1개)를 읽었다. 그 엔드포인트가 백엔드에서 삭제됐다(`04f6be7` — 매칭방 변화가
    /// SSE 전용이 되면서 폴링용 조회가 쓰이지 않게 됐다). 그런데 **배차·운행 전이에는 SSE 이벤트도
    /// FCM 도 없어서**(서버 발행처가 참여·퇴장·종료뿐) 폴링을 없앨 수도 없다 — 수단만 상세로 바꿨다.
    ///
    /// 상세는 쿼리 3개에 경로까지 실어 오는 무거운 호출이라(부하테스트에서 상세 폴링이 전체 요청의
    /// 45% — Backend #177) 간격을 4초 → `RIDE_POLL_INTERVAL_MS`(8초)로 늘렸고, 받은 값이 들고 있던
    /// 것과 같으면 **흘려보낸다**(`shouldPublishDetail`) — 바뀔 값이 없는 화면이라 평상시엔 매 주기
    /// 같은 상세가 오고, 그대로 넣으면 8초마다 지도가 다시 그려진다.
    ///
    /// 지도용 상세를 "첫 성공 한 번만" 읽던 분기는 **없어졌다** — 폴링이 주는 게 곧 그 상세다.
    /// 첫 조회가 실패해도 다음 주기가 자동으로 복구한다(예전에 `shouldLoadRideDetail` 이 하던 일).
    ///
    /// 스코프는 **ViewModel** 것이고, 도는지 마는지는 `visible` 이 정한다 — 가려지는 순간 진행 중인
    /// 조회와 대기를 **함께** 취소하고, 다시 보이면 같은 패스를 처음부터 시작한다(원본 `collectLatest`).
    ///
    /// 복귀하면 **첫 주기를 기다리지 않는다** — 본문이 조회 → 판정 → 대기 순서라 패스가 다시 시작하는
    /// 순간 조회가 나간다. 가려진 동안 FINISHED 가 됐어도 돌아온 즉시 33 으로 넘어간다.
    ///
    /// 폴링 실패는 일시적 네트워크 문제일 뿐이라 화면을 에러로 덮지 않고 다음 주기를 기다린다
    /// (운행 중 화면은 27 신고 진입점이라 무슨 일이 있어도 가려지면 안 된다 — QA D-3 동류).
    private func observeRideFinish() {
        pass?.cancel()
        pass = nil
        // 끝난 뒤에는 가시성이 바뀌어도 되살아나지 않는다 — 가시성은 스위치, 완료는 종결이다.
        guard shouldPollRideFinish(visible: visible, finished: finished) else { return }
        let repository = self.repository
        let partyId = self.partyId
        let sleep = self.sleep
        logger.debug("운행 완료 폴링 시작 partyId=\(partyId)")
        pass = scope.launch { [weak self] in
            defer { logger.debug("운행 완료 폴링 중단 partyId=\(partyId)") }
            while !Task.isCancelled {
                // 실패 시 마지막 성공값을 유지한다 — 마커가 깜빡이면 "사라졌다"로 읽힌다.
                let fetched: Ride?
                do {
                    fetched = try await repository.getPartyDetail(partyId: partyId)
                } catch {
                    logger.debug("상세 폴링 실패 — 다음 주기 재시도: \(error.localizedDescription)")
                    fetched = nil
                }
                // 가려진 뒤 늦게 도착한 응답은 버린다 — 원본은 취소가 응답을 먼저 끊는다.
                if Task.isCancelled { return }
                // self 를 대기 너머로 잡지 않는다. 잡으면 뷰모델이 해제되지 않아 폴링이 영영 돈다.
                guard let done = self?.receive(fetched), !done else { return }
                do {
                    try await sleep(.milliseconds(RIDE_POLL_INTERVAL_MS))
                } catch {
                    return // 대기가 던지는 것은 취소뿐이다 — 패스를 끝낸다.
                }
            }
        }
    }

    /// 한 주기의 결과를 반영한다. 운행이 끝났으면 true.
    private func receive(_ fetched: Ride?) -> Bool {
        if let fetched, shouldPublishDetail(held: ride, fetched: fetched) {
            ride = fetched
        }
        // 판정은 **이번 주기에 받은 값**으로만 한다 — 실패한 주기(nil)는 "아직 아니다"다.
        guard isRideFinished(ride: fetched) else { return false }
        logger.debug("운행 완료 감지 partyId=\(self.partyId) → 33 도착 완료")
        finished = true
        return true
    }
}

/// 26 운행 중 — 서버 운행 완료를 **방 상세 폴링**으로 따라잡는 진입점.
///
/// partyId 가 없으면(채팅·34 내 기록에서 바로 들어온 경우) 폴링 없이 화면만 띄운다 — 이때는 목적지·경유
/// 순서도 알 수 없어 「목적지로 이동 중」만 보인다.
/// 33 으로의 전이는 서버 status 전이가 유일한 신호다(`isRideFinished`) — 화면 안에 수동 트리거는 없다.
///
/// **이 화면은 택시 모드에서만 보인다** — 동승 모드 서버는 `ONGOING` 을 내지 않는다
/// (`docs/MODE-ROUTES.md`). 그래서 `RideOngoingViewModel.observeRideFinish` 의 상세 폴링도
/// 택시 모드에서만 돈다. 그 폴링은 **화면이 보이는 동안만** 돈다(`shouldPollRideFinish`).
public struct RideOngoingRoute: View {
    private let repository: any RideRepository
    private let partyId: Int64?
    private let onBack: () -> Void
    private let onOpenChat: () -> Void
    private let onReport: () -> Void
    private let onRideFinished: () -> Void

    // 내 현재 위치 — 지도에 파란 점으로 계속 반영된다(1초 주기, 화면이 보이는 동안만).
    // 권한 다이얼로그는 새로 띄우지 않는다(운행 흐름을 끊지 않게 — PinAdjustOverlay 와 같은 이유).
    // 지도까지 온 사용자라면 15~19 에서 이미 허용했고, 없으면 점 없이 마커만 그린다.
    @RememberMyLocationState(autoRequestPermission: false) private var myLocation

    public init(
        repository: any RideRepository,
        partyId: Int64?,
        onBack: @escaping () -> Void = {},
        onOpenChat: @escaping () -> Void = {},
        onReport: @escaping () -> Void = {},
        onRideFinished: @escaping () -> Void = {}
    ) {
        self.repository = repository
        self.partyId = partyId
        self.onBack = onBack
        self.onOpenChat = onOpenChat
        self.onReport = onReport
        self.onRideFinished = onRideFinished
    }

    public var body: some View {
        ZStack {
            if let partyId {
                RideOngoingContent(
                    repository: repository,
                    partyId: partyId,
                    myLocation: myLocation.coordinates,
                    onBack: onBack,
                    onOpenChat: onOpenChat,
                    onReport: onReport,
                    onRideFinished: onRideFinished
                )
                // 원본 `viewModel(key = "ongoing-$partyId")` — 방이 바뀌면 뷰모델도 새로 만든다
                .id(partyId)
            } else {
                // 서버 좌표 없이도 지도는 띄운다 — 내 위치가 있으면 그 점이라도 보인다
                RideOngoingScreen(
                    myLocation: myLocation.coordinates,
                    onBack: onBack,
                    onOpenChat: onOpenChat,
                    onReport: onReport
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .myLocationEffect($myLocation)
    }
}

/// 방 id 를 아는 Route 본체. 뷰모델은 id 가 있어야 만들 수 있어 나눴다.
private struct RideOngoingContent: View {
    @HostedViewModel private var viewModel: RideOngoingViewModel
    @State private var routePath: [LatLng] = []

    private let myLocation: UserCoordinates?
    private let onBack: () -> Void
    private let onOpenChat: () -> Void
    private let onReport: () -> Void
    private let onRideFinished: () -> Void

    init(
        repository: any RideRepository,
        partyId: Int64,
        myLocation: UserCoordinates?,
        onBack: @escaping () -> Void,
        onOpenChat: @escaping () -> Void,
        onReport: @escaping () -> Void,
        onRideFinished: @escaping () -> Void
    ) {
        _viewModel = HostedViewModel(wrappedValue: RideOngoingViewModel(repository: repository, partyId: partyId))
        self.myLocation = myLocation
        self.onBack = onBack
        self.onOpenChat = onOpenChat
        self.onReport = onReport
        self.onRideFinished = onRideFinished
    }

    var body: some View {
        let viewModel = self.viewModel
        let ride = viewModel.ride
        let finished = viewModel.finished
        RideOngoingScreen(
            // 시트 상단 「{목적지}까지 약 N분」·경유 순서 카드 — 상세를 받기 전(nil)엔 일반 문구만, 카드는 숨긴다
            originName: ride?.origin,
            destinationName: ride?.destination,
            estimatedMinutes: ride?.estimatedMinutes,
            // 좌표는 범위 검증(latLngOrNull)을 거친다 — 서버 위경도 전치 결함(QA D-1) 방어, 25 와 동일 판정
            originPosition: latLngOrNull(latitude: ride?.originLat, longitude: ride?.originLng),
            destinationPosition: latLngOrNull(latitude: ride?.destinationLat, longitude: ride?.destinationLng),
            routePath: routePath,
            myLocation: myLocation,
            onBack: onBack,
            onOpenChat: onOpenChat,
            onReport: onReport
        )
        // 화면이 **보이는 동안만** 폴링한다 — 위에 27 신고가 올라오거나 앱이 백그라운드로 가면 멈추고,
        // 돌아오면 그 자리에서 첫 주기를 즉시 돈다(21 매칭 대기·17 탐색·24 채팅방과 같은 경계).
        .lifecycleEffect(
            onStart: { viewModel.onScreenStart() },
            onStop: { viewModel.onScreenStop() }
        )
        .task(id: finished) {
            if finished { onRideFinished() }
        }
        // 경로는 방 상세의 routePolyline(서버가 방 생성 시 확정한 경로)을 그대로 쓴다 — 25 와 동일.
        // 폴링이 매 주기 상세를 받아오지만 같은 값이면 ViewModel 이 흘려보내므로(shouldPublishDetail)
        // 운행 내내 한 번만 디코드한다 — 폴리라인 디코딩은 좌표 수백 개짜리 작업이고, 이 뷰는 위치가
        // 올 때마다(1초) 다시 그려져 본문에서 디코드하면 안 된다.
        .onChange(of: ride?.routePolyline, initial: true) { _, polyline in
            routePath = polyline.map { decodePolyline(encoded: $0) } ?? []
        }
    }
}

/// 운행이 끝났는가 — 33 도착 완료로 넘길 **유일한** 신호.
///
/// `RideStatus.completed`(서버 `FINISHED`) 하나만 참이다. `RideStatus.canceled` 는 **일부러 뺀다**:
/// 서버가 방을 CANCELED 로 닫는 건 기사 매칭 3분 타임아웃처럼 **탑승 전** 상황이고, 그건 25 배차 현황이
/// 「기사님을 찾지 못했어요」로 다룬다. 운행 중 화면에서 취소를 완료로 접으면 타지도 않은 운행의
/// 최종 요금 화면이 열린다 — 정상 종료는 FINISHED 뿐이다(`RideStatus` 설명).
///
/// 입력이 `RideStatus` 가 아니라 `Ride` 인 이유: 폴링이 받는 게 **방 상세뿐**이 됐다(가벼운 상태 조회가
/// 서버에서 삭제됐다 — `04f6be7`). 두 종류의 응답으로 똑같이 판정할 일이 없어졌으니 들고 있는 값 그대로
/// 받는다(25 의 `isRideStarted` 와 같은 모양).
///
/// 조회가 실패한 주기(nil)는 "아직 안 끝났다"로 본다 — 한 번의 네트워크 오류로 화면을 넘기지 않는다.
func isRideFinished(ride: Ride?) -> Bool {
    ride?.status == .completed
}

/// 완료 폴링을 지금 돌려야 하는가 — **가시성 게이트의 판정**(`RideOngoingViewModel.observeRideFinish`).
///
/// | 판정 | 조건 | 왜 |
/// |---|---|---|
/// | 돌지 않는다 | `visible` 이 false | **이 함수의 존재 이유.** 보이지 않는 화면이 8초마다 쿼리 3개짜리 상세를 부를 이유가 없다. 예전 배선(`LaunchedEffect`)은 앱 백그라운드를 잡지 못해 30분 운행에 승객 1명당 약 225회가 나갔다 — **화면에는 아무 증상이 없어** 로그·프록시로만 드러나므로 판정을 여기에 모아 못 박는다(17 탐색 `nearbyPollStep`·21 `fallbackPollStep` 과 같은 자리) |
/// | 돌지 않는다 | `finished` 가 true | 이미 33 으로 넘겼다. **기존 종료 조건** — 가시성이 다시 켜져도 되살아나면 회귀다(가시성은 스위치, 완료는 종결이다) |
/// | 돈다 | 그 밖 | 보이고, 아직 끝나지 않았다 |
///
/// 끊어도 안전한 근거는 **기다리는 전이가 서버 status 에 남아 있다**는 것이다 — 놓치는 게 아니라 늦게 보는
/// 것뿐이고, 복귀하면 루프 본문이 조회부터 시작하므로 그 지연도 없다(`RideOngoingViewModel.visible` 설명).
///
/// - Parameters:
///   - visible: 화면이 사용자에게 보이는가(`lifecycleEffect` 로 받는다)
///   - finished: 운행 완료를 이미 감지했는가(`isRideFinished`)
func shouldPollRideFinish(visible: Bool, finished: Bool) -> Bool {
    visible && !finished
}
// 「지도용 상세를 아직 못 받았을 때만 읽는다」(shouldLoadRideDetail)는 없앴다 — 폴링이 주는 게 곧
// 그 상세여서 읽을지 고를 대상이 없다. 첫 조회 실패도 다음 주기가 그냥 복구한다.
