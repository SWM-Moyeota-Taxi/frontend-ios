import Foundation
import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// 서버가 내려보내는 UUID v7 문자열 형식 그대로. 로그인 세션의 `sub` 와 같은 값을 가정한다.
private let UUID_ME = "01a06145-3caf-7614-a3bd-cee6e25316b1"
private let UUID_OTHER = "01a06145-3caf-7614-a3bd-cee6e2531999"

/// 멤버 교체(인원수는 그대로)를 만들 때 쓰는 제3의 계정.
private let UUID_STRANGER = "01a06145-3caf-7614-a3bd-cee6e2531aaa"

@Suite struct PartyMappersTest {

    @Test("백엔드 PartyStatus 를 RideStatus 로 매핑한다")
    func mapsBackendPartyStatus() {
        #expect(partyStatusToRideStatus(status: "ACTIVE") == .recruiting)
        #expect(partyStatusToRideStatus(status: "COMPLETED") == .matched)
        #expect(partyStatusToRideStatus(status: "MATCHING") == .dispatching)
        #expect(partyStatusToRideStatus(status: "DRIVER_ASSIGNED") == .dispatching)
        #expect(partyStatusToRideStatus(status: "IN_RIDE") == .ongoing)
        #expect(partyStatusToRideStatus(status: "FINISHED") == .completed)
        #expect(partyStatusToRideStatus(status: "CANCELED") == .canceled)
    }

    @Test("알 수 없는 상태는 RECRUITING 으로 처리한다")
    func unknownStatusIsRecruiting() {
        #expect(partyStatusToRideStatus(status: "SOMETHING_NEW") == .recruiting)
    }

    @Test("목록 PartyItem 을 Ride 로 매핑한다")
    func mapsListItem() {
        let item = PartyListResponse.PartyItem(
            partyId: 7,
            departure: "서울시청",
            destination: "강남역",
            currentMembers: 2,
            capacity: 3,
            status: "ACTIVE"
        )

        let ride = item.toRide()

        #expect(ride.id == "7")
        #expect(ride.origin == "서울시청")
        #expect(ride.destination == "강남역")
        #expect(ride.capacity == 3)
        #expect(ride.members.count == 2)
        #expect(ride.status == .recruiting)
        // 목록 응답에는 요금/경로가 없고, 좌표는 없으면 null 로 남는다.
        #expect(ride.farePerPerson == 0)
        #expect(ride.totalFare == 0)
        #expect(ride.routePolyline == nil)
        #expect(ride.originLat == nil)
    }

    @Test("지도 범위 목록 아이템의 출발 좌표를 Ride 로 옮긴다")
    func mapsListItemOriginCoordinates() {
        let ride = PartyListResponse.PartyItem(
            partyId: 1,
            departure: "부산대 정문",
            destination: "서면역",
            currentMembers: 1,
            capacity: 3,
            status: "ACTIVE",
            departureLat: 35.2313,
            departureLng: 129.0838
        ).toRide()

        #expect(isClose(35.2313, ride.originLat, 0.00001))
        #expect(isClose(129.0838, ride.originLng, 0.00001))
        // 도착 좌표·요금·경로는 목록에 없다 — 상세에서 채운다.
        #expect(ride.destinationLat == nil)
        #expect(ride.destinationLng == nil)
        #expect(ride.routePolyline == nil)
    }

    @Test("지도 범위 목록 응답 JSON 을 실제 서버 shape 그대로 역직렬화한다")
    func decodesViewportListJSON() throws {
        // 실측: GET /api/v1/matching/rooms?swLat=35.20&swLng=129.05&neLat=35.26&neLng=129.12
        let body = """
            {"list":[{"partyId":1,"departure":"부산대 정문","destination":"서면역","currentMembers":1,
             "capacity":3,"status":"ACTIVE","departureLat":35.2313,"departureLng":129.0838}]}
            """

        let rides = try decodeJSON(PartyListResponse.self, body).list.map { $0.toRide() }

        #expect(rides.count == 1)
        #expect(rides[0].id == "1")
        #expect(rides[0].origin == "부산대 정문")
        #expect(rides[0].status == .recruiting)
        #expect(isClose(35.2313, rides[0].originLat, 0.00001))
        #expect(isClose(129.0838, rides[0].originLng, 0.00001))
    }

    @Test("목록 아이템에 좌표가 빠져도 매핑이 깨지지 않는다")
    func listItemWithoutCoordinates() throws {
        // 브랜치에 따라 전체 목록 응답에는 좌표가 없을 수 있다.
        let body = """
            {"list":[{"partyId":7,"departure":"서울시청","destination":"강남역","currentMembers":2,"capacity":3,"status":"ACTIVE"}]}
            """

        let list = try decodeJSON(PartyListResponse.self, body).list
        #expect(list.count == 1)
        let ride = list[0].toRide()

        #expect(ride.originLat == nil)
        #expect(ride.originLng == nil)
        #expect(ride.id == "7")
    }

    @Test("상세 응답을 Ride 로 매핑하고 요금 경로 기사 id 를 채운다")
    func mapsDetail() {
        let detail = detailResponse()

        let ride = detail.toRide()

        #expect(ride.id == "7")
        #expect(ride.origin == "서울시청")
        #expect(ride.destination == "강남역")
        #expect(ride.status == .dispatching)
        #expect(ride.members.count == 2)
        #expect(isClose(37.5665, ride.originLat, 0.0001))
        #expect(isClose(127.0276, ride.destinationLng, 0.0001))
        #expect(ride.estimatedFare == 9600)
        #expect(ride.estimatedMinutes == 14)
        #expect(ride.routePolyline == "_p~iF~ps|U")
        #expect(ride.driverId == 42)
        // 전체 요금은 정원으로 나눠 1인당 요금을 만든다(9600 / 3).
        #expect(ride.totalFare == 9600)
        #expect(ride.farePerPerson == 3200)
    }

