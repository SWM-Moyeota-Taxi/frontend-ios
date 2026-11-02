import MoyeotaDomain
import Testing
@testable import MoyeotaData

/// `GET /api/v1/users/me/parties` 응답 → 도메인.
///
/// ### 왜 JSON 전문을 문자열로 박는가
/// 디코더가 모르는 키를 무시한다. 그래서 DTO 의 필드 이름이 하나만
/// 틀려도 **예외가 아니라 조용한 기본값**이 된다 — 화면에는 「0원」·빈 이름·「0명」이 뜨고
/// 아무 로그도 남지 않는다. 필드 선언을 눈으로 보는 검사로는 못 잡고, 실제 서버 문자열을
/// 디코딩해 보는 이 테스트만이 잡는다.
///
/// 아래 JSON 은 **실측 전문**이다(2026-11-01, 로컬 `:8080`, 기사 배차 흐름을 끝까지 돌려
/// FINISHED 로 만든 party 69·67). 서버가 계약을 바꾸면 이 테스트부터 깨지는 게 정상이다.
@Suite struct RideRecordMappersTest {

    /// 실측 응답(기록 2건, 마지막 페이지). 멤버 한 명이 나 자신이다.
    private let twoRecordsJson = """
        {"rides":[{"partyId":69,
          "departure":"강남역",
          "destination":"판교역",
          "pickupTime":"2026-10-31T19:15:17.550211Z",
          "dropoffTime":"2026-10-31T19:15:17.571486Z",
          "totalFare":16500,
          "farePerPerson":16500,
          "currentMembers":1,
          "members":[{"publicId":"01a19361-7771-7893-a836-273e05867193",
                      "nickname":"프로브9911",
                      "imageUrl":"https://cdn.moyeota.co.kr/profile/presets/default.png"}]},
         {"partyId":67,
          "departure":"강남역",
          "destination":"판교역",
          "pickupTime":"2026-10-31T19:14:39.245151Z",
          "dropoffTime":"2026-10-31T19:14:39.296191Z",
          "totalFare":16500,
          "farePerPerson":16500,
          "currentMembers":1,
          "members":[{"publicId":"01a19361-7771-7893-a836-273e05867193",
                      "nickname":"프로브9911",
                      "imageUrl":"https://cdn.moyeota.co.kr/profile/presets/default.png"}]}],
         "nextCursor":null,"hasNext":false}
        """

    private func decode(_ raw: String) throws -> RideRecordPageResponse {
        try decodeJSON(RideRecordPageResponse.self, raw)
    }

    /// 필드 9개 + 중첩 멤버 3개가 **이름 그대로** 실려 오는지. 이름 하나가 틀리면
    /// 조용히 기본값이 되어 화면이 거짓 숫자를 그린다.
    @Test("서버 응답 한 건이 그대로 도메인 기록이 된다")
    func mapsRecord() throws {
        let page = try decode(twoRecordsJson).toRideRecordPage(currentUuid: "01a19361-7771-7893-a836-273e05867193")

        #expect(page.records.count == 2)
        let first = try #require(page.records.first)
        #expect(first.partyId == 69)
        #expect(first.departure == "강남역")
        #expect(first.destination == "판교역")
        #expect(first.pickupTime == "2026-10-31T19:15:17.550211Z")
        #expect(first.dropoffTime == "2026-10-31T19:15:17.571486Z")
        #expect(first.totalFare == 16500)
        #expect(first.farePerPerson == 16500)
        #expect(first.memberCount == 1)

        #expect(first.members.count == 1)
        let member = try #require(first.members.first)
        #expect(member.id == "01a19361-7771-7893-a836-273e05867193")
        #expect(member.nickname == "프로브9911")
        #expect(member.imageUrl == "https://cdn.moyeota.co.kr/profile/presets/default.png")
    }

    /// 서버 정렬은 `dropoffTime desc, matchId desc` 다. 매퍼가 순서를 섞으면 최신순이 깨진다.
    @Test("서버가 준 최신순 순서를 그대로 유지한다")
    func keepsServerOrder() throws {
        let page = try decode(twoRecordsJson).toRideRecordPage(currentUuid: nil)

        #expect(page.records.map(\.partyId) == [69, 67])
    }

