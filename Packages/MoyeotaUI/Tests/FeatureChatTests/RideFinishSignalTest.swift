@testable import FeatureChat
import MoyeotaDomain
import Testing

/// 26 운행 중이 **33 도착 완료로 넘어가는 신호**.
///
/// 화면 안에 수동 트리거가 없고 이 전이에는 SSE 이벤트도 FCM 도 없어서(서버 SSE 발행처가
/// 참여·퇴장·종료뿐) 폴링이 유일한 근거다 — 한 번 틀리면 화면이 영영 안 넘어가거나, 타지도 않은
/// 운행의 최종 요금이 열린다.
///
/// 입력이 `Ride` 인 이유: 폴링 수단이 가벼운 상태 조회에서 **방 상세**로 바뀌었다(`/status` 가
/// 백엔드에서 삭제됐다 — `04f6be7`). 25 의 `isRideStarted` 와 같은 모양이다.
///
/// 「지도용 상세를 언제 읽는가」(`shouldLoadRideDetail`)는 사라졌다 — 폴링이 주는 게 곧 그 상세다.
struct RideFinishSignalTest {
    private func ride(status: RideStatus = .ongoing) -> Ride {
        Ride(
            id: "1", origin: "부산대", destination: "서면", departureLabel: "지금 출발",
            capacity: 2, members: [], farePerPerson: 0, totalFare: 0, status: status
        )
    }

    @Test("서버 FINISHED(COMPLETED)만 33 으로 넘긴다")
    func onlyCompletedFinishes() {
        #expect(isRideFinished(ride: ride(status: .completed)))
    }

    @Test("운행 중 상태들은 끝으로 보지 않는다")
    func ongoingStatesAreNotFinished() {
        #expect(!isRideFinished(ride: ride(status: .ongoing)))
        #expect(!isRideFinished(ride: ride(status: .dispatching)))
        #expect(!isRideFinished(ride: ride(status: .matched)))
        #expect(!isRideFinished(ride: ride(status: .recruiting)))
    }

    @Test("CANCELED 는 완료가 아니다 - 타지 않은 운행의 최종 요금을 열면 안 된다")
    func canceledIsNotFinished() {
        #expect(!isRideFinished(ride: ride(status: .canceled)))
    }

    @Test("상세 조회가 실패한 주기는 아직 안 끝난 것으로 본다")
    func failedPollIsNotFinished() {
        #expect(!isRideFinished(ride: nil))
    }
}
