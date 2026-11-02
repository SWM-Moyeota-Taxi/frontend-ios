@testable import FeatureMatching
import MoyeotaDomain
import Testing

/// 25 배차 상태가 **26 운행 중으로 넘어가는 신호**.
///
/// 화면 안에 수동 트리거가 없어 이 판정이 전이의 발화점 전부다. 게다가 이 전이에는 SSE 이벤트도 푸시도
/// 없어서(서버 SSE 발행처가 참여·퇴장·종료뿐) 폴링이 유일한 근거다 — 한 번 틀리면 승객이 택시에 타고
/// 있는데도 화면은 「기사님이 오고 있어요」에 머문다.
///
/// 26 의 `isRideFinished` 와 짝이며, 폴링 수단이 방 상세로 바뀌면서(가벼운 상태 조회가 서버에서 삭제됐다 —
/// `04f6be7`) 둘 다 `Ride` 를 받는다.
struct RideStartSignalTest {
    private func ride(_ status: RideStatus, driverId: Int64? = 7) -> Ride {
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

    @Test("서버 IN_RIDE(ONGOING)만 26 으로 넘긴다")
    func ongoingStarts() {
        #expect(isRideStarted(ride: ride(.ongoing)))
    }

    @Test("배차 단계는 아직 탑승이 아니다 - 기사가 배정돼도 board 전까지는 25 에 머문다")
    func dispatchingIsNotStarted() {
        #expect(!isRideStarted(ride: ride(.dispatching, driverId: nil)))
        #expect(!isRideStarted(ride: ride(.dispatching, driverId: 7)))
        #expect(!isRideStarted(ride: ride(.matched)))
        #expect(!isRideStarted(ride: ride(.recruiting)))
    }

    /// 3분 타임아웃으로 서버가 방을 닫은 경우다. 25 가 「기사님을 찾지 못했어요」로 다뤄야 하므로
    /// 탑승으로 접으면 안 된다 — 타지도 않은 운행 화면이 열린다.
    @Test("CANCELED 는 탑승이 아니다")
    func canceledIsNotStarted() {
        #expect(!isRideStarted(ride: ride(.canceled)))
    }

    /// 이미 끝난 방을 뒤늦게 받아도 25 → 26 전이를 다시 일으키지 않는다.
    @Test("COMPLETED 는 탑승이 아니다")
    func completedIsNotStarted() {
        #expect(!isRideStarted(ride: ride(.completed)))
    }

    @Test("조회가 실패한 주기는 아직 아닌 것으로 본다")
    func failedReadIsNotStarted() {
        #expect(!isRideStarted(ride: nil))
    }
}