    /// 방장은 **서버가 멤버마다 표시해 준다**(`MemberInfo.host`, Backend #240) — 앱이 셈하지 않는다.
    /// 예전엔 입장 시각(joinedAt)이 가장 이른 멤버를 방장으로 추정해 "방장" 닉네임을 붙였는데,
    /// 그 추정이 되살아나지 않는지 못박는다: 서버가 `joinedAt` 을 아예 없앴고(Backend #218) 방장
    /// 판정은 `Party.isHost` 하나로 들어왔으므로, 목록 순서나 첫째 원소로 방장을 **고르면 안 된다**.
    @Test("멤버 순서와 표시는 서버가 준 그대로다 — 앱이 방장을 추정하지 않는다")
    func keepsServerMemberOrder() {
        let detail = detailResponse(
            members: [
                member(publicId: UUID_OTHER, nickname: "다른사람"),
                member(publicId: UUID_ME, nickname: "성윤"),
            ]
        )

        let ride = detail.toRide()

        // 서버가 준 순서 그대로, 재정렬하거나 특별 취급하지 않는다.
        #expect(ride.members.map(\.id) == [UUID_OTHER, UUID_ME])
        #expect(ride.members.map(\.nickname) == ["다른사람", "성윤"])
        // 닉네임에 "방장" 같은 꾸밈이 붙지 않는다 — 방장 표시는 isHost 필드 하나뿐이다.
        #expect(!ride.members.contains { $0.nickname.contains("방장") })
    }

    /// 서버가 `host` 로 말해 준 방장이 그대로 `User.isHost` 가 된다.
    @Test("서버가 준 host 를 멤버의 isHost 로 옮긴다")
    func mapsHostToIsHost() {
        let detail = detailResponse(
            members: [
                member(publicId: UUID_OTHER, nickname: "다른사람", host: true),
                member(publicId: UUID_ME, nickname: "성윤", host: false),
            ]
        )

        let ride = detail.toRide(currentUuid: UUID_ME)

        #expect(ride.members.map(\.isHost) == [true, false])
        // 「내가 방장인가」의 단일 창구 — 방장은 내가 아니다.
        #expect(!ride.isHostedByMe)
    }

    /// 내가 방장이면 `isHostedByMe` 가 참이다 — 목록 순서와 무관하다.
    @Test("내가 방장이면 isHostedByMe 가 참이다 — 목록 순서와 무관하다")
    func hostedByMeIgnoresOrder() throws {
        let detail = detailResponse(
            members: [
                member(publicId: UUID_OTHER, nickname: "다른사람", host: false),
                member(publicId: UUID_ME, nickname: "성윤", host: true),
            ]
        )

        let ride = detail.toRide(currentUuid: UUID_ME)

        // 방장이 목록의 **둘째**다 — 첫째 원소를 방장으로 보던 추정이 되살아나면 여기서 깨진다.
        #expect(ride.isHostedByMe)
        let hosts = ride.members.filter(\.isHost)
        #expect(hosts.count == 1)
        #expect(hosts.first?.id == UUID_ME)
    }

    /// 세션 uuid 를 모르면 나를 특정할 수 없으므로 「내가 방장인가」는 거짓이다 —
    /// 서버가 누군가를 방장이라고 말했더라도 그게 나라는 근거가 없다.
    @Test("세션 uuid 를 모르면 방장이 있어도 내가 방장은 아니다")
    func unknownSessionIsNotHostedByMe() {
        let detail = detailResponse(members: [member(publicId: UUID_ME, host: true)])

        let ride = detail.toRide(currentUuid: nil)

        #expect(ride.members.count == 1)
        #expect(ride.members[0].isHost)
        #expect(!ride.isHostedByMe)
    }

    /// ### 서버가 `host` 를 말하지 않은 응답 ★
    /// 옛 배포를 보고 있거나 서버가 필드를 빼면 `host` 가 없다. 그때 전부 false 로 접으면
    /// **방장조차 「합승 완료」를 못 보고** 방을 끝낼 길이 사라진다(30분 만료 대기 = 복구 불가).
    /// 반대로 나를 방장으로 보면 눌러도 서버가 403 `NOT_PARTY_HOST` 로 막고 앱이 사유별 문구로
    /// 안내한다(복구됨). 그래서 누락은 **나에 대해서만** 방장으로 떨어진다.
    @Test("host 키가 빠지면 나만 방장으로 본다 — 서버 403 에 맡긴다")
    func missingHostFallsBackToMe() {
        let detail = detailResponse(
            members: [
                member(publicId: UUID_OTHER, nickname: "다른사람", host: nil),
                member(publicId: UUID_ME, nickname: "성윤", host: nil),
            ]
        )

        let ride = detail.toRide(currentUuid: UUID_ME)

        // 남에 대해서는 false — 모두에게 "방장" 표시가 붙지 않는다.
        #expect(ride.members.map(\.isHost) == [false, true])
        #expect(ride.isHostedByMe)
    }

    /// `host` 키가 아예 없는 JSON(옛 서버 응답 그대로)도 같은 길로 떨어진다 — 파싱이 깨지지 않는다.
    @Test("host 키가 없는 상세 JSON 도 파싱되고 나만 방장으로 떨어진다")
    func detailJSONWithoutHostKey() throws {
        let body = """
            {"id":7,"departure":"서울시청","destination":"강남역","capacity":3,"currentMembers":2,
             "status":"ACTIVE",
             "members":[{"publicId":"\(UUID_ME)","nickname":"성윤","badgeId":null,"rideCount":4},
                        {"publicId":"\(UUID_OTHER)","nickname":"철수","badgeId":null,"rideCount":3}]}
            """

        let ride = try decodeJSON(PartyDetailResponse.self, body).toRide(currentUuid: UUID_ME)

        #expect(ride.members.map(\.isHost) == [true, false])
        #expect(ride.isHostedByMe)
    }