    /// 1차 모드(기사 없이 방장이 합승 종료)로 끝난 기록. 요금과 탑승 시각이 null 로 **남아야** 한다
    /// — 0 으로 접으면 화면이 「0원」을 그려 「공짜로 탔다」는 거짓말이 된다.
    @Test("1차 모드 기록은 요금과 탑승 시각이 비어 있다")
    func firstModeRecord() throws {
        let raw = """
            {"rides":[{"partyId":12,"departure":"부산대 정문","destination":"서면역",
              "pickupTime":null,"dropoffTime":"2026-10-20T09:03:00Z",
              "totalFare":null,"farePerPerson":null,"currentMembers":3,"members":[]}],
             "nextCursor":null,"hasNext":false}
            """

        let records = try decode(raw).toRideRecordPage(currentUuid: nil).records
        #expect(records.count == 1)
        let record = try #require(records.first)

        #expect(record.pickupTime == nil, "탑승 시각이 0 이나 빈 문자열로 접혔다")
        #expect(record.totalFare == nil, "총 요금이 0 으로 접혔다 — 화면이 「0원」을 그린다")
        #expect(record.farePerPerson == nil, "1인 부담이 0 으로 접혔다 — 화면이 「0원」을 그린다")
        // 하차 시각과 인원은 그대로 와야 한다(요금만 없는 기록이다)
        #expect(record.dropoffTime == "2026-10-20T09:03:00Z")
        #expect(record.memberCount == 3)
    }

    /// 서버가 `isMe` 를 주지 않으므로 매퍼가 publicId 비교로 만든다. 한 명만 나여야 한다.
    @Test("내 publicId 가 들어 있는 멤버만 나로 표시된다")
    func onlyMyPublicIdIsMe() throws {
        let raw = """
            {"rides":[{"partyId":5,"departure":"A","destination":"B",
              "pickupTime":null,"dropoffTime":"2026-10-20T09:03:00Z",
              "totalFare":null,"farePerPerson":null,"currentMembers":2,
              "members":[{"publicId":"me-uuid","nickname":"나","imageUrl":null},
                         {"publicId":"other-uuid","nickname":"남","imageUrl":null}]}],
             "nextCursor":null,"hasNext":false}
            """

        let records = try decode(raw).toRideRecordPage(currentUuid: "me-uuid").records
        #expect(records.count == 1)

        #expect(records[0].members.map(\.isMe) == [true, false])
    }

    /// ★ `nil == nil` 이 true 라서 **미로그인 상태에서 요약 없는 멤버가 "나"가 되는** 버그를 못 박는다.
    ///
    /// 이 묶음에서 가장 쉽게 틀리는 자리다 — `publicId == currentUuid` 만 쓰면 둘 다 null 인 조합이
    /// 통과한다. `PartyMappers` 가 같은 가드(`publicId != nil &&`)를 쓰는 이유다.
    @Test("미로그인 상태에서는 아무도 나로 표시되지 않는다")
    func signedOutNobodyIsMe() throws {
        let raw = """
            {"rides":[{"partyId":5,"departure":"A","destination":"B",
              "pickupTime":null,"dropoffTime":"2026-10-20T09:03:00Z",
              "totalFare":null,"farePerPerson":null,"currentMembers":1,
              "members":[{"publicId":null,"nickname":null,"imageUrl":null}]}],
             "nextCursor":null,"hasNext":false}
            """

        let records = try decode(raw).toRideRecordPage(currentUuid: nil).records
        #expect(records.count == 1)
        #expect(records[0].members.count == 1)
        let member = try #require(records[0].members.first)

        #expect(!member.isMe, "요약 없는 멤버가 미로그인 상태에서 「나」가 됐다")
    }

