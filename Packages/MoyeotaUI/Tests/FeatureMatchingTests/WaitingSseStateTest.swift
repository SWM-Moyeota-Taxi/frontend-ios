@testable import FeatureMatching
import MoyeotaDomain
import Testing

/// 21 대기 화면이 **SSE 변경분만으로 방 상태를 만드는** 규칙.
///
/// 이 화면은 이제 평상시 서버를 주기적으로 부르지 않는다 — 들어오고 나가는 사람은 변경분으로 오고,
/// 그 변경분을 들고 있던 방에 **더하고 빼서** 화면을 만든다. 그래서 화면의 정확도가 통째로 이 함수들에 달려 있다:
/// 여기서 한 번 틀어지면 되돌릴 폴링이 없고(평상시 0회), 다음 재연결 스냅샷까지 틀린 인원이 떠 있게 된다.
///
/// 서버가 지문(fingerprint)과 상태 조회 API 를 지우면서(Backend #221) 「바뀌었나」를 싸게 묻던 장치도 사라졌다 —
/// 갱신의 근거는 이제 **스냅샷·변경분·(끊겼을 때만) 상세** 셋뿐이다.
struct WaitingSseStateTest {
    private func user(
        _ id: String,
        isMe: Bool = false,
        rideCount: Int = 0,
        isHost: Bool = false
    ) -> User {
        User(
            id: id,
            nickname: "승객\(id)",
            verifiedLabel: "",
            rating: 0.0,
            rideCount: rideCount,
            isMe: isMe,
            isHost: isHost
        )
    }

    private var me: User { user("me", isMe: true) }

    /// 원본 `me.copy(isHost = true)`
    private var hostMe: User { user("me", isMe: true, isHost: true) }

    private func ride(
        status: RideStatus = .recruiting,
        capacity: Int = 4,
        members: [User]? = nil
    ) -> Ride {
        Ride(
            id: "1",
            origin: "부산대",
            destination: "서면",
            departureLabel: "지금 출발",
            capacity: capacity,
            members: members ?? [me],
            farePerPerson: 0,
            totalFare: 0,
            status: status
        )
    }

    // ─── 입장 ───────────────────────────────────────────────────────────────

    @Test("입장 - 멤버를 더하고 서버가 준 상태로 바꾼다")
    func joinAddsMember() {
        let before = ride(status: .recruiting, members: [me])

        let after = before.withMemberJoined(member: user("u2"), status: .recruiting)

        #expect(after.members.map(\.id) == ["me", "u2"])
        #expect(after.status == .recruiting)
    }

    @Test("입장 - 마지막 자리를 채우면 서버가 실어 준 전이가 그대로 반영된다")
    func joinCarriesTransition() {
        // 서버는 정원이 차면 그 자리에서 정원 충족(동승 모드) · 배차 시작(택시 모드)까지 끝내고
        // 그 결과 상태를 member-joined 에 싣는다 — 앱이 따로 물어볼 필요가 없다.
        let before = ride(status: .recruiting, capacity: 2, members: [me])

        let completed = before.withMemberJoined(member: user("u2"), status: .matched)
        #expect(completed.status == .matched)

        let dispatching = before.withMemberJoined(member: user("u2"), status: .dispatching)
        #expect(dispatching.status == .dispatching)
    }

    @Test("입장 - 같은 publicId 는 자리를 지키며 교체한다 (인원이 부풀지 않는다)")
    func joinReplacesSameId() {
        let before = ride(members: [me, user("u2", rideCount: 3), user("u3")])

        let after = before.withMemberJoined(member: user("u2", rideCount: 9), status: .recruiting)

        #expect(after.members.map(\.id) == ["me", "u2", "u3"])
        #expect(after.members.count == 3)
        #expect(after.members[1].rideCount == 9) // 새 값으로 덮였다
    }

