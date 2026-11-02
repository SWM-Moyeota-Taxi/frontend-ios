import MoyeotaDomain
import Testing
@testable import PresentationCore

/// 25 배차 상태 · 26 운행 중의 **방 상세 폴링** 규칙.
///
/// 두 화면은 상태·인원·지문만 담은 가벼운 `/status` 를 읽고 **지문이 달라진 주기에만** 상세를
/// 재조회했다. 백엔드가 그 엔드포인트와 지문을 지우면서(`04f6be7`) 폴링 수단이 방 상세로 바뀌었고,
/// 「안 바뀌었으면 재조회 생략」은 원리적으로 불가능해졌다(바뀌었는지 알려면 상세를 받아야 한다).
/// 남은 규칙이 둘이다: **간격을 벌린다**, 그리고 **같은 값이면 화면을 갱신하지 않는다**.
@Suite struct PartyDetailPollingTest {
    private func member(_ id: String) -> User {
        User(id: id, nickname: "멤버 \(id)", verifiedLabel: "", rating: 0.0, rideCount: 0)
    }

    private func ride(
        status: RideStatus = .dispatching,
        driverId: Int64? = nil,
        memberIds: [String] = ["a", "b"]
    ) -> Ride {
        Ride(
            id: "1", origin: "부산대", destination: "서면", departureLabel: "지금 출발",
            capacity: 2, members: memberIds.map(member), farePerPerson: 0, totalFare: 0,
            status: status, driverId: driverId
        )
    }

    @Test("아직 아무것도 못 받았으면 반영한다 - 첫 조회 실패에서 폴링이 복구된다")
    func publishesWhenNothingHeld() {
        #expect(shouldPublishDetail(held: nil, fetched: ride()))
    }

    /// 이게 이 함수의 존재 이유다 — 평상시엔 매 주기 같은 상세가 오고, 그대로 넣으면 7~8초마다 다시 그린다.
    @Test("같은 상세가 다시 오면 반영하지 않는다")
    func skipsSameDetail() {
        #expect(!shouldPublishDetail(held: ride(), fetched: ride()))
    }

    @Test("상태가 바뀌면 반영한다 - 탑승 시작과 운행 완료가 여기서 보인다")
    func publishesStatusChange() {
        let held = ride(status: .dispatching)
        #expect(shouldPublishDetail(held: held, fetched: ride(status: .ongoing)))
        #expect(shouldPublishDetail(held: held, fetched: ride(status: .canceled)))
    }

    /// 기사 배정(`MATCHING` → `DRIVER_ASSIGNED`)은 **status 가 바뀌지 않는다** — 앱에서는 둘 다
    /// `RideStatus.dispatching` 이고 인원도 같다. 달라지는 건 `taxiDriverId` 하나뿐이라, 요약만 받던
    /// 옛 구조에서는 지문이 없으면 이 전이를 영영 못 봤다. 상세를 직접 받는 지금은 그냥 잡힌다.
    @Test("기사 배정은 상태가 그대로여도 반영한다 - driverId 만 달라지는 전이다")
    func publishesDriverAssignment() {
        let searching = ride(status: .dispatching, driverId: nil)
        let assigned = ride(status: .dispatching, driverId: 7)

        #expect(shouldPublishDetail(held: searching, fetched: assigned))
        #expect(!shouldPublishDetail(held: assigned, fetched: assigned))
    }

    /// 지문(서버 fingerprint)이 애초에 왜 있었나 — 요약(상태·인원수)으로는 「한 명 나가고 한 명 들어온」
    /// 변화를 못 잡기 때문이다. 받는 게 곧 상세가 된 지금은 `Ride` 의 `==` 가 멤버 목록까지
    /// 깊이 비교하므로 **지문 없이도 잡힌다** — 지문을 되살릴 이유가 없다는 근거가 이 테스트다.
    @Test("인원수가 같아도 멤버가 교체되면 반영한다 - 지문이 하던 일이다")
    func publishesMemberSwap() {
        let held = ride(memberIds: ["a", "b"])
        let swapped = ride(memberIds: ["a", "c"])

        #expect(shouldPublishDetail(held: held, fetched: swapped))
    }

    @Test("인원이 늘거나 줄면 반영한다")
    func publishesHeadcountChange() {
        let held = ride(memberIds: ["a", "b"])
        #expect(shouldPublishDetail(held: held, fetched: ride(memberIds: ["a", "b", "c"])))
        #expect(shouldPublishDetail(held: held, fetched: ride(memberIds: ["a"])))
    }

    // 아래 둘은 FeatureMatching·FeatureChat 의 상수를 본다. 기능 모듈은 이 테스트 타깃에서 import 할 수 없어
    // 소스에서 값을 읽는다. 해당 Route 가 아직 포팅되지 않았으면 건너뛴다.
    private static let routesPorted = SourceTree.exists("FeatureMatching/DispatchStatusRoute.swift")
        && SourceTree.exists("FeatureChat/RideOngoingRoute.swift")

    /// 간격이 조용히 옛 값(25: 5초, 26: 4초)으로 돌아가는 걸 막는다.
    ///
    /// 수단이 쿼리 1개짜리 상태 조회에서 **쿼리 3개짜리 방 상세**로 바뀌었으므로, 옛 간격을 그대로 쓰면
    /// 쿼리 부하가 3배가 된다(25: 0.20 → 0.60 q/s, 26: 0.25 → 0.75 q/s). 화면만 보면 아무 증상이 없어
    /// 서버 부하로만 드러나는 종류의 회귀라 숫자로 못박는다 — 근거는
    /// `PARTY_DETAIL_POLL_FLOOR_MS` 주석의 부하 표.
    @Test(
        "두 화면의 폴링 간격이 하한 아래로 내려가지 않는다",
        .enabled(if: routesPorted, "25·26 Route 가 아직 포팅되지 않았다")
    )
    func intervalsAboveFloor() throws {
        let driver = try #require(SourceTree.int64Constant("DRIVER_POLL_INTERVAL_MS", under: "FeatureMatching"))
        let ride = try #require(SourceTree.int64Constant("RIDE_POLL_INTERVAL_MS", under: "FeatureChat"))
        #expect(driver >= PARTY_DETAIL_POLL_FLOOR_MS, "25 배차 폴링이 \(driver)ms — 상세는 쿼리 3개짜리 호출이다")
        #expect(ride >= PARTY_DETAIL_POLL_FLOOR_MS, "26 운행 폴링이 \(ride)ms — 상세는 쿼리 3개짜리 호출이다")
    }

    /// 25 가 26 보다 **짧은** 이유를 고정한다: 25 는 같은 루프에서 기사 위치도 물어 이 간격이 곧 마커
    /// 갱신 주기다(40km/h 면 한 걸음에 약 78m). 26 은 지도에 움직일 마커가 없어 더 벌릴 수 있다.
    /// 뒤바뀌면 "왜 이 값인가"의 근거가 사라진다.
    @Test(
        "마커가 움직이는 25 가 26 보다 짧게 돈다",
        .enabled(if: routesPorted, "25·26 Route 가 아직 포팅되지 않았다")
    )
    func dispatchPollsFasterThanRide() throws {
        let driver = try #require(SourceTree.int64Constant("DRIVER_POLL_INTERVAL_MS", under: "FeatureMatching"))
        let ride = try #require(SourceTree.int64Constant("RIDE_POLL_INTERVAL_MS", under: "FeatureChat"))
        #expect(driver <= ride)
    }
}