    /// 서버가 `"host": null` 을 실어 보내도(원시 boolean 이라 없을 일이지만) 누락과 같게 다룬다.
    @Test("host 가 명시적 null 이어도 파싱이 깨지지 않는다")
    func explicitNullHost() throws {
        let body = """
            {"id":7,"status":"ACTIVE",
             "members":[{"publicId":"\(UUID_ME)","nickname":"성윤","rideCount":0,"host":null}]}
            """

        let ride = try decodeJSON(PartyDetailResponse.self, body).toRide(currentUuid: UUID_ME)

        #expect(ride.isHostedByMe)
    }

    /// 요약 없는 멤버(전 필드 null)에도 서버는 `host` 를 실어 준다 — 파티 쪽 데이터라 요약과 무관하다.
    /// 그래도 **나로 특정되지 않으므로** 「내가 방장인가」에는 영향이 없고, 매핑도 터지지 않아야 한다.
    @Test("요약이 없는 멤버가 방장이어도 매핑이 깨지지 않는다")
    func hostWithoutSummary() {
        let detail = detailResponse(
            members: [
                member(publicId: nil, nickname: nil, rideCount: 3, host: true),
                member(publicId: UUID_ME, nickname: "성윤", host: false),
            ]
        )

        let ride = detail.toRide(currentUuid: UUID_ME)

        #expect(ride.members[0].id == "")
        #expect(ride.members[0].nickname == "탈퇴한 회원")
        #expect(ride.members[0].isHost)
        #expect(!ride.isHostedByMe)
    }

    /// 요약도 없고 `host` 도 없는 멤버 — 폴백이 `User.isMe` 를 타므로
    /// publicId 가 null 인 멤버는 방장이 되지 않는다. 누군지 모르는 멤버를 방장으로 세우면 안 된다.
    @Test("요약도 host 도 없는 멤버는 방장이 되지 않는다")
    func noSummaryNoHostIsNotHost() {
        let detail = detailResponse(members: [member(publicId: nil, nickname: nil, host: nil)])

        let ride = detail.toRide(currentUuid: nil)

        #expect(ride.members.count == 1)
        #expect(!ride.members[0].isHost)
        #expect(!ride.isHostedByMe)
    }

    /// 서버 record 에서 **`hostId`(Long) 가 지워졌다** — 내부 PK 를 밖으로 내보내지 않는다(Backend #240).
    /// 방 수준 방장 필드를 되살리면 「목록이 말하는 방장」과 「방이 말하는 방장」이 어긋날 수 있다.
    @Test("상세 응답 DTO 에 방 수준 hostId 필드가 없다")
    func detailHasNoRoomLevelHostId() {
        let fields = fieldNames(PartyDetailResponse.CodingKeys.self)

        #expect(!fields.contains("hostId"))
        // 방장은 멤버마다 실린다 — 키 이름은 isHost 가 아니라 host 다(서버 record 컴포넌트 이름).
        let memberFields = fieldNames(PartyDetailResponse.MemberInfo.CodingKeys.self)
        #expect(memberFields.contains("host"))
        #expect(!memberFields.contains("isHost"))
    }

    /// 서버가 주는 값(닉네임·이미지·탑승 횟수)은 그대로, 주지 않는 값(별점·인증)은 지어내지 않는다.
    @Test("멤버 요약을 표시용 User 로 옮긴다")
    func mapsMemberSummary() throws {
        let detail = detailResponse(
            members: [
                member(
                    publicId: UUID_OTHER,
                    nickname: "모여타",
                    imageUrl: "https://cdn.moyeota.com/p/1.png",
                    rideCount: 12
                ),
            ]
        )

        let members = detail.toRide(currentUuid: UUID_ME).members
        #expect(members.count == 1)
        let user = try #require(members.first)

        #expect(user.id == UUID_OTHER)
        #expect(user.nickname == "모여타")
        #expect(user.imageUrl == "https://cdn.moyeota.com/p/1.png")
        #expect(user.rideCount == 12)
        // 평가 API 도 배지 매핑도 없다 — 4.9·매너 98% 같은 가짜 값이 되살아나면 여기서 깨진다.
        #expect(user.rating == 0.0)
        #expect(user.verifiedLabel == "")
        #expect(!user.isMe)
    }

    /// 탈퇴 등으로 유저 요약이 없으면 서버가 publicId·nickname·imageUrl 을 전부 null 로 내려보낸다.
    /// 그래도 방 상세는 열려야 한다 — 매핑이 터지거나 빈 닉네임이 그대로 화면에 나가면 안 된다.
    @Test("요약이 없는 멤버는 탈퇴한 회원으로 표시하고 id 를 비운다")
    func memberWithoutSummary() throws {
        let detail = detailResponse(
            members: [member(publicId: nil, nickname: nil, rideCount: 3)]
        )

        let members = detail.toRide(currentUuid: UUID_ME).members
        #expect(members.count == 1)
        let user = try #require(members.first)

        #expect(user.id == "")
        #expect(user.nickname == "탈퇴한 회원")
        #expect(user.imageUrl == nil)
        // rideCount 는 파티 쪽 데이터라 유저 요약이 없어도 채워진다.
        #expect(user.rideCount == 3)
        // publicId 가 null 이라고 "나"가 되면 안 된다 — currentUuid 가 null 인 경우까지 참이 될 수 있다.
        #expect(!user.isMe)
    }