    /// 탈퇴한 동승자는 `publicId` 가 **살아 있고** 이름만 서버가 가려 보낸다. 앱이 다시 치환하지
    /// 않는다는 것 — 치환하면 「요약이 없다」와 「탈퇴했다」가 한 문자열로 합쳐져
    /// 「프로필로 들어갈 수 있는가」 판정이 사라진다(`MemberDisplay` 주석의 그 구분).
    @Test("탈퇴한 동승자는 이름이 탈퇴한 사용자로 그대로 온다")
    func withdrawnMemberKeepsServerName() {
        let member = RideRecordMemberResponse(
            publicId: "withdrawn-uuid",
            nickname: WithdrawnMemberNames.SERVER_DELETED,
            imageUrl: "https://cdn.moyeota.co.kr/profile/presets/default.png"
        ).toRideRecordMember(currentUuid: "me-uuid")

        #expect(member.id == "withdrawn-uuid")
        #expect(member.nickname == WithdrawnMemberNames.SERVER_DELETED)
        #expect(!member.isMe)
    }

    /// 요약 자체가 없는 멤버(세 필드 전부 null). 식별자가 **빈 문자열**이어야 한다 — 화면이
    /// 「탭 불가」로 다룰 근거가 그것이고(`MemberDisplay.isWithdrawn`), 이름은 앱이 채운 자리값이다.
    @Test("정보가 없는 멤버는 식별자가 빈 문자열이다")
    func memberWithoutSummary() {
        let member = RideRecordMemberResponse().toRideRecordMember(currentUuid: "me-uuid")

        #expect(member.id == "")
        #expect(member.nickname == WithdrawnMemberNames.NO_SUMMARY)
        #expect(member.imageUrl == nil)
        #expect(!member.isMe)
    }

    /// 마지막 페이지. **`hasNext=false` 인데 `nextCursor` 를 읽어 다음 페이지를 또 부르면
    /// 커서 없이 첫 페이지를 다시 받아 목록이 무한히 중복된다.**
    @Test("마지막 페이지는 다음 커서가 없다")
    func lastPageHasNoCursor() throws {
        let page = try decode(twoRecordsJson).toRideRecordPage(currentUuid: nil)

        #expect(!page.hasNext)
        #expect(page.nextCursor == nil)
    }

    /// 실측 1페이지(`size=1`): 커서는 그 페이지 **마지막 기록의 방 id** 다.
    @Test("다음 페이지가 있으면 커서가 마지막 기록의 방 id 다")
    func nextPageCursor() throws {
        let raw = """
            {"rides":[{"partyId":69,"departure":"강남역","destination":"판교역",
              "pickupTime":"2026-10-31T19:15:17.550211Z","dropoffTime":"2026-10-31T19:15:17.571486Z",
              "totalFare":16500,"farePerPerson":16500,"currentMembers":1,
              "members":[{"publicId":"u","nickname":"프로브9911","imageUrl":null}]}],
             "nextCursor":69,"hasNext":true}
            """

        let page = try decode(raw).toRideRecordPage(currentUuid: nil)

        #expect(page.hasNext)
        #expect(page.nextCursor == 69)
        #expect(page.records.last?.partyId == 69)
    }

    /// 기록이 없는 계정(실측: `moyeota2`). 빈 페이지가 예외 없이 나와야 한다.
    @Test("기록이 없으면 빈 페이지다")
    func emptyPage() throws {
        let page = try decode(#"{"rides":[],"nextCursor":null,"hasNext":false}"#)
            .toRideRecordPage(currentUuid: "me-uuid")

        #expect(page.records.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(!page.hasNext)
    }

    /// 출발·도착이 없는 응답은 **빈 문자열로 접는다** — 화면이 null 을 또 확인하지 않게.
    /// 요금과 달리 「없으면 비워 둔다」 하나뿐이라 null 을 끝까지 들고 갈 이유가 없다.
    @Test("출발지와 도착지가 없으면 빈 문자열이 된다")
    func missingEndpointsAreEmpty() throws {
        let raw = """
            {"rides":[{"partyId":5,"departure":null,"destination":null,
              "pickupTime":null,"dropoffTime":"2026-10-20T09:03:00Z",
              "totalFare":null,"farePerPerson":null,"currentMembers":1,"members":[]}],
             "nextCursor":null,"hasNext":false}
            """

        let records = try decode(raw).toRideRecordPage(currentUuid: nil).records
        #expect(records.count == 1)
        let record = try #require(records.first)

        #expect(record.departure == "")
        #expect(record.destination == "")
    }
}