    @Test("입장 - isMe 는 온 그대로 쓴다 (화면이 다시 판정하지 않는다)")
    func joinKeepsIsMe() {
        // 데이터 계층이 상세와 같은 근거(publicId == 세션 uuid)로 채워 준다.
        let before = ride(members: [user("u2")])

        let after = before.withMemberJoined(member: user("me2", isMe: true), status: .recruiting)

        // 원본 `single { … }` 자리 — 같은 id 가 없거나 둘 이상이면 실패한다.
        #expect(after.members.filter { $0.id == "me2" }.map(\.isMe) == [true])
        #expect(after.members.filter { $0.id == "u2" }.map(\.isMe) == [false])
    }

    @Test("입장 - id 가 빈 멤버끼리는 같다고 보지 않는다 (구별할 근거가 없다)")
    func joinBlankIdsDiffer() {
        // 탈퇴 등으로 서버가 유저 요약을 못 만들면 publicId 가 빈 문자열로 온다.
        // 빈 id 끼리 같다고 보면 서로 다른 사람을 덮어쓴다.
        let before = ride(members: [me, user("")])

        let after = before.withMemberJoined(member: user(""), status: .recruiting)

        #expect(after.members.count == 3)
    }

    // ─── 퇴장 ───────────────────────────────────────────────────────────────

    @Test("퇴장 - publicId 로 그 한 명만 지우고 상태를 바꾼다")
    func leaveRemovesOne() {
        let before = ride(status: .matched, members: [me, user("u2"), user("u3")])

        let after = before.withMemberLeft(publicId: "u2", status: .recruiting).ride

        #expect(after.members.map(\.id) == ["me", "u3"])
        #expect(after.status == .recruiting)
    }

    @Test("퇴장 - 모르는 publicId 면 목록은 그대로 두고 상태만 반영한다")
    func leaveUnknownKeepsList() {
        // 그 사람의 입장 신호를 놓쳤다는 뜻이다. 없는 사람을 지우려 상세를 또 읽지는 않는다.
        let before = ride(status: .matched, members: [me, user("u2")])

        let after = before.withMemberLeft(publicId: "u9", status: .recruiting).ride

        #expect(after.members.map(\.id) == ["me", "u2"])
        #expect(after.status == .recruiting)
    }

    @Test("퇴장 - 빈 publicId 로는 아무도 지우지 않는다")
    func leaveBlankRemovesNobody() {
        // 요약이 없는 멤버(빈 id)들을 한꺼번에 날리는 사고를 막는다.
        let before = ride(members: [me, user(""), user("")])

        let after = before.withMemberLeft(publicId: "", status: .recruiting).ride

        #expect(after.members.count == 3)
    }

    @Test("들어왔다 나가면 원래 목록으로 돌아온다")
    func joinThenLeaveRestores() {
        let before = ride(members: [me, user("u2")])

        let after = before
            .withMemberJoined(member: user("u3"), status: .recruiting)
            .withMemberLeft(publicId: "u3", status: .recruiting)
            .ride

        #expect(after.members == before.members)
    }

    @Test("증분은 멤버와 상태만 건드린다 - 경로·요금·좌표는 스냅샷 값 그대로다")
    func deltaTouchesOnlyMembersAndStatus() {
        var before = ride()
        before.farePerPerson = 3_500
        before.totalFare = 14_000
        before.originLat = 35.23
        before.originLng = 129.08
        before.routePolyline = "abc"
        before.estimatedFare = 14_000
        before.estimatedMinutes = 21

        let joined = before.withMemberJoined(member: user("u2"), status: .recruiting)
        let left = joined.withMemberLeft(publicId: "u2", status: .recruiting).ride

        #expect(left == before)
    }

    // ─── 방장 승계 (Backend #240) ───────────────────────────────────────────