    /// publicId 가 JWT sub 와 같은 값이라 이 비교가 곧 "나" 판정이다(기존 「나 제외」 필터 결함의 해소).
    @Test("publicId 가 세션 uuid 와 같은 멤버만 나로 표시한다")
    func onlySessionMemberIsMe() {
        let ride = detailResponse().toRide(currentUuid: UUID_ME)

        #expect(ride.members.map(\.isMe) == [true, false])
        #expect(ride.members.filter(\.isMe).count == 1)
    }

    /// 미로그인·복원 전이면 currentUserUuid 가 null 이다. 아무도 나로 표시되지 않아야 한다.
    @Test("세션 uuid 를 모르면 아무도 나로 표시하지 않는다")
    func unknownSessionNobodyIsMe() {
        let ride = detailResponse().toRide(currentUuid: nil)

        #expect(!ride.members.contains { $0.isMe })
    }

    /// 자리 표시용 멤버(목록·생성 응답)는 식별자가 없어 "나"를 알 수 없다 — 판정이 새어 들어오면 안 된다.
    @Test("자리 표시용 멤버는 나로 표시되지 않는다")
    func placeholderMembersAreNotMe() {
        let ride = PartyListResponse.PartyItem(
            partyId: 7,
            currentMembers: 2,
            capacity: 3,
            status: "ACTIVE"
        ).toRide()

        #expect(!ride.members.contains { $0.isMe })
        #expect(ride.members.map(\.nickname) == ["멤버 1", "멤버 2"])
    }

    @Test("정원이 0 이면 1인당 요금 계산이 터지지 않는다")
    func zeroCapacityFare() {
        #expect(farePerPerson(estimateFare: 9600, capacity: 0) == 0)
        #expect(farePerPerson(estimateFare: nil, capacity: 3) == 0)
    }

    /// 1인당 요금은 **10원 단위 반올림**이다(예전에는 Int 나눗셈 절삭이었다).
    ///
    /// **아래 표는 presentation 쪽 `FarePerPersonRuleTest` 와 같은 값이어야 한다.** 16 도착지 확인은
    /// 방을 만들기 전의 추정 총액을 인원으로 나누고, 19 합류·22 상세·25 배차는 이 함수가 만든 값을
    /// 쓰는데 **나누는 수가 같은 값(정원)**이라 반올림 규칙만 어긋나도 같은 방이 화면마다 다른 금액을
    /// 보여 준다 — 실제로 7,900원·3인 방이 16 에서 2,630원, 25 에서 2,633원이었다. 모듈이 달라
    /// 함수를 공유할 수 없으니 **같은 표를 양쪽에 고정**해 둔다(한쪽만 고치면 반대쪽이 깨진다).
    @Test("1인당 요금은 10원 단위로 반올림한다")
    func farePerPersonRoundsToTens() {
        #expect(farePerPerson(estimateFare: 7900, capacity: 3) == 2630) // 2633.33 → 내림
        #expect(farePerPerson(estimateFare: 8000, capacity: 3) == 2670) // 2666.67 → 올림
        #expect(farePerPerson(estimateFare: 9650, capacity: 2) == 4830) // 4825 → 올림(.5)
        #expect(farePerPerson(estimateFare: 9600, capacity: 3) == 3200) // 딱 나뉘는 값
        #expect(farePerPerson(estimateFare: 7900, capacity: 1) == 7900) // 혼자 타면 전액
    }

    /// 목록 응답에 `currentMembers` 키가 없으면 **인원을 지어내지 않는다.**
    ///
    /// 예전 DTO 기본값(0)은 「0명인 방」과 「인원을 모른다」를 한 값으로 접었다. 이 목록은 서버가
    /// `status = ACTIVE` 로만 거른 방들이라 **0명인 방은 존재할 수 없고**(최소 방장 1명), 0 으로
    /// 접으면 17 탐색 카드가 「0/3명」이라는 없는 상태를 그린다. `Ride.members` 가 비어 있다 =
    /// 인원을 모른다는 규약이고, 화면은 그때 정원만 쓴다(`headcountLabel`).
    @Test("목록 아이템에 인원 수가 없으면 인원을 지어내지 않는다")
    func listItemWithoutHeadcount() throws {
        let body = """
            {"list":[{"partyId":7,"departure":"서울시청","destination":"강남역","capacity":3,"status":"ACTIVE"}]}
            """

        let list = try decodeJSON(PartyListResponse.self, body).list
        #expect(list.count == 1)
        let ride = list[0].toRide()

        #expect(ride.members.isEmpty, "없는 멤버를 만들었다")
        #expect(ride.capacity == 3)
    }

    /// 명시적 `null` 이 섞여도 **목록 전체가 날아가지 않는다.** non-null 기본값이던 동안에는
    /// 디코더가 그 한 건에서 예외를 던져(기본값은 키 누락에만 쓰인다) 지도 목록이 통째로 비었다.
    @Test("목록에 인원 수가 null 인 방이 섞여도 나머지가 살아남는다")
    func listWithNullHeadcount() throws {
        let body = """
            {"list":[
              {"partyId":7,"departure":"서울시청","destination":"강남역","capacity":3,"status":"ACTIVE","currentMembers":null},
              {"partyId":8,"departure":"장전역","destination":"서면역","capacity":3,"status":"ACTIVE","currentMembers":2}
            ]}
            """

        let rides = try decodeJSON(PartyListResponse.self, body).list.map { $0.toRide() }

        #expect(rides.count == 2)
        #expect(rides[0].members.isEmpty, "null 을 0명으로 접었다")
        #expect(rides[1].members.count == 2)
    }

