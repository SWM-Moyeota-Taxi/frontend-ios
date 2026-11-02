import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 매칭방 SSE 계약 테스트 — **서버가 실제로 내보내는 문자열**을 그대로 넣는다
/// (`PartySseRegistry.subscribe` 의 `connected`, `RedisPartyChangeNotifier` 의 나머지 셋).
///
/// 이 파일이 도는 이유는 하나다: SSE 프레임의 파싱 실패는 **화면에서 "아무 일도 안 일어남"으로 보인다**.
/// 예외도, 에러 화면도 없이 대기 화면이 영원히 1명으로 남는다 — 그래서 네트워크 없이 문자열만으로
/// 계약을 못박는다(`parsePartySseFrame` 를 순수 함수로 뺀 이유).
@Suite struct PartySseEventTest {
    /// 서버가 내려보내는 UUID v7 문자열 형식 그대로. 로그인 세션의 `sub` 와 같은 값을 가정한다.
    private static let UUID_ME = "01a06145-3caf-7614-a3bd-cee6e25316b1"
    private static let UUID_OTHER = "01a06145-3caf-7614-a3bd-cee6e2531999"

    /// 구독 직후 `connected` 의 data — 방 상세(`PartyDetailResult`)를 Jackson 이 직렬화한 모양 그대로.
    private let connectedData = """
        {"id":7,"departureLat":37.5665,"departureLng":126.978,"destinationLat":37.4979,
         "destinationLng":127.0276,"departure":"서울시청","destination":"강남역","capacity":3,
         "currentMembers":2,"departureRadius":500,"destinationRadius":500,"status":"ACTIVE",
         "createdAt":"2026-10-13T09:00:00Z",
         "members":[{"publicId":"\(Self.UUID_ME)","nickname":"성윤","imageUrl":null,"badgeId":null,"rideCount":4},
                    {"publicId":"\(Self.UUID_OTHER)","nickname":"철수","imageUrl":null,"badgeId":null,"rideCount":3}],
         "estimateFare":9600,"estimateTime":14,"route":"_p~iF~ps|U","taxiDriverId":null}
        """

    private struct UnexpectedFrame: Error {
        let description: String
    }

    private func parse(_ type: String, _ data: String) throws -> PartySseEvent {
        let frame = parsePartySseFrame(type: type, data: data)
        guard case .received(let event) = frame else {
            throw UnexpectedFrame(description: "\(frame)")
        }
        return event
    }

    private func snapshot(_ event: PartyEvent) throws -> (ride: Ride, version: Int64?) {
        guard case .snapshot(let ride, let version) = event else {
            throw UnexpectedFrame(description: "\(event)")
        }
        return (ride, version)
    }

    private func joined(_ event: PartyEvent) throws -> (member: User, status: RideStatus, version: Int64?) {
        guard case .memberJoined(let member, let status, let version) = event else {
            throw UnexpectedFrame(description: "\(event)")
        }
        return (member, status, version)
    }

    private func left(_ event: PartyEvent) throws -> (publicId: String?, status: RideStatus, hostPublicId: String?, version: Int64?) {
        guard case .memberLeft(let publicId, let status, let hostPublicId, let version) = event else {
            throw UnexpectedFrame(description: "\(event)")
        }
        return (publicId, status, hostPublicId, version)
    }

    private func isSkipped(_ frame: PartySseFrame) -> Bool {
        if case .skipped = frame { return true }
        return false
    }

    @Test("connected 는 방 상세 전체를 스냅샷으로 올린다")
    func connectedIsSnapshot() throws {
        let event = try parse(EVENT_CONNECTED, connectedData).toPartyEvent(currentUuid: Self.UUID_ME)

        let snapshot = try snapshot(event)
        #expect(snapshot.ride.id == "7")
        #expect(snapshot.ride.origin == "서울시청")
        #expect(snapshot.ride.status == .recruiting)
        // 상세 조회와 똑같이 멤버·요금·경로까지 다 온다 — 그래서 catch-up 조회가 필요 없다.
        // (지문 필드는 서버가 지웠다 — `04f6be7`. 상세 응답과 같은 모양이라 여기서도 없다.)
        #expect(snapshot.ride.members.map(\.nickname) == ["성윤", "철수"])
        #expect(snapshot.ride.members.map(\.isMe) == [true, false])
        #expect(snapshot.ride.estimatedFare == 9600)
        #expect(snapshot.ride.routePolyline == "_p~iF~ps|U")
    }

