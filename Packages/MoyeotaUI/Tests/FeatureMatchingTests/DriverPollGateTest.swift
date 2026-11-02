@testable import FeatureMatching
import MoyeotaDomain
import Testing

/// 배차 폴링이 기사 정보·위치를 **배정된 뒤에만** 묻는지.
///
/// 서버 `MATCHING` 과 `DRIVER_ASSIGNED` 는 앱에서 둘 다 `RideStatus.dispatching` 이라 status 로는
/// 배정 여부를 알 수 없다. 이 게이트가 무너지면 「기사 찾는 중」 3분 동안 승객마다 5초에 한 번
/// 서버에 `DRIVER_NOT_ASSIGNED` 409 + WARN 로그가 쌓인다 — 앱 화면에는 아무 증상이 없어 서버 로그로만 드러난다.
struct DriverPollGateTest {
    private func ride(status: RideStatus, driverId: Int64?) -> Ride {
        Ride(
            id: "1",
            origin: "부산대",
            destination: "서면",
            departureLabel: "지금 출발",
            capacity: 2,
            members: [],
            farePerPerson: 0,
            totalFare: 0,
            status: status,
            driverId: driverId
        )
    }

    @Test("기사 찾는 중(MATCHING→DISPATCHING, driverId 없음)에는 기사 정보를 묻지 않는다")
    func searching() {
        let searching = ride(status: .dispatching, driverId: nil)
        #expect(!shouldFetchDriverInfo(ride: searching, alreadyLoaded: false))
        #expect(!shouldFetchDriverLocation(ride: searching))
    }

    @Test("배정되면(driverId 있음) 정보와 위치를 묻는다")
    func assigned() {
        let assigned = ride(status: .dispatching, driverId: 7)
        #expect(shouldFetchDriverInfo(ride: assigned, alreadyLoaded: false))
        #expect(shouldFetchDriverLocation(ride: assigned))
    }

    @Test("운행 중에도 driverId 가 기준이다")
    func ongoing() {
        #expect(shouldFetchDriverLocation(ride: ride(status: .ongoing, driverId: 7)))
        #expect(!shouldFetchDriverLocation(ride: ride(status: .ongoing, driverId: nil)))
    }

    @Test("기사 정보는 한 번 받으면 다시 묻지 않는다")
    func infoOnce() {
        #expect(!shouldFetchDriverInfo(ride: ride(status: .dispatching, driverId: 7), alreadyLoaded: true))
    }

    @Test("방 상세를 아직 못 받았으면 아무것도 묻지 않는다")
    func noDetail() {
        #expect(!shouldFetchDriverInfo(ride: nil, alreadyLoaded: false))
        #expect(!shouldFetchDriverLocation(ride: nil))
    }

    // ─── 가시성 게이트 ──────────────────────────────────────────────────────

    /// **25 만 이 게이트가 빠져 있었다.** 폴링이 `LaunchedEffect(viewModel) { pollDriver() }` 하나에
    /// 묶여 있었는데, `LaunchedEffect` 는 **컴포지션 이탈**에만 취소되고 **앱 백그라운드**에는
    /// 반응하지 않는다 — NavHost 컴포지션은 앱을 내려놓아도 살아 있다. 주기 7초에 호출이 2건
    /// (방 상세 + 기사 위치)이라 주머니 속에서 **분당 약 17건**이 계속 나갔다.
    ///
    /// 21 대기·17 탐색·24 채팅방은 이미 `LifecycleStartEffect` 게이트를 쓰고 있었다(QA 123 D-3).
    @Test("안 보이면 폴링하지 않는다")
    func hidden() {
        #expect(!shouldPollDispatch(visible: false, pollDone: false))
        #expect(!shouldPollDispatch(visible: false, pollDone: true))
    }

    @Test("보이고 아직 전이를 못 잡았으면 폴링한다")
    func visible() {
        #expect(shouldPollDispatch(visible: true, pollDone: false))
    }

    /// 탑승 시작을 잡아 끝난 루프는 **복귀로 되살아나지 않는다** — 가시성은 「멈췄다 다시 켜는」
    /// 스위치지만 이건 「끝났다」는 사실이다(21 의 `fallbackDone` 과 같은 자리).
    @Test("전이를 잡아 끝난 루프는 복귀해도 다시 돌지 않는다")
    func doneStaysDone() {
        #expect(shouldPollDispatch(visible: true, pollDone: false)) // 진입
        #expect(!shouldPollDispatch(visible: false, pollDone: false)) // 백그라운드
        #expect(shouldPollDispatch(visible: true, pollDone: false)) // 복귀 → 즉시 한 주기
        #expect(!shouldPollDispatch(visible: true, pollDone: true)) // IN_RIDE 감지 뒤
    }
}