    /// 상세 응답의 `currentMembers` 가 null 이어도 **방 화면이 열린다.**
    ///
    /// 앱은 이 값을 읽지 않는다(인원의 근거는 `members` 목록이다). 그래도 non-null 로 받던 동안에는
    /// 명시적 null 하나가 상세를 통째로 파싱 실패로 만들었고, 25·26 의 주기 조회가 그 상세 하나에
    /// 걸려 있어 배차·운행 전이를 영영 못 잡는 것으로 번졌다.
    @Test("상세 응답에 인원 수가 null 이어도 상세가 열린다")
    func detailWithNullHeadcount() throws {
        let body = """
            {"id":7,"departure":"서울시청","destination":"강남역","capacity":3,"currentMembers":null,
             "status":"ACTIVE","members":[{"publicId":"\(UUID_ME)","nickname":"성윤","rideCount":0,"host":true}]}
            """

        let ride = try decodeJSON(PartyDetailResponse.self, body).toRide(currentUuid: UUID_ME)

        #expect(ride.id == "7")
        #expect(ride.status == .recruiting)
        // 인원은 members 목록이 말한다 — currentMembers 가 없어도 1명이다.
        #expect(ride.members.count == 1)
        #expect(ride.members[0].isMe)
    }

    @Test("방 생성 응답은 멤버 목록 없이 인원 수만 주므로 자리 표시용 멤버를 만든다")
    func openResponseMakesPlaceholders() {
        let response = OpenPartyResponse(
            id: 12,
            departureLat: 37.5665,
            departureLng: 126.9780,
            destinationLat: 37.4979,
            destinationLng: 127.0276,
            departure: "서울시청",
            destination: "강남역",
            capacity: 3,
            currentMembers: 1,
            departureRadius: 500,
            destinationRadius: 500,
            status: "ACTIVE",
            createdAt: "2026-08-24T09:00:00Z",
            estimateFare: 9600,
            estimateTime: 14,
            route: "_p~iF~ps|U",
            taxiDriverId: nil
        )

        let ride = response.toRide()

        #expect(ride.id == "12")
        #expect(ride.status == .recruiting)
        #expect(ride.members.count == 1)
        #expect(ride.members[0].nickname == "멤버 1")
        #expect(ride.routePolyline == "_p~iF~ps|U")
        #expect(ride.driverId == nil)
    }

    /// **인원 수를 모르면(키 누락·null) 멤버를 지어내지 않는다.**
    ///
    /// 예전에는 DTO 기본값이 0 이라 이 테스트가 「0 이면 빈다」를 확인했는데, 그 0 은 서버가 만들 수
    /// 없는 값(생성 직후엔 늘 1 = 생성자)이라 사실상 「서버가 말하지 않았다」를 확인하고 있었다.
    /// 지금은 둘을 갈라 두었으므로 **모른다**를 확인한다 — 0 인 경우는 아래 테스트가 따로 본다.
    @Test("생성 응답에 인원 수가 없으면 멤버를 지어내지 않는다")
    func openResponseWithoutHeadcount() throws {
        let ride = OpenPartyResponse(id: 12, capacity: 3, status: "ACTIVE").toRide()

        #expect(ride.members.isEmpty)

        // 명시적 null 도 같다 — 그리고 **파싱이 터지지 않는다**(non-null 이던 동안에는 예외였고,
        // 방은 이미 만들어졌는데 앱만 실패로 보는 상태가 됐다).
        let parsed = try decodeJSON(
            OpenPartyResponse.self,
            #"{"id":12,"capacity":3,"status":"ACTIVE","currentMembers":null}"#
        ).toRide()

        #expect(parsed.id == "12")
        #expect(parsed.members.isEmpty)
    }

    /// 0 이 와도 멤버를 만들지 않는다 — 0명인 방은 존재할 수 없으니 「모른다」와 같게 다룬다.
    @Test("생성 응답 인원 수가 0 이면 멤버가 빈다")
    func openResponseZeroHeadcount() {
        let ride = OpenPartyResponse(id: 12, capacity: 3, currentMembers: 0, status: "ACTIVE").toRide()

        #expect(ride.members.isEmpty)
    }

