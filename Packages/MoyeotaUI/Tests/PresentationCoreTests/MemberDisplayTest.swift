import MoyeotaDomain
import Testing
@testable import PresentationCore

/// `MemberDisplay` 의 멤버 표기 규칙 — 20 합류 확인 · 21 매칭 대기 · 22 탑승 상세 · 23 동승자 프로필이
/// **같은 데이터를 같은 문구로** 읽는지 못 박는다.
///
/// 가장 쉽게 저지를 수 있는 실수가 **탈퇴 판정을 `imageUrl == nil` 로 옮기는 것**이다 —
/// 서버는 한 번도 고른 적 없는 사용자에게도 기본 이미지의 전체 URL 을 주므로 그렇게 바꾸면 판정이 정확히 뒤집혀
/// **살아 있는 전원이 탈퇴 회원으로 표시된다.** 그래서 첫 테스트가 그 한 줄을 막는다.
///
/// ### 덮지 못하는 것
/// 아바타가 **실제로 사진을 그리는지**는 여기서 확인할 수 없다. 이 테스트는 순수 로직만 본다.
@Suite struct MemberDisplayTest {
    /// 멤버 한 명. 기본값은 **서버가 유저 요약을 찾은 멀쩡한 멤버**다.
    ///
    /// `imageUrl` 기본값을 nil 로 둔 건 **서버 모양이 그렇다는 뜻이 아니다**(서버는 기본 이미지의
    /// 전체 URL 을 준다). 아래 테스트들이 「사진 유무는 어느 판정에도 끼어들지 않는다」를 확인하기
    /// 위해 가장 불리한 값을 기본으로 깐 것이다.
    private func member(
        id: String = "u1",
        nickname: String = "성윤",
        verifiedLabel: String = "",
        rideCount: Int = 0,
        imageUrl: String? = nil,
        isMe: Bool = false
    ) -> User {
        User(
            id: id,
            nickname: nickname,
            verifiedLabel: verifiedLabel,
            rating: 0.0,
            rideCount: rideCount,
            imageUrl: imageUrl,
            isMe: isMe
        )
    }

    /// 유저 요약이 없는 멤버 — 서버가 publicId·nickname·imageUrl 을 전부 null 로 주고 매퍼가 이렇게 접는다.
    private func noSummary() -> User { member(id: "", nickname: WithdrawnMemberNames.NO_SUMMARY) }

    /// soft delete 된 사용자 — publicId 는 **살아 있고** 닉네임만 서버 상수로 가려진다.
    private func softDeleted() -> User { member(id: "u2", nickname: WithdrawnMemberNames.SERVER_DELETED) }

    // ─── 탈퇴 판정의 출처는 빈 id 하나다 ────────────────────────────────────────

    @Test("이미지가 없는 멤버를 탈퇴로 보지 않는다")
    func noImageIsNotWithdrawn() {
        #expect(!member(id: "u1", nickname: "성윤", imageUrl: nil).isWithdrawn)
    }

    @Test("사진을 고른 멤버와 안 고른 멤버의 탈퇴 판정이 같다")
    func pickedAndDefaultImageSame() {
        let picked = member(imageUrl: "https://cdn.moyeota.co.kr/profile/presets/01.png")
        let fallback = member(imageUrl: "https://cdn.moyeota.co.kr/profile/presets/default.png")

        #expect(!picked.isWithdrawn)
        #expect(!fallback.isWithdrawn)
    }

    @Test("유저 요약이 없는 멤버는 탈퇴로 본다")
    func noSummaryIsWithdrawn() {
        #expect(noSummary().isWithdrawn)
    }

    /// 식별자가 살아 있어 프로필로 들어갈 수 있다 — 막아야 하는 건 이름으로 부르는 것뿐이다.
    @Test("soft delete 된 사용자는 탈퇴 판정에 걸리지 않는다")
    func softDeletedIsNotWithdrawn() {
        #expect(!softDeleted().isWithdrawn)
    }

    /// 사진이 있어도 요약이 없으면 탈퇴다 — 판정이 imageUrl 로 새지 않았는지 반대 방향에서 확인한다.
    @Test("사진이 있어도 id 가 비면 탈퇴로 본다")
    func imageWithoutIdIsWithdrawn() {
        let weird = member(
            id: "",
            nickname: WithdrawnMemberNames.NO_SUMMARY,
            imageUrl: "https://cdn.moyeota.co.kr/profile/presets/07.png"
        )

        #expect(weird.isWithdrawn)
    }

    // ─── 이름으로 부를 수 있는가 ────────────────────────────────────────────────

    @Test("멀쩡한 닉네임은 이름으로 부를 수 있다")
    func normalNicknameCallable() {
        #expect(member(nickname: "성윤").hasCallableName)
    }

