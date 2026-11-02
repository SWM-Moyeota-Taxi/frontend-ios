import MoyeotaDomain
import Testing
@testable import PresentationCore

/// 채팅방 감시 폴링(10초, `GET /chat-rooms/me`)이 **보일 때만** 도는지.
///
/// 이 루프는 앱 루트의 수명에서 돈다. 앱 루트는 **앱이 백그라운드로 가도 살아 있어서**, 진행 중인 방이 있고
/// 채팅방이 아직 없는 사용자는 어느 화면에 있든 — 앱을 내려놓아도 — 10초마다 서버를 불렀다
/// (QA 119 D-1 과 같은 성격의 누수. `120` §5 가 「가시성과 무관하게 네트워크를 때리는 루프로 남은 유일한 건」으로 지목한 자리다).
///
/// 판정을 고정한다. 「가려지면 진행 중인 조회와 대기가 실제로 죽는가」는 `ViewModelsTest` 가 본다.
@Suite struct ChatRoomPollGateTest {
    /// D-1 성격의 누수 회귀 방지 — 안 보이면 **나머지 조건을 보지 않는다.**
    @Test("안 보이면 어떤 조합에서도 폴링하지 않는다")
    func neverPollsWhenHidden() {
        let rides: [Ride?] = [
            nil,
            ride(.recruiting),
            ride(.matched),
            ride(.dispatching),
            ride(.ongoing),
            ride(.completed),
        ]
        for ride in rides {
            for roomId in [nil, Int64(7)] as [Int64?] {
                #expect(
                    !shouldPollChatRoom(visible: false, ride: ride, chatRoomId: roomId),
                    "가려진 상태에서 폴링했다 (ride=\(String(describing: ride?.status)), chatRoomId=\(String(describing: roomId)))"
                )
            }
        }
    }

    @Test("보이고 진행 중 방이 있고 채팅방을 모르면 폴링한다")
    func pollsWhenVisibleWithRide() {
        #expect(shouldPollChatRoom(visible: true, ride: ride(.matched), chatRoomId: nil))
    }

    /// 모집 중(21 대기)에도 찾는다 — 서버가 채팅방을 **합류 시점에** 만든다(Backend #109).
    /// 「정원이 차야 생긴다」던 옛 가정으로 되돌리면 1차 배포 모드(정원이 차도 대기 단계)에서
    /// 21 의 「채팅 열기」가 영영 안 뜬다.
    @Test("모집 중에도 채팅방을 찾는다")
    func pollsWhileRecruiting() {
        #expect(shouldPollChatRoom(visible: true, ride: ride(.recruiting), chatRoomId: nil))
    }

    /// 기존 종료 조건 — 찾으면 멈춘다(`pollTarget` 이 nil 이 되어 진행 중 패스가 취소된다).
    @Test("채팅방을 찾으면 멈춘다")
    func stopsOnceFound() {
        #expect(!shouldPollChatRoom(visible: true, ride: ride(.ongoing), chatRoomId: 7))
    }

    /// 「채팅방 나가기」·403 으로 캐시를 버리면(`forgetChatRoom`) 다시 찾아야 한다.
    @Test("채팅방 캐시를 버리면 다시 찾는다")
    func pollsAfterForget() {
        #expect(shouldPollChatRoom(visible: true, ride: ride(.ongoing), chatRoomId: nil))
    }

    @Test("진행 중인 방이 없으면 찾을 대상이 없다")
    func noRideNoPoll() {
        #expect(!shouldPollChatRoom(visible: true, ride: nil, chatRoomId: nil))
    }

    /// 끝난 방(`clearParty` 가 늦게 돌아 홀더에 남아 있는 경우)의 채팅방은 열어 줄 데가 없다.
    @Test("끝난 방이면 찾지 않는다")
    func finishedRideNoPoll() {
        #expect(!shouldPollChatRoom(visible: true, ride: ride(.completed), chatRoomId: nil))
        #expect(!shouldPollChatRoom(visible: true, ride: ride(.canceled), chatRoomId: nil))
    }

    private func ride(_ status: RideStatus) -> Ride {
        Ride(
            id: "7",
            origin: "성결대",
            destination: "안양역",
            departureLabel: "지금 출발",
            capacity: 4,
            members: [],
            farePerPerson: 2_000,
            totalFare: 8_000,
            status: status
        )
    }
}