    /// `ServerSentEventReader` 는 여러 줄 `data:` 를 개행문자로 이어 하나의 문자열로 준다.
    /// 서버가 pretty-print 로 바뀌어도 스냅샷이 깨지지 않아야 한다.
    @Test("여러 줄로 쪼개진 data 도 스냅샷으로 읽는다")
    func multilineDataIsSnapshot() throws {
        let multiline = "{\n  \"id\": 7,\n  \"departure\": \"서울시청\",\n  \"status\": \"ACTIVE\"\n}"

        let snapshot = try snapshot(try parse(EVENT_CONNECTED, multiline).toPartyEvent())

        #expect(snapshot.ride.id == "7")
        #expect(snapshot.ride.origin == "서울시청")
    }

    @Test("member-joined 는 들어온 멤버와 변경 후 상태를 올린다")
    func memberJoined() throws {
        let data = #"{"member":{"publicId":"\#(Self.UUID_OTHER)","nickname":"철수","imageUrl":null,"badgeId":null,"rideCount":3},"status":"ACTIVE"}"#

        let joined = try joined(try parse(EVENT_MEMBER_JOINED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(joined.member.id == Self.UUID_OTHER)
        #expect(joined.member.nickname == "철수")
        #expect(joined.member.rideCount == 3)
        #expect(!joined.member.isMe)
        #expect(joined.status == .recruiting)
    }

    /// 상세와 **같은 매퍼**를 쓰므로 "나" 판정 근거도 같다(publicId == 세션 uuid).
    @Test("내가 다른 기기로 들어온 경우도 나로 표시한다")
    func joinedFromOtherDeviceIsMe() throws {
        let data = #"{"member":{"publicId":"\#(Self.UUID_ME)","nickname":"성윤","imageUrl":null,"badgeId":null,"rideCount":4},"status":"COMPLETED"}"#

        let joined = try joined(try parse(EVENT_MEMBER_JOINED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(joined.member.isMe)
        // 마지막 자리를 채우면 서버가 그 자리에서 정원 충족까지 끝내고 그 결과를 싣는다.
        #expect(joined.status == .matched)
    }

    /// 유저 요약이 없으면 서버가 전부 null 인 member 를 싣는다 — 상세와 같은 "탈퇴한 회원" 처리.
    @Test("요약이 없는 멤버가 들어와도 신호를 올린다")
    func joinedWithoutSummary() throws {
        let data = #"{"member":{"publicId":null,"nickname":null,"imageUrl":null,"badgeId":null,"rideCount":0},"status":"ACTIVE"}"#

        let joined = try joined(try parse(EVENT_MEMBER_JOINED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(joined.member.id == "")
        #expect(joined.member.nickname == "탈퇴한 회원")
        #expect(!joined.member.isMe)
    }

    @Test("member-left 는 나간 사람의 publicId 와 변경 후 상태를 올린다")
    func memberLeft() throws {
        let data = #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE"}"#

        let left = try left(try parse(EVENT_MEMBER_LEFT, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(left.publicId == Self.UUID_OTHER)
        #expect(left.status == .recruiting)
    }

    /// **publicId 는 null 로 온다** — 탈퇴 등으로 서버가 유저 요약을 못 찾으면 그대로 null 을 싣고도
    /// 신호는 보낸다(`PartyService.leave`). 논-널로 선언했다면 이 프레임에서 파싱이 터져
    /// 그 뒤의 모든 변화를 놓친다. 화면은 이때 상세를 다시 받아야 한다.
    @Test("member-left 의 publicId 가 null 이어도 파싱이 깨지지 않는다")
    func memberLeftNullPublicId() throws {
        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":null,"status":"ACTIVE"}"#).toPartyEvent(currentUuid: Self.UUID_ME)
        )

        #expect(left.publicId == nil)
        #expect(left.status == .recruiting)
    }

    /// 빈 문자열도 null 과 같이 다룬다 — 화면이 "모름"을 한 가지 모양으로만 보게 한다.
    @Test("member-left 의 publicId 가 빈 문자열이면 null 로 접는다")
    func memberLeftEmptyPublicId() throws {
        let left = try left(try parse(EVENT_MEMBER_LEFT, #"{"publicId":"","status":"CANCELED"}"#).toPartyEvent())

        #expect(left.publicId == nil)
        #expect(left.status == .canceled)
    }

    /// **`closed` 의 data 는 JSON 이 아니라 partyId 숫자 문자열이다**(`String.valueOf(partyId)`).
    /// 역직렬화를 시도하면 실패해 종결 신호를 놓치고, 화면은 닫힌 방에 계속 매달린다.
    @Test("closed 의 data 는 숫자 문자열이지만 종결 신호로 읽는다")
    func closedWithNumericData() throws {
        #expect(try parse(EVENT_CLOSED, "42") == .closed)
        #expect(try parse(EVENT_CLOSED, "42").toPartyEvent() == .closed)
    }

    /// 서버가 이벤트 종류를 늘려도 앱이 멈추지 않아야 한다 — 모르는 이름은 건너뛴다.
    @Test("모르는 이벤트 이름은 건너뛴다")
    func unknownEventIsSkipped() throws {
        let frame = parsePartySseFrame(type: "driver-assigned", data: #"{"driverId":42}"#)

        guard case .skipped(let reason) = frame else {
            Issue.record("건너뛰지 않았다: \(frame)")
            return
        }
        #expect(reason.contains("driver-assigned"))
    }

    /// 이름이 없는 프레임(SSE 기본 이벤트 `message`)도 같은 길로 흘려보낸다.
    @Test("이벤트 이름이 없으면 건너뛴다")
    func missingEventNameIsSkipped() {
        #expect(isSkipped(parsePartySseFrame(type: nil, data: "{}")))
    }

    /// **깨진 프레임 하나로 스트림을 죽이지 않는다.** 예외를 올리면 재연결 루프가 돌고, 서버가 같은 프레임을
    /// 다시 보내면 영원히 끊겼다 붙기만 한다 — 건너뛰고 다음 스냅샷으로 보정하는 쪽이 낫다.
    @Test("깨진 JSON 은 예외가 아니라 건너뜀으로 떨어진다")
    func brokenJsonIsSkipped() {
        #expect(isSkipped(parsePartySseFrame(type: EVENT_MEMBER_JOINED, data: "not json at all")))
        #expect(isSkipped(parsePartySseFrame(type: EVENT_MEMBER_LEFT, data: #"{"publicId":}"#)))
        // connected 의 id 는 기본값이 없는 유일한 필드다 — 빠지면 스냅샷을 못 만든다(죽지는 않는다).
        #expect(isSkipped(parsePartySseFrame(type: EVENT_CONNECTED, data: #"{"departure":"서울시청"}"#)))
    }

    /// 키가 빠진 프레임도 건너뛰기보다 "요약 없는 멤버"로 살려 둔다 — 인원 증가는 전해져야 한다.
    @Test("member 키가 빠져도 입장 신호는 살린다")
    func missingMemberKeyKeepsSignal() throws {
        let joined = try joined(try parse(EVENT_MEMBER_JOINED, #"{"status":"ACTIVE"}"#).toPartyEvent())

        #expect(joined.member.nickname == "탈퇴한 회원")
        #expect(joined.status == .recruiting)
    }

    /// 모르는 상태 문자열은 상세·목록과 **같은 표**로 떨어진다 — 경로가 갈리면 화면 단계가 어긋난다.
    @Test("모르는 상태 문자열은 모집 중으로 떨어진다")
    func unknownStatusIsRecruiting() throws {
        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":"\#(Self.UUID_OTHER)","status":"SOMETHING_NEW"}"#).toPartyEvent()
        )

        #expect(left.status == .recruiting)
    }

    /// 끊김은 서버 프레임이 아니라 앱이 만든 신호다 — 도메인까지 그대로 올라간다.
    @Test("끊김 신호는 그대로 도메인으로 올라간다")
    func disconnectedPassesThrough() {
        #expect(PartySseEvent.disconnected.toPartyEvent() == .disconnected)
    }

    // ─────────────────────────────── 방장(Backend #240) ───────────────────────────────

    /// `connected` 스냅샷에도 `host` 가 실린다 — 상세 조회와 **같은 record** 이므로 당연하지만,
    /// 스냅샷이 전체 교체이기 때문에 **방장 표시의 기준선**이 바로 이 프레임이다.
    @Test("connected 스냅샷이 멤버의 host 를 그대로 올린다")
    func snapshotCarriesHost() throws {
        let data = connectedData
            .replacingOccurrences(of: #""badgeId":null,"rideCount":4"#, with: #""badgeId":null,"rideCount":4,"host":true"#)
            .replacingOccurrences(of: #""badgeId":null,"rideCount":3"#, with: #""badgeId":null,"rideCount":3,"host":false"#)

        let snapshot = try snapshot(try parse(EVENT_CONNECTED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(snapshot.ride.members.map(\.isHost) == [true, false])
        #expect(snapshot.ride.isHostedByMe)
    }

    /// **키 이름은 `isHost` 가 아니라 `host` 다**(서버 record 컴포넌트 이름 그대로). 틀리게 적으면
    /// 모르는 키라 **조용히 늘 누락**이 되므로, 틀린 이름이 먹히지 않음을 못박는다.
    @Test("isHost 라는 키는 방장으로 읽히지 않는다 — 계약 키는 host 다")
    func isHostKeyIsNotContract() throws {
        let data = """
            {"id":7,"status":"ACTIVE","members":[
                {"publicId":"\(Self.UUID_OTHER)","nickname":"철수","rideCount":0,"isHost":true}]}
            """

        let snapshot = try snapshot(try parse(EVENT_CONNECTED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        // 내가 아닌 멤버 + host 누락 → false. isHost 키를 읽었다면 true 가 됐을 것이다.
        #expect(snapshot.ride.members.count == 1)
        #expect(snapshot.ride.members.first?.isHost == false)
    }

    /// `host` 가 없는 옛 스냅샷에서도 **나만** 방장으로 떨어진다 — 근거는 `PartyMappers.toUser` 주석.
    @Test("host 가 없는 스냅샷에서는 나만 방장으로 떨어진다")
    func snapshotWithoutHostFallsBackToMe() throws {
        let snapshot = try snapshot(try parse(EVENT_CONNECTED, connectedData).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(snapshot.ride.members.map(\.isHost) == [true, false])
        #expect(snapshot.ride.isHostedByMe)
    }

    /// `member-joined` 의 본문은 Backend #240 에서 바뀌지 않았지만, 품고 있는 `MemberInfo` 에
    /// `host` 가 실려 온다(`PartyService.join` 이 `saved.isHost(memberId)` 로 채운다).
    /// 합류자는 가장 늦게 들어온 사람이라 사실상 늘 false 지만, 앱은 **서버 값을 그대로** 옮긴다.
    @Test("member-joined 의 멤버에도 host 가 실려 온다")
    func joinedCarriesHost() throws {
        let data = """
            {"member":{"publicId":"\(Self.UUID_OTHER)","nickname":"철수","imageUrl":null,
                "badgeId":null,"rideCount":3,"host":false},"status":"ACTIVE"}
            """

        let joined = try joined(try parse(EVENT_MEMBER_JOINED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(!joined.member.isHost)
    }

    /// **승계 신호** — `member-left` 의 `hostPublicId` 는 서버가 이탈을 반영한 **뒤** 읽은 방장이다.
    /// 이 값을 버리면 방장이 나간 뒤 승계된 사람이 자기 권한을 모른다(서버는 다시 보내지 않는다).
    @Test("member-left 는 승계 후 방장의 publicId 를 올린다")
    func leftCarriesHostSuccession() throws {
        let data = #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE","hostPublicId":"\#(Self.UUID_ME)"}"#

        let left = try left(try parse(EVENT_MEMBER_LEFT, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(left.publicId == Self.UUID_OTHER)
        #expect(left.hostPublicId == Self.UUID_ME)
        #expect(left.status == .recruiting)
    }

    /// 승계된 멤버의 유저 요약을 서버가 못 찾으면 `hostPublicId` 가 null 이다
    /// (`PartyService.leave` 의 `hostSummary == null`). 받는 쪽은 "새 방장을 모름"으로 다뤄야 한다.
    @Test("member-left 의 hostPublicId 가 null 이어도 파싱이 깨지지 않는다")
    func leftNullHost() throws {
        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE","hostPublicId":null}"#)
                .toPartyEvent(currentUuid: Self.UUID_ME)
        )

        #expect(left.hostPublicId == nil)
    }

    /// 옛 서버는 `hostPublicId` 를 아예 싣지 않는다 — 누락도 "모름"(null)으로 같게 떨어진다.
    @Test("hostPublicId 가 없는 member-left 도 그대로 읽는다")
    func leftMissingHost() throws {
        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE"}"#)
                .toPartyEvent(currentUuid: Self.UUID_ME)
        )

        #expect(left.publicId == Self.UUID_OTHER)
        #expect(left.hostPublicId == nil)
    }

    /// publicId 와 같은 이유로 빈 문자열까지 null 로 접는다 — "모름"은 한 가지 모양이어야 한다.
    @Test("hostPublicId 가 빈 문자열이면 null 로 접는다")
    func leftEmptyHost() throws {
        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE","hostPublicId":""}"#)
                .toPartyEvent()
        )

        #expect(left.hostPublicId == nil)
    }

    /// 누가 나갔는지 모르는 프레임(publicId null)에도 승계는 실린다 — 둘은 서로 독립이다.
    @Test("나간 사람을 몰라도 승계 후 방장은 전해진다")
    func hostSuccessionIndependentOfPublicId() throws {
        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":null,"status":"ACTIVE","hostPublicId":"\#(Self.UUID_ME)"}"#)
                .toPartyEvent(currentUuid: Self.UUID_ME)
        )

        #expect(left.publicId == nil)
        #expect(left.hostPublicId == Self.UUID_ME)
    }

    // ─── 방 순번(version) ───────────────────────────────────────────────────
    //
    // 프레임 순서가 뒤집혀 도착할 수 있어서(서버는 구독을 먼저 등록한 뒤 DB 를 읽어 connected 를
    // 보낸다) 무엇이 더 최신인지 숫자로 가려야 한다. 그 숫자가 여기서 안 넘어오면 21 대기 화면의
    // 순서 판정이 통째로 무력해지고, 낡은 스냅샷이 이미 반영한 합류를 지운다.

    /// 네 가지 프레임 중 세 가지가 순번을 싣는다(closed 는 앱이 data 를 안 읽는다).
    @Test("connected 는 방 순번을 싣는다")
    func snapshotVersion() throws {
        let data = #"{"id":7,"departure":"서울시청","status":"ACTIVE","version":42}"#

        let snapshot = try snapshot(try parse(EVENT_CONNECTED, data).toPartyEvent())

        #expect(snapshot.version == 42)
    }

    @Test("member-joined 는 반영 뒤의 순번을 싣는다")
    func joinedVersion() throws {
        let data = #"{"member":{"publicId":"\#(Self.UUID_OTHER)","nickname":"철수"},"status":"ACTIVE","version":43}"#

        let joined = try joined(try parse(EVENT_MEMBER_JOINED, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(joined.version == 43)
    }

    @Test("member-left 는 반영 뒤의 순번을 싣는다")
    func leftVersion() throws {
        let data = #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE","version":44}"#

        let left = try left(try parse(EVENT_MEMBER_LEFT, data).toPartyEvent(currentUuid: Self.UUID_ME))

        #expect(left.version == 44)
    }

    /// **순번을 모르는 옛 서버에서도 파싱이 깨지면 안 된다.** 논-널로 선언하면 그 배포를 보는 순간
    /// 모든 프레임이 건너뜀으로 떨어져 화면이 영영 안 갱신된다.
    ///
    /// 그리고 그때는 `null` 이어야 한다 — 기본값 `0` 으로 뭉개면 갓 만든 방(순번 0)과 구분이 안 되고,
    /// 뒤따르는 변경분이 전부 "틈"으로 보여 상세를 끝없이 다시 읽는다.
    @Test("순번 없는 프레임은 null 로 읽는다")
    func missingVersionIsNil() throws {
        let snapshot = try snapshot(
            try parse(EVENT_CONNECTED, #"{"id":7,"departure":"서울시청","status":"ACTIVE"}"#).toPartyEvent()
        )
        #expect(snapshot.version == nil)

        let joined = try joined(
            try parse(EVENT_MEMBER_JOINED, #"{"member":{"publicId":"\#(Self.UUID_OTHER)"},"status":"ACTIVE"}"#).toPartyEvent()
        )
        #expect(joined.version == nil)

        let left = try left(
            try parse(EVENT_MEMBER_LEFT, #"{"publicId":"\#(Self.UUID_OTHER)","status":"ACTIVE"}"#).toPartyEvent()
        )
        #expect(left.version == nil)
    }

    /// 갓 만든 방은 0 에서 시작한다 — 0 과 「없음」이 뭉개지지 않는지 고정한다.
    @Test("순번 0 은 없음과 다르다")
    func versionZeroIsNotNil() throws {
        let snapshot = try snapshot(
            try parse(EVENT_CONNECTED, #"{"id":7,"departure":"서울시청","status":"ACTIVE","version":0}"#).toPartyEvent()
        )

        #expect(snapshot.version == 0)
    }

    /// `closed` 는 이제 `{partyId, status, version}` JSON 으로 온다(옛 서버는 partyId 숫자 문자열).
    /// 앱은 둘 다 **읽지 않고** 종결 신호로만 쓰므로, 어느 모양이 와도 closed 로 떨어져야 한다.
    @Test("closed 는 본문 모양과 상관없이 종결 신호다")
    func closedRegardlessOfBody() throws {
        #expect(try parse(EVENT_CLOSED, #"{"partyId":7,"status":"CANCELED","version":9}"#).toPartyEvent() == .closed)
        #expect(try parse(EVENT_CLOSED, "7").toPartyEvent() == .closed)
    }
}