    /// 두 자리값 모두 **멀쩡한 문자열**이라 공백 검사로는 걸러지지 않는다.
    @Test("탈퇴를 가리키는 두 자리값은 이름으로 부를 수 없다")
    func withdrawnNamesNotCallable() {
        #expect(!softDeleted().hasCallableName)
        #expect(!noSummary().hasCallableName)
    }

    @Test("빈 닉네임은 이름으로 부를 수 없다")
    func blankNotCallable() {
        #expect(!member(nickname: "   ").hasCallableName)
    }

    // ─── 목록에 찍는 이름 ───────────────────────────────────────────────────────

    @Test("멀쩡한 멤버는 닉네임을 그대로 찍는다")
    func displaysNickname() {
        #expect(member(nickname: "성윤").displayNickname == "성윤")
    }

    @Test("요약이 없는 멤버는 자리값을 찍는다")
    func noSummaryDisplaysPlaceholder() {
        #expect(noSummary().displayNickname == WithdrawnMemberNames.NO_SUMMARY)
    }

    /// 닉네임만 빈 응답도 같은 자리값으로 접는다 — 이름 칸이 비어 보이는 줄을 만들지 않는다.
    @Test("id 는 있고 닉네임만 빈 멤버도 자리값을 찍는다")
    func emptyNicknameDisplaysPlaceholder() {
        #expect(member(nickname: "").displayNickname == WithdrawnMemberNames.NO_SUMMARY)
    }

    /// soft delete 는 **서버가 가린 문구를 그대로 쓴다.** 앱 자리값으로 바꿔 쓰면 같은 사람이 화면마다
    /// 달라 보이고, 서버가 문구를 바꿨을 때 두 문구가 섞여 뜬다.
    @Test("soft delete 된 사용자는 서버가 가린 문구를 그대로 찍는다")
    func softDeletedDisplaysServerName() {
        #expect(softDeleted().displayNickname == WithdrawnMemberNames.SERVER_DELETED)
    }

    // ─── 탑승 횟수 ──────────────────────────────────────────────────────────────

    /// 서버 rideCount 는 FINISHED 파티 수라 신규 가입자는 항상 0 이다 — 빈 실적처럼 읽히면 안 된다.
    @Test("탑승 0회는 첫 탑승으로 쓴다")
    func zeroRidesFirstRide() {
        #expect(member(rideCount: 0).rideCountLabel == "첫 탑승")
    }

    @Test("음수 탑승 횟수도 첫 탑승으로 접는다")
    func negativeRidesFirstRide() {
        #expect(member(rideCount: -1).rideCountLabel == "첫 탑승")
    }

    @Test("탑승 횟수가 있으면 회수를 쓴다")
    func ridesCounted() {
        #expect(member(rideCount: 1).rideCountLabel == "탑승 1회")
        #expect(member(rideCount: 12).rideCountLabel == "탑승 12회")
    }

    // ─── 인증 라벨 ──────────────────────────────────────────────────────────────

    /// 서버 badgeId 가 아직 항상 null 이라 대부분 이 경우다 — 빈 값을 그냥 비워 두면 「인증된 사람」으로 읽힌다.
    @Test("인증 라벨이 비면 중립 문구를 쓴다")
    func blankVerifiedLabelNeutral() {
        #expect(member(verifiedLabel: "").verifiedLabelOrNone == "인증 정보 없음")
        #expect(member(verifiedLabel: "   ").verifiedLabelOrNone == "인증 정보 없음")
    }

    @Test("인증 라벨이 있으면 그대로 쓴다")
    func verifiedLabelKept() {
        #expect(member(verifiedLabel: "성결대 인증").verifiedLabelOrNone == "성결대 인증")
    }

    // ─── 방장 표기 (원본에 테스트가 없는 규칙) ──────────────────────────────────

    @Test("내 줄에는 방장 배지를 그리지 않는다")
    func hostBadgeSkipsMe() {
        var me = member(id: "me", isMe: true)
        me.isHost = true
        var other = member(id: "other")
        other.isHost = true
        #expect(!me.showsHostBadge)
        #expect(other.showsHostBadge)
        #expect(!member().showsHostBadge)
    }

    @Test("이름으로 부를 수 없는 방장은 nil 이다")
    func hostDisplayNameRules() {
        var host = member(id: "h", nickname: "길동")
        host.isHost = true
        var deletedHost = softDeleted()
        deletedHost.isHost = true
        var missingHost = noSummary()
        missingHost.isHost = true
        #expect([member(), host].hostDisplayNameOrNull() == "길동")
        #expect([deletedHost].hostDisplayNameOrNull() == nil)
        #expect([missingHost].hostDisplayNameOrNull() == nil)
        #expect([member()].hostDisplayNameOrNull() == nil)
    }

    @Test("이니셜은 첫 글자이고 부를 이름이 없으면 물음표다")
    func avatarInitialRules() {
        #expect(member(nickname: "성윤").avatarInitial == "성")
        #expect(noSummary().avatarInitial == "?")
        #expect(member(nickname: " ").avatarInitial == "?")
    }
}