    /// 방 생성 요청 본문의 **계약**을 통째로 못 박는다 — 좌표·라벨·정원 7개 키뿐이다.
    ///
    /// 서버가 버리는 값(사용자 id·반경)이 본문에 되살아나도 응답은 200 이라 **아무 증상이 없다.**
    /// 그래서 키 목록을 여기서 고정한다: 되살아나면 "앱이 보낸 생성자/반경이 유효하다"는 착각만 남는다.
    /// - 사용자 id: 서버가 `@CurrentUser`(토큰 주체)를 쓰고 본문 `creatorId` 는 버린다.
    /// - 반경: 서버가 `OpenPartyRequest` 에서 빼고 고정값 500m 를 쓴다(Backend `a668aee`).
    @Test("생성 요청 본문에는 좌표 라벨 정원만 실린다 — 사용자 id 도 반경도 없다")
    func openRequestBodyKeys() throws {
        let dto: OpenPartyRequestDto = NewParty(
            departureLat: 37.5665,
            departureLng: 126.9780,
            destinationLat: 37.4979,
            destinationLng: 127.0276,
            departure: "서울시청",
            destination: "강남역",
            capacity: 3
        ).toRequestDto()

        #expect(dto.departure == "서울시청")
        #expect(dto.capacity == 3)

        let encoded = try encodeJSON(dto)
        #expect(!encoded.contains("creatorId"), "생성자 id 가 본문에 되살아났다: \(encoded)")
        #expect(!encoded.contains("hostId"), "생성자 id 가 본문에 되살아났다: \(encoded)")
        #expect(!encoded.contains("Radius"), "반경이 본문에 되살아났다: \(encoded)")
        #expect(!encoded.contains("radius"), "반경이 본문에 되살아났다: \(encoded)")
        // 키 집합 자체를 고정한다 — 새 필드가 몰래 끼어드는 것까지 잡는다.
        #expect(
            Set(try parseJSONObject(encoded).keys) == [
                "departureLat", "departureLng", "destinationLat", "destinationLng",
                "departure", "destination", "capacity",
            ]
        )
    }

    @Test("서버가 좌표나 요금 경로를 빠뜨려도 상세 매핑이 깨지지 않는다")
    func detailWithMissingFields() throws {
        let decoded = try decodeJSON(
            PartyDetailResponse.self,
            #"{"id":9,"departure":"성결대 정문","destination":"안양역","capacity":3,"status":"ACTIVE"}"#
        )

        let ride = decoded.toRide()

        #expect(ride.id == "9")
        #expect(ride.originLat == nil)
        #expect(ride.estimatedFare == nil)
        #expect(ride.routePolyline == nil)
        #expect(ride.driverId == nil)
        #expect(ride.members.isEmpty)
        #expect(ride.status == .recruiting)
    }

    @Test("상세 응답 JSON 을 실제 서버 shape 그대로 역직렬화한다")
    func decodesDetailJSON() throws {
        // PartyDetailResult(… members, estimateFare, estimateTime, route, taxiDriverId) 기준.
        // members 는 MemberInfo(publicId, nickname, imageUrl, badgeId, rideCount) —
        // 내부 PK memberId 와 joinedAt 은 사라졌고, 둘째 멤버는 요약이 없는(탈퇴) 경우다.
        // badgeId 는 서버 TODO 라 항상 null.
        let body = """
            {"id":7,"departureLat":37.5665,"departureLng":126.978,"destinationLat":37.4979,
             "destinationLng":127.0276,"departure":"서울시청","destination":"강남역","capacity":3,
             "currentMembers":2,"departureRadius":500,"destinationRadius":500,"status":"DRIVER_ASSIGNED",
             "createdAt":"2026-08-30T09:00:00Z",
             "members":[{"publicId":"\(UUID_ME)","nickname":"성윤","imageUrl":null,"badgeId":null,
                         "rideCount":4},
                        {"publicId":null,"nickname":null,"imageUrl":null,"badgeId":null,
                         "rideCount":0}],
             "estimateFare":9600,"estimateTime":14,"route":"_p~iF~ps|U","taxiDriverId":42}
            """

        let decoded = try decodeJSON(PartyDetailResponse.self, body)
        let ride = decoded.toRide(currentUuid: UUID_ME)

        // 서버는 아직 반경을 내려보낸다(고정 500m) — DTO 는 그 모양대로 받는다.
        #expect(decoded.departureRadius == 500)
        #expect(decoded.destinationRadius == 500)
        #expect(ride.id == "7")
        #expect(ride.status == .dispatching)
        #expect(ride.members.map(\.id) == [UUID_ME, ""])
        #expect(ride.members.map(\.nickname) == ["성윤", "탈퇴한 회원"])
        #expect(ride.members.map(\.rideCount) == [4, 0])
        #expect(ride.members.map(\.isMe) == [true, false])
        #expect(ride.driverId == 42)
        #expect(ride.estimatedFare == 9600)
    }

    /// 서버가 `memberId`·`joinedAt` 으로 되돌아가거나 새 필드를 얹어도 방 상세가 열리는 건 지켜야 한다
    /// (모르는 키 무시 + 전 필드 기본값). 파싱이 터지면 21/25 화면이 통째로 죽는다.
    @Test("멤버 항목에 모르는 필드가 있거나 필드가 빠져도 파싱이 깨지지 않는다")
    func memberWithUnknownOrMissingFields() throws {
        let body = """
            {"id":9,"departure":"성결대 정문","destination":"안양역","capacity":3,"status":"ACTIVE",
             "members":[{"memberId":1,"publicId":"\(UUID_OTHER)","nickname":"모여타","unknown":"x"},
                        {"joinedAt":"2026-08-30T09:01:00Z"}]}
            """

        let ride = try decodeJSON(PartyDetailResponse.self, body).toRide(currentUuid: UUID_ME)

        #expect(ride.members.map(\.id) == [UUID_OTHER, ""])
        #expect(ride.members.map(\.rideCount) == [0, 0])
    }

    @Test("목록 응답 JSON 을 실제 서버 shape 그대로 역직렬화한다")
    func decodesListJSON() throws {
        let body = """
            {"list":[{"partyId":7,"departure":"서울시청","destination":"강남역","currentMembers":2,"capacity":3,"status":"ACTIVE"}]}
            """

        let decoded = try decodeJSON(PartyListResponse.self, body)

        #expect(decoded.list.count == 1)
        #expect(decoded.list[0].toRide().id == "7")
    }

    @Test("기사 요약 응답을 도메인 모델로 매핑한다")
    func mapsDriverSummary() throws {
        // 서버 DriverSummary(seats, plateNumber, type) — 이름/별점 필드가 없다.
        let decoded = try decodeJSON(
            DriverSummaryResponse.self,
            #"{"seats":4,"plateNumber":"12가 3456","type":"쏘나타"}"#
        )

        let driver = decoded.toAssignedDriver()

        #expect(driver.seats == 4)
        #expect(driver.plateNumber == "12가 3456")
        #expect(driver.vehicleType == "쏘나타")
    }

    @Test("기사 요약에 좌석 수가 없어도 매핑이 깨지지 않는다")
    func driverSummaryWithoutSeats() throws {
        let driver = try decodeJSON(DriverSummaryResponse.self, #"{"plateNumber":"99하 1111"}"#)
            .toAssignedDriver()

        #expect(driver.seats == nil)
        #expect(driver.vehicleType == "")
    }

    @Test("경로 미리보기 요청 본문 필드명이 백엔드 RouteRequest 와 일치한다")
    func routeRequestBody() throws {
        // 백엔드 record RouteRequest(departureLat, departureLng, destinationLat, destinationLng).
        // 이름이 하나라도 어긋나면 Spring 이 0.0 으로 바인딩해 엉뚱한 경로가 나온다.
        let body = try encodeJSON(
            routeRequestDto(
                departureLat: 35.2313,
                departureLng: 129.0838,
                destinationLat: 35.1580,
                destinationLng: 129.0594
            )
        )

        #expect(
            body == #"{"departureLat":35.2313,"departureLng":129.0838,"#
                + #""destinationLat":35.158,"destinationLng":129.0594}"#
        )
    }

    @Test("경로 응답의 path 를 encodedPath 로 옮긴다")
    func mapsRouteEstimatePath() throws {
        // 서버 RouteEstimate(estimateFare, estimateTime, path) — path 는 인코딩된 폴리라인.
        let decoded = try decodeJSON(
            RouteEstimateResponse.self,
            #"{"estimateFare":9600,"estimateTime":14,"path":"_p~iF~ps|U_ulLnnqC"}"#
        )

        let estimate = decoded.toRouteEstimate()

        #expect(estimate.estimatedFare == 9600)
        #expect(estimate.estimatedMinutes == 14)
        #expect(estimate.encodedPath == "_p~iF~ps|U_ulLnnqC")
    }

    @Test("경로 응답이 비어도 기본값으로 방어한다")
    func emptyRouteEstimate() {
        let estimate = RouteEstimateResponse().toRouteEstimate()

        #expect(estimate.estimatedFare == 0)
        #expect(estimate.estimatedMinutes == 0)
        #expect(estimate.encodedPath == "")
    }

    // ---- 합류 응답(POST /matching/rooms/{partyId}/join) ----
    //
    // 이 DTO 의 쓰임은 **합류 응답 하나뿐**이다. 예전에는 폴링용 상태 조회
    // `GET /matching/rooms/{partyId}/status` 도 같은 모양이었지만 백엔드가 그 엔드포인트와
    // 지문(fingerprint)을 함께 삭제했다(`04f6be7`) — 매칭방 변화가 SSE 전용이 되면서
    // 「요약이 상세와 같은가」를 비교할 이유가 없어졌다.

    /// 합류 응답은 상세와 **같은 상태 변환표**를 써야 한다(`partyStatusToRideStatus`) —
    /// 갈리면 합류 직후 상태와 방 상세가 같은 방을 서로 다른 단계로 보여 준다.
    @Test("합류 응답을 도메인 PartyStatus 로 매핑한다")
    func mapsJoinResponse() {
        let status = PartyStatusResponse(
            status: "DRIVER_ASSIGNED",
            currentMembers: 3
        ).toPartyStatus()

        #expect(status.status == .dispatching)
        #expect(status.currentMembers == 3)
    }

    /// **합류 응답이 이 모양으로 바뀌었다**(Backend #213) — 방 상세가 아니라 상태·인원 두 값뿐이고,
    /// `04f6be7` 에서 지문까지 빠져 **정확히 두 값**이다.
    ///
    /// 예전 응답(방 상세)을 기대하던 DTO 로는 이 본문이 **역직렬화에서 터졌다** — `PartyDetailResponse.id`
    /// 가 기본값 없는 유일한 필드라서다. 서버는 이미 멤버를 추가해 둔 상태라 그 실패가 곧
    /// "어떤 방에도 못 들어가는" 계정을 만들었다(RemoteRideRepository.recoverMembership 참고).
    @Test("합류 응답 JSON 을 실제 서버 shape 그대로 역직렬화한다")
    func decodesJoinResponseJSON() throws {
        // 백엔드 PartyController.join → PartyStatusResponse(status, currentMembers). 내가 마지막 자리를
        // 채운 경우(서버가 그 자리에서 정원 충족까지 끝내고 COMPLETED 를 돌려준다).
        let body = #"{"status":"COMPLETED","currentMembers":3}"#

        let status = try decodeJSON(PartyStatusResponse.self, body).toPartyStatus()

        #expect(status.status == .matched)
        #expect(status.currentMembers == 3)
    }

    /// 합류 응답의 필드가 **딱 둘**인 것을 못박는다 — 지문이 다시 생기면 비교할 짝(상세의 지문)이 없는
    /// 죽은 필드가 되고, 「요약과 상세를 비교한다」는 사라진 설계가 코드에 되살아난다.
    @Test("합류 응답 DTO 에는 상태와 인원 두 필드만 있다")
    func joinResponseHasTwoFields() {
        #expect(fieldNames(PartyStatusResponse.CodingKeys.self) == ["status", "currentMembers"])
    }

    /// 합류 응답의 인원이 null 이어도 **파싱이 깨지지 않는다** — 이 응답에서의 파싱 실패 대가가 가장
    /// 크다: 서버는 멤버 추가를 **먼저 커밋**하고 응답을 만들므로, 앱이 응답을 못 읽으면 서버에는
    /// 내가 들어가 있는데 앱은 실패로 보고, 그 계정은 30분 스윕 전까지 어떤 방에도 못 들어간다.
    ///
    /// 도메인 `PartyStatus.currentMembers` 가 non-null 이라 0 으로 떨어지는데, 이 값을 읽는 화면이
    /// 없어서(21 매칭 대기는 SSE 첫 스냅샷을 믿는다) 그 0 이 화면에 나가지는 않는다.
    @Test("합류 응답에 인원 수가 null 이어도 상태를 읽는다")
    func joinResponseWithNullHeadcount() throws {
        let status = try decodeJSON(
            PartyStatusResponse.self,
            #"{"status":"ACTIVE","currentMembers":null}"#
        ).toPartyStatus()

        #expect(status.status == .recruiting)
        #expect(status.currentMembers == 0)
    }

    /// 롤아웃 중 서버가 아직 옛 버전이라 `fingerprint` 를 실어 보내도 합류가 깨지지 않아야 한다 —
    /// 디코더가 모르는 키를 무시한다(`MoyeotaJSON`). 합류는 서버가 **멤버 추가를 먼저 커밋**하므로,
    /// 여기서 파싱이 터지면 그 계정은 30분 스윕 전까지 어떤 방에도 못 들어간다.
    @Test("옛 서버가 지문을 실어 보내도 합류 응답 파싱이 깨지지 않는다")
    func joinResponseWithLegacyFingerprint() throws {
        let status = try decodeJSON(
            PartyStatusResponse.self,
            #"{"status":"FINISHED","currentMembers":3,"fingerprint":"9f3c1a7b4e2d0586","memberIds":[1,2,3]}"#
        ).toPartyStatus()

        #expect(status.status == .completed)
        #expect(status.currentMembers == 3)
    }

    // ---- 상세 응답에 지문이 없다 ----

    /// 옛 서버의 상세 응답이 지문을 실어 보내도 **조용히 무시**돼야 한다. 25·26 의 주기 조회가
    /// 이 상세로 옮겨왔으므로, 여기서 파싱이 터지면 두 화면이 배차·운행 전이를 영영 못 잡는다.
    @Test("옛 서버가 지문을 실어 보내도 상세 매핑이 깨지지 않는다")
    func detailWithLegacyFingerprint() throws {
        let body = """
            {"id":7,"departure":"서울시청","destination":"강남역","capacity":3,"currentMembers":3,
             "status":"MATCHING","fingerprint":"9f3c1a7b4e2d0586"}
            """

        let ride = try decodeJSON(PartyDetailResponse.self, body).toRide()

        #expect(ride.id == "7")
        #expect(ride.status == .dispatching)
    }

    /// 상세 DTO 에 지문 필드가 **되살아나지 않는 것**을 못박는다. 서버가 지웠으니 되살리면 항상 null 인
    /// 필드가 되고, 그 null 을 근거로 「바뀌었나」를 판정하던 옛 분기가 따라 돌아온다
    /// (「지문이 없으면 매 주기 상세를 읽는다」 같은 예외 조건).
    @Test("상세 응답 DTO 에 지문 필드가 없다")
    func detailHasNoFingerprint() {
        let fields = fieldNames(PartyDetailResponse.CodingKeys.self)

        #expect(!fields.contains("fingerprint"), "PartyDetailResponse 에 fingerprint 가 되살아났다")
        // 폴링이 읽는 값들은 그대로 있어야 한다 — 상세가 25·26 의 유일한 전이 근거다.
        #expect(Set(fields).isSuperset(of: ["status", "members", "taxiDriverId", "route"]))
    }

    /// 같은 방의 상세를 두 번 매핑하면 **`==` 로 같다**는 것 — 25·26 폴링이 「안 바뀌었다」를 판정하는
    /// 유일한 근거가 이 동등성이다(지문이 하던 일을 `Ride` 의 Equatable 이 대신한다).
    ///
    /// 멤버가 교체되면(인원수는 같다) 달라야 한다 — 요약 비교로는 못 잡아 지문이 필요했던 바로 그 경우가,
    /// 받는 게 상세가 된 지금은 equals 로 그냥 잡힌다.
    @Test("같은 방의 상세를 두 번 매핑하면 서로 같고 멤버가 교체되면 달라진다")
    func rideEquality() {
        let held = detailResponse().toRide(currentUuid: UUID_ME)
        let same = detailResponse().toRide(currentUuid: UUID_ME)
        let swapped = detailResponse(
            members: [
                member(publicId: UUID_ME, nickname: "성윤"),
                member(publicId: UUID_STRANGER, nickname: "새로온사람"),
            ]
        ).toRide(currentUuid: UUID_ME)

        #expect(held == same)
        // 인원수가 같아도 멤버가 바뀌면 다른 방 상태다(한 명 나가고 한 명 들어온 경우).
        #expect(held.members.count == swapped.members.count)
        #expect(held != swapped)
    }

    private func detailResponse(
        members: [PartyDetailResponse.MemberInfo] = [
            PartyMappersTest.member(publicId: UUID_ME, nickname: "성윤"),
            PartyMappersTest.member(publicId: UUID_OTHER, nickname: "다른사람"),
        ]
    ) -> PartyDetailResponse {
        PartyDetailResponse(
            id: 7,
            departureLat: 37.5665,
            departureLng: 126.9780,
            destinationLat: 37.4979,
            destinationLng: 127.0276,
            departure: "서울시청",
            destination: "강남역",
            capacity: 3,
            currentMembers: members.count,
            departureRadius: 500,
            destinationRadius: 500,
            status: "MATCHING",
            createdAt: "2026-08-17T09:00:00Z",
            members: members,
            estimateFare: 9600,
            estimateTime: 14,
            route: "_p~iF~ps|U",
            taxiDriverId: 42
        )
    }

    private func member(
        publicId: String? = UUID_ME,
        nickname: String? = "성윤",
        imageUrl: String? = nil,
        rideCount: Int = 0,
        host: Bool? = nil
    ) -> PartyDetailResponse.MemberInfo {
        Self.member(publicId: publicId, nickname: nickname, imageUrl: imageUrl, rideCount: rideCount, host: host)
    }

    /// `host` 기본값이 null 인 건 **옛 테스트들이 쓰던 모양 그대로**를 뜻한다(서버가 `host` 를 말하지
    /// 않은 응답). 방장을 보는 테스트만 명시적으로 true/false 를 넘긴다.
    private static func member(
        publicId: String?,
        nickname: String?,
        imageUrl: String? = nil,
        rideCount: Int = 0,
        host: Bool? = nil
    ) -> PartyDetailResponse.MemberInfo {
        PartyDetailResponse.MemberInfo(
            publicId: publicId,
            nickname: nickname,
            imageUrl: imageUrl,
            badgeId: nil,
            rideCount: rideCount,
            host: host
        )
    }
}