    /// **이 테스트가 깨지면 방장이 나가도 승계된 사람이 「합승 완료」를 못 본다.**
    ///
    /// 서버는 멤버가 나갈 때마다 남은 멤버 중 `min(joinedAt, memberId)` 를 방장으로 다시 정하고,
    /// 그 결과를 `member-left` 의 `hostPublicId` 로 **한 번만** 알려 준다 — 여기서 버리면 다음
    /// 재연결 스냅샷까지 승계된 사람의 화면이 낡은 채로 남는다.
    @Test("승계 - 방장이 나가면 서버가 지목한 사람이 방장이 된다")
    func successionOnHostLeave() {
        let before = ride(status: .matched, members: [user("u1", isHost: true), me, user("u3")])

        let after = before.withMemberLeft(publicId: "u1", status: .recruiting, hostPublicId: "me")

        #expect(after.ride.members.map(\.id) == ["me", "u3"])
        #expect(after.ride.members.map(\.isHost) == [true, false])
        #expect(after.ride.isHostedByMe)
        // 지목된 사람이 목록에 있었으므로 서버에 다시 물을 이유가 없다
        #expect(!after.needsDetail)
    }

    /// 승계가 나에게 오지 않았으면 내 방장 표시는 **지워져야** 한다 — 서버 말이 곧 「방장은 한 명」이다.
    @Test("승계 - 내가 아닌 사람이 방장이 되면 내 표시가 지워진다")
    func successionClearsMine() {
        let before = ride(members: [hostMe, user("u2"), user("u3")])

        let after = before.withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: "u3")

