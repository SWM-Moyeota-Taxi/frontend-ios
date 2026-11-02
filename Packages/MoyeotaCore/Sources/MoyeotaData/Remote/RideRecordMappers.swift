import MoyeotaDomain

extension RideRecordPageResponse {
    /// 탑승 기록 응답 → 도메인 모델.
    ///
    /// `currentUuid` 는 `UserSession.currentUserUuid` 다. 서버가 멤버마다 `isMe` 를 주지 않으므로
    /// `publicId` 비교로 직접 만든다 — 방 상세 매퍼(`PartyMappers.swift` 의 `toUser`)와 **같은 근거**이고,
    /// 액세스 토큰 `sub` 가 publicId 와 같은 값이라 이 비교가 곧 「나」다(실측 확인).
    ///
    /// 미로그인(null)이면 전원 false 이고 그게 맞다 — 기록 화면은 로그인 뒤에만 열린다.
    public func toRideRecordPage(currentUuid: String?) -> RideRecordPage {
        RideRecordPage(
            records: rides.map { $0.toRideRecord(currentUuid: currentUuid) },
            // hasNext 가 false 면 서버가 항상 null 을 주지만, 그 약속을 매퍼가 다시 못 박지는 않는다
            // — 값을 그대로 옮기고 「언제 다음 페이지를 부르는가」의 판정은 hasNext 하나로 모은다.
            nextCursor: nextCursor,
            hasNext: hasNext
        )
    }
}

extension RideRecordResponse {
    /// 기록 한 건. **요금과 탑승 시각의 null 을 0 이나 빈 문자열로 접지 않는다** — null 은 1차 모드
    /// (기사 없이 방장이 합승 종료)라는 **뜻 있는 값**이고, 0 으로 접으면 화면이 「0원」을 그린다.
    ///
    /// 반대로 `departure`·`destination` 은 빈 문자열로 접는다
    /// — 그 둘이 없을 때 화면이 할 수 있는 일이 「비워 둔다」 하나뿐이라 null 을 끝까지 들고 갈 이유가
    /// 없다(요금처럼 「그리지 않는다」와 「0원」이 갈리는 자리가 아니다).
    public func toRideRecord(currentUuid: String?) -> RideRecord {
        RideRecord(
            partyId: partyId,
            departure: departure ?? "",
            destination: destination ?? "",
            pickupTime: pickupTime,
            dropoffTime: dropoffTime,
            totalFare: totalFare,
            farePerPerson: farePerPerson,
            memberCount: currentMembers,
            members: members.map { $0.toRideRecordMember(currentUuid: currentUuid) }
        )
    }
}

extension RideRecordMemberResponse {
    /// 동승자 한 명.
    ///
    /// ### `publicId != nil` 가드가 먼저 와야 하는 이유
    /// 사용자 요약이 없는 멤버는 세 필드가 **전부 null** 로 온다. 그 상태에서 미로그인
    /// (`currentUuid` 가 null)이면 `publicId == currentUuid` 가 `nil == nil` 이라 **true** 가 되고,
    /// 요약 없는 남이 「나」로 표시된다. `PartyMappers.swift` 의 `toUser` 가 같은 가드를 쓰는 이유다.
    ///
    /// ### 두 종류의 「없는 사람」을 다르게 접는다
    /// 서버가 **탈퇴**를 알리는 방식은 `publicId` 를 그대로 주고 이름만
    /// `WithdrawnMemberNames.SERVER_DELETED` 로 가리는 것이다 — 앱이 다시 치환하지 않고 그대로
    /// 흘려보낸다. **요약 자체가 없는** 멤버(세 필드 전부 null)에만 앱이
    /// `WithdrawnMemberNames.NO_SUMMARY` 를 채우고, 그때는 식별자가 빈 문자열이라 화면이
    /// 「탭 불가」로 다룰 근거가 된다. 두 경우를 한 문자열로 합치면 「프로필로 들어갈 수 있는가」가
    /// 사라진다 — `MemberDisplay` 주석의 표가 같은 구분을 적어 두었다.
    public func toRideRecordMember(currentUuid: String?) -> RideRecordMember {
        RideRecordMember(
            id: publicId ?? "",
            nickname: nickname ?? WithdrawnMemberNames.NO_SUMMARY,
            imageUrl: imageUrl,
            isMe: publicId != nil && publicId == currentUuid
        )
    }
}