        #expect(!after.ride.isHostedByMe)
        #expect(after.ride.members.filter(\.isHost).map(\.id) == ["u3"])
        #expect(!after.needsDetail)
    }

    /// 방장이 아닌 사람이 나가면 방장은 그대로다 — 서버가 같은 publicId 를 다시 지목한다.
    @Test("승계 - 방장이 아닌 사람이 나가면 방장은 그대로다")
    func successionUnchanged() {
        let before = ride(members: [hostMe, user("u2"), user("u3")])

        let after = before.withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: "me")

        #expect(after.ride.isHostedByMe)
        #expect(after.ride.members.filter(\.isHost).count == 1)
        #expect(!after.needsDetail)
    }

    /// 서버가 새 방장을 특정하지 못하면(`hostSummary == null`) 들고 있던 표시를 **그대로 두고**
    /// 방 상세를 다시 받는다 — 서버 Swagger 가 「null 이거나 목록에 없는 publicId 면 host 표시를
    /// 바꾸지 말고 방 상세를 다시 받는다」고 적어 두었다. 모른다고 전부 false 로 밀면 반대로
    /// **진짜 방장의 표시를 지우는** 쪽이 위험하다.
    @Test("승계 - hostPublicId 가 없으면 표시를 손대지 않고 상세를 다시 읽는다")
    func successionNilKeepsAndReads() {
        let before = ride(members: [hostMe, user("u2")])

        let after = before.withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: nil)

        #expect(after.ride.isHostedByMe)
        #expect(after.needsDetail, "서버가 승계를 말하지 않았으니 상세로 확인해야 한다")

        // 빈 문자열도 같다 — "모름"은 한 가지 모양으로만 다룬다.
        let blank = before.withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: "")
        #expect(blank.ride.isHostedByMe)
        #expect(blank.needsDetail)
    }

    /// **지목된 publicId 가 목록에 없으면 표시를 바꾸지 않는다** — 서버 계약 그대로다
    /// (「단 null 이거나 목록에 없는 publicId 면 host 표시를 바꾸지 말고 방 상세를 다시 받는다 —
    /// 이벤트 순서 역전 대비」, 백엔드 `PartySseController` Swagger).
    ///
    /// 예전에는 여기서 **전원 false** 가 됐다(아무도 `$0.id == host` 가 아니므로). 그게 서버 계약과
    /// 반대이고, 역전 프레임에서 진짜 방장의 표시를 지웠다 — 아래 역전 테스트가 그 경로다.
    @Test("승계 - 목록에 없는 사람이 지목되면 표시를 손대지 않고 상세를 다시 읽는다")
    func successionUnknownKeepsAndReads() {
        let before = ride(members: [hostMe, user("u2")])

        let after = before.withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: "u9")

        #expect(after.ride.isHostedByMe, "전원 false 로 밀면 진짜 방장이 버튼을 잃는다")
        #expect(after.ride.members.filter(\.isHost).map(\.id) == ["me"])
        #expect(after.needsDetail, "서버에 다시 물어야 한다")
    }

    /// ### 프레임 순서 역전 ★ — **이 테스트가 깨지면 진짜 방장이 「합승 완료」를 영구히 잃는다**
    ///
    /// 두 멤버가 연달아 나가면 서버는 프레임 둘을 따로 발행하고, 각 프레임의 `hostPublicId` 는
    /// **그 프레임을 반영한 뒤의** 방장이다. 전송 중 순서가 뒤집히면 뒤늦게 온 프레임이
    /// **이미 나간 사람**을 방장으로 지목한다(아래 `u2`).
    ///
    /// 그때 「목록에 없으니 전원 false」로 밀면 그 순간 진짜 방장(나)의 `User.isHost` 가 지워지고
    /// 복구 수단이 없다: `hasMemberDrift` 는 **인원수만** 보므로 못 잡고(목록 길이는 맞다),
    /// SSE 가 살아 있으면 폴백 폴링도 돌지 않는다(`shouldPollFallback`).
    @Test("승계 - 프레임 순서가 역전돼도 진짜 방장은 표시를 잃지 않는다")
    func successionSurvivesReorder() {
        let before = ride(status: .matched, capacity: 3, members: [user("u1", isHost: true), user("u2"), me])

        // 나중 프레임(u2 이탈 → 승계 = me)이 먼저 도착했다
        let first = before.withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: "me")
        #expect(first.ride.isHostedByMe)
        #expect(!first.needsDetail)

        // 앞 프레임(u1 이탈 → 승계 = u2, **이미 나간 사람**)이 뒤늦게 도착했다
        let second = first.ride.withMemberLeft(publicId: "u1", status: .recruiting, hostPublicId: "u2")

        #expect(second.ride.isHostedByMe, "역전 프레임이 진짜 방장의 표시를 지우면 안 된다")
        #expect(second.needsDetail, "표시를 믿을 수 없으니 상세를 다시 읽어야 한다")
        // 이 구멍을 기존 장치로는 메울 수 없다는 근거 — 인원수는 어긋나지 않는다
        #expect(!hasMemberDrift(ride: second.ride))
    }

    /// id 가 빈 멤버(요약 없음)를 방장으로 세우지 않는다 — 빈 문자열끼리 맞아떨어지면 안 된다.
    @Test("승계 - id 가 빈 멤버는 방장이 되지 않는다")
    func successionSkipsBlankIds() {
        let before = ride(members: [me, user(""), user("")])

        let after = before.withMemberLeft(publicId: "u9", status: .recruiting, hostPublicId: "me").ride

        #expect(after.members.filter(\.isHost).map(\.id) == ["me"])
    }

    /// 승계만 반영하는 경로(`member-left` 의 publicId 가 nil 일 때 뷰모델이 쓰는 자리) —
    /// 멤버 목록은 건드리지 않고 방장 표시만 옮긴다.
    @Test("승계 - 목록을 못 고치는 프레임에서도 방장 표시는 옮긴다")
    func successionWithoutListChange() {
        let before = ride(members: [user("u1", isHost: true), me])

        let after = before.withHostSuccession(hostPublicId: "me")

        #expect(after.ride.members.map(\.id) == before.members.map(\.id))
        #expect(after.ride.isHostedByMe)
        #expect(!after.needsDetail)
    }

    /// ### delta 경로와 snapshot 경로가 같은 결과를 낸다 ★
    ///
    /// `connected` 스냅샷은 전체 교체라 서버가 계산한 `host` 가 그대로 들어온다. 증분 경로는 그 값을
    /// 쌓아서 만든다 — 두 경로가 갈리면 "재연결 전에는 방장, 후에는 아님" 같은 어긋남이 생긴다.
    ///
    /// 같을 수 있는 근거: 서버가 싣는 `hostPublicId` 는 **이탈을 반영한 뒤** 읽은 `party.hostId()` 이고,
    /// 스냅샷의 `host` 도 같은 `Party.isHost` 가 만든다. 그리고 합류는 방장을 바꿀 수 없다
    /// (합류자는 가장 늦게 들어온 사람 = `min(joinedAt)` 이 될 수 없다).
    @Test("승계 - 증분으로 만든 방장 표시가 스냅샷과 같다")
    func deltaMatchesSnapshot() {
        let before = ride(status: .matched, capacity: 3, members: [user("u1", isHost: true), me, user("u3")])

        // delta: u1(방장) 이탈 → 서버가 me 를 승계로 지목
        let delta = before.withMemberLeft(publicId: "u1", status: .recruiting, hostPublicId: "me").ride

        // snapshot: 같은 시점의 상세를 서버가 통째로 다시 내려 준 모양
        var snapshot = before
        snapshot.members = [hostMe, user("u3")]
        snapshot.status = .recruiting

        #expect(delta == snapshot)
    }

    /// 합류는 방장을 바꾸지 않는다 — 합류자는 `min(joinedAt)` 이 될 수 없다(서버 보장).
    @Test("승계 - 합류는 방장을 바꾸지 않는다")
    func joinKeepsHost() {
        let before = ride(members: [hostMe])

        let after = before.withMemberJoined(member: user("u2"), status: .recruiting)

        #expect(after.isHostedByMe)
        #expect(after.members.filter(\.isHost).count == 1)
    }

    // ─── 상세 재조회 판정 (되돌이 방지) ────────────────────────────────────

    /// 변경분 적용 뒤 상세를 읽는 사유는 둘이고 처방이 같다 — 그래서 판정도 하나다.
    ///
    /// **되돌이가 없는 근거**: 이 판정은 **이벤트 프레임에만** 걸린다. 읽어 온 상세는
    /// `MatchWaitingViewModel.readDetail` 이 화면 상태로 직접 세우고 이 판정을 다시 지나지 않으므로,
    /// 프레임 하나당 추가 조회는 최대 1건이고 그 조회가 또 조회를 부르는 길이 없다.
    @Test("재조회 - 지목된 방장을 못 맞춘 프레임은 상세를 읽는다")
    func rereadOnUnknownHost() {
        // 인원은 어긋나지 않는다(정원 4, 1명, 모집 중) — needsDetail 하나만 세워진 경우
        let delta = ride(status: .recruiting, capacity: 4, members: [me])
            .withMemberLeft(publicId: "u9", status: .recruiting, hostPublicId: "u9")

        #expect(delta.needsDetail)
        #expect(!hasMemberDrift(ride: delta.ride))
        #expect(needsDetailAfterDelta(delta: delta))
    }

    @Test("재조회 - 인원이 어긋난 프레임도 상세를 읽는다")
    func rereadOnDrift() {
        // 방장은 맞췄지만(me) 정원이 찼다는 status 에 목록이 모자란다
        let delta = ride(status: .matched, capacity: 4, members: [me])
            .withMemberLeft(publicId: "u9", status: .matched, hostPublicId: "me")

        #expect(!delta.needsDetail)
        #expect(needsDetailAfterDelta(delta: delta))
    }

    @Test("재조회 - 사유가 둘 다여도 판정은 하나다 (상세는 1회)")
    func rereadOnBoth() {
        let delta = ride(status: .matched, capacity: 4, members: [me])
            .withMemberLeft(publicId: "u9", status: .matched, hostPublicId: "u9")

        #expect(delta.needsDetail)
        #expect(hasMemberDrift(ride: delta.ride))
        #expect(needsDetailAfterDelta(delta: delta))
    }

    @Test("재조회 - 방장도 인원도 멀쩡하면 서버를 부르지 않는다")
    func noReread() {
        let delta = ride(status: .recruiting, capacity: 4, members: [hostMe, user("u2")])
            .withMemberLeft(publicId: "u2", status: .recruiting, hostPublicId: "me")

        #expect(!needsDetailAfterDelta(delta: delta))
    }

    // ─── 어긋남 감지 ────────────────────────────────────────────────────────

    @Test("어긋남 - 정원이 찼다는데 목록이 모자라면 상세로 보정한다")
    func driftMatchedShort() {
        #expect(hasMemberDrift(ride: ride(status: .matched, capacity: 4, members: [me])))
    }

    @Test("어긋남 - 정원이 찼고 목록도 찼으면 아무것도 안 한다")
    func noDriftMatchedFull() {
        let full = ride(status: .matched, capacity: 2, members: [me, user("u2")])
        #expect(!hasMemberDrift(ride: full))
    }

    @Test("어긋남 - 모집 중인데 목록이 정원을 채웠으면 상세로 보정한다")
    func driftRecruitingFull() {
        // 내 목록엔 다 찬 것처럼 보이는데 서버는 아직 모집 중이다 = 퇴장 신호를 놓쳤다.
        let stale = ride(status: .recruiting, capacity: 2, members: [me, user("u2")])
        #expect(hasMemberDrift(ride: stale))
    }

    @Test("어긋남 - 모집 중이고 자리가 남았으면 정상이다")
    func noDriftRecruiting() {
        #expect(!hasMemberDrift(ride: ride(status: .recruiting, capacity: 4, members: [me])))
    }

    @Test("어긋남 - 배차·종료 단계는 보지 않는다 (화면이 이미 넘어간다)")
    func noDriftAfterDispatch() {
        for status in [RideStatus.dispatching, .ongoing, .completed, .canceled] {
            #expect(!hasMemberDrift(ride: ride(status: status, capacity: 4, members: [me])))
        }
    }

    @Test("어긋남 - 정원을 모르는 방은 판단하지 않는다")
    func noDriftUnknownCapacity() {
        #expect(!hasMemberDrift(ride: ride(status: .recruiting, capacity: 0, members: [])))
    }

    // ─── 폴링 정책 ──────────────────────────────────────────────────────────

    @Test("폴링 - SSE 가 살아 있고 방이 떠 있으면 한 번도 부르지 않는다")
    func noPollWhenAlive() {
        #expect(!shouldPollFallback(realtimeAlive: true, hasRide: true))
    }

    @Test("폴링 - 끊긴 동안에만 폴백이 돈다")
    func pollWhenDisconnected() {
        #expect(shouldPollFallback(realtimeAlive: false, hasRide: true))
    }

    @Test("폴링 - 화면에 방이 없으면 SSE 가 살아 있어도 읽는다 (에러 화면에 갇히지 않게)")
    func pollWithoutRide() {
        // 변경분은 바탕이 있을 때만 쓸 수 있다 — 첫 조회가 실패한 채로 두면 다음 멤버 변화까지 에러다.
        #expect(shouldPollFallback(realtimeAlive: true, hasRide: false))
        #expect(shouldPollFallback(realtimeAlive: false, hasRide: false))
    }

    @Test("대기 단계는 모집 중과 정원 찬 상태뿐 - 그 밖이면 폴백을 끝낸다")
    func waitingStages() {
        #expect(isWaitingForMembers(status: .recruiting))
        #expect(isWaitingForMembers(status: .matched))
        for status in [RideStatus.dispatching, .ongoing, .completed, .canceled] {
            #expect(!isWaitingForMembers(status: status))
        }
    }
}
