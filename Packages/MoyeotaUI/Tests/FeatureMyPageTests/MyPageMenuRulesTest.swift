import PresentationCore
import Testing
@testable import FeatureMyPage

/// 35 마이페이지 메뉴 구성 규칙.
///
/// **여기서 테스트가 꼭 필요한 이유:** 「주소가 없으면 행이 사라진다」는 동작을 눈으로 확인하려면
/// 소스의 상수를 바꿔 다시 빌드해야 한다. 실제로 QA 가 그렇게 돌렸고, 되돌리다 사고가 날 뻔했다
/// (`_workspace/113_qa-verifier_report.md` §O4 — 그 파일이 untracked 라 `git checkout` 이 안 됐다).
/// 이제는 값으로 넣어 본다.
///
/// 주소가 운영 값으로 채워진 뒤에도(2026-10-14) **빈 상태를 계속 테스트한다** — 페이지가 내려가면
/// 그 길로 긴급 복구하게 되고, 그때 레이아웃이 깨지면 고칠 시간이 없다.
@Suite struct MyPageMenuRulesTest {

    private let allLinks = SupportLinkTargets(
        privacyUrl: "https://example.com/privacy/",
        termsUrl: "https://example.com/terms/",
        contactEmail: "help@example.com"
    )

    // ─────────────────────────── 그룹 구성 ───────────────────────────

    @Test("주소가 다 있으면 탑승 설정 안내 계정 네 그룹이 이 순서로 선다")
    func fourGroupsInOrder() {
        let groups = myPageGroups(links: allLinks)

        #expect(
            groups.map(\.label) == [
                MyPageGroupLabel.RIDES,
                MyPageGroupLabel.SETTINGS,
                MyPageGroupLabel.INFO,
                MyPageGroupLabel.ACCOUNT,
            ]
        )
    }

    /// 빈 카드·머리말만 남은 그룹은 "고장난 메뉴"로 보인다. 그룹마다가 아니라 한 규칙으로 막는다.
    @Test("행이 없는 그룹은 아예 만들지 않는다")
    func noEmptyGroups() {
        for links in [allLinks, SupportLinkTargets.None, SupportLinkTargets(termsUrl: nil)] {
            for group in myPageGroups(links: links) {
                #expect(!group.rows.isEmpty, "행 없는 그룹이 남았다: \(group.label)")
            }
        }
    }

    // ─────────────────────────── 주소가 없을 때 ───────────────────────────

    /// 셋 다 비면 「안내」는 **머리말과 카드까지** 사라진다. 「준비 중」 자리표시를 두지 않는 이유는
    /// 눌러도 아무 일이 없는 행이 고장으로 읽히고, 스토어 심사도 죽은 링크를 잡기 때문이다.
    @Test("주소가 전부 없으면 안내 그룹이 통째로 사라진다")
    func infoGroupDisappears() {
        let groups = myPageGroups(links: SupportLinkTargets.None)

        #expect(groups.group(MyPageGroupLabel.INFO) == nil, "안내 카드가 빈 채로 남았다")
        // 주소와 무관한 세 그룹은 그대로 있어야 한다 — 로그아웃·탈퇴가 사라지면 갇힌다.
        #expect(groups.rowTexts(MyPageGroupLabel.RIDES) == ["지난 탑승 기록"])
        #expect(groups.rowTexts(MyPageGroupLabel.SETTINGS) == ["알림 설정"])
        #expect(groups.rowTexts(MyPageGroupLabel.ACCOUNT) == ["로그아웃", "탈퇴하기"])
    }

    /// 세 행은 서로 독립이다 — 하나가 비어도 나머지는 남는다.
    @Test("주소 하나가 없으면 그 행만 빠진다")
    func onlyMissingRowDrops() {
        var noPrivacy = allLinks
        noPrivacy.privacyUrl = nil
        #expect(myPageGroups(links: noPrivacy).rowTexts(MyPageGroupLabel.INFO) == ["이용약관", "문의하기"])

        var noTerms = allLinks
        noTerms.termsUrl = nil
        #expect(myPageGroups(links: noTerms).rowTexts(MyPageGroupLabel.INFO) == ["개인정보 처리방침", "문의하기"])

        var noContact = allLinks
        noContact.contactEmail = nil
        #expect(myPageGroups(links: noContact).rowTexts(MyPageGroupLabel.INFO) == ["개인정보 처리방침", "이용약관"])
    }

    @Test("주소가 없으면 그 주소로 가는 동작도 사라진다")
    func noExternalActionsWithoutLinks() {
        let actions = myPageGroups(links: SupportLinkTargets.None).flatMap(\.rows).map(\.action)

        let external = actions.filter { action in
            switch action {
            case .openWeb, .sendMail: true
            default: false
            }
        }
        #expect(external.isEmpty, "주소 없는데 외부 이동 동작이 남았다: \(actions)")
    }

    // ─────────────────────────── 어느 행이 어디로 가는가 ───────────────────────────

    @Test("안내 행은 각자 받은 주소로 나간다")
    func infoRowsUseOwnAddress() throws {
        let rows = try #require(myPageGroups(links: allLinks).group(MyPageGroupLabel.INFO)).rows

        #expect(rows[0].action == .openWeb(url: try #require(allLinks.privacyUrl)))
        #expect(rows[1].action == .openWeb(url: try #require(allLinks.termsUrl)))
        #expect(rows[2].action == .sendMail(address: try #require(allLinks.contactEmail)))
    }

    /// 기본값은 운영 주소다 — 화면이 아무것도 넘기지 않아도 운영 값으로 선다.
    @Test("기본 주소 묶음은 SupportLinks 를 그대로 쓴다")
    func defaultTargetsUseSupportLinks() {
        let targets = SupportLinkTargets()

        #expect(targets.privacyUrl == SupportLinks.PRIVACY_URL)
        #expect(targets.termsUrl == SupportLinks.TERMS_URL)
        #expect(targets.contactEmail == SupportLinks.CONTACT_EMAIL)
    }

    /// 주소가 채워져 있다면 **모양이 맞아야** 한다. 값 자체를 못 박지는 않는다 —
    /// 페이지가 내려갔을 때 nil 로 비우는 길이 테스트 때문에 막히면 안 된다(`SupportLinks` 주석).
    @Test("채워진 운영 주소는 공개 https 주소와 메일 형식이다")
    func filledLinksAreWellFormed() {
        let urls = [SupportLinks.PRIVACY_URL, SupportLinks.TERMS_URL, SupportLinks.ACCOUNT_DELETION_URL]
            .compactMap { $0 }
        for url in urls {
            #expect(url.hasPrefix("https://"), "로그인 없이 열리는 https 주소여야 한다: \(url)")
            #expect(!url.contains(" "), "주소에 공백이 있다: \(url)")
        }
        if let email = SupportLinks.CONTACT_EMAIL {
            #expect(email.contains("@") && !email.contains(" "), "메일 주소가 아니다: \(email)")
        }
    }

    // ─────────────────────────── 기호 규칙 (↗ / ›) ───────────────────────────

    /// 이 화면의 기호는 뜻이 둘뿐이다 — ↗ 는 앱을 벗어나고, › 는 앱 안에서 다음 단계로 간다.
    /// 아이콘 세트가 없는 앱이라 이 두 기호가 유일한 비언어 단서다. 어긋나면 규칙이 무의미해진다.
    @Test("앱 밖으로 나가는 행은 전부 외부 표시다")
    func leavingRowsAreExternal() {
        for row in myPageGroups(links: allLinks).flatMap(\.rows) {
            let leavesApp = switch row.action {
            case .notificationSettings, .openWeb, .sendMail: true
            case .rideHistory, .logout, .deleteAccount: false
            }
            let expected: MyPageRowMark = leavesApp ? .external : .chevron
            #expect(row.mark == expected, "\(row.text)")
        }
    }

    // ─────────────────────────── 계정 카드 ───────────────────────────

    /// 로그아웃과 탈퇴가 **같은 카드에 나란히** 있다(레퍼런스 구조). 로그아웃이 13sp 회색 글자였던
    /// 동안에는 훨씬 자주 쓰는 기능이 더 작아 위계가 뒤집혀 있었다. 파괴적인 쪽이 아래다.
    @Test("계정 카드는 로그아웃 다음에 탈퇴하기다")
    func accountCardOrder() throws {
        let rows = try #require(myPageGroups(links: allLinks).group(MyPageGroupLabel.ACCOUNT)).rows

        #expect(rows.map(\.text) == ["로그아웃", "탈퇴하기"])
        #expect(rows[0].action == .logout)
        #expect(rows[1].action == .deleteAccount)
    }

    /// 카드 안에서 빨강이 하나뿐이라야 경고로 읽힌다. 로그아웃은 되돌릴 수 있는 동작이다.
    @Test("탈퇴하기만 빨간 행이다")
    func onlyDeleteIsDanger() {
        let danger = myPageGroups(links: allLinks).flatMap(\.rows).filter(\.danger)

        #expect(danger.map(\.text) == ["탈퇴하기"])
    }

    /// 부연은 **「탈퇴하면」으로 시작해야 한다.** 두 행이 한 카드에 들어오면서, 주어 없는 문장은
    /// 바로 위 로그아웃에까지 걸리는 말로 읽힌다 — 로그아웃은 아무것도 지우지 않는다.
    @Test("계정 카드 부연은 탈퇴를 가리킨다")
    func captionPointsAtDeletion() throws {
        let account = try #require(myPageGroups(links: allLinks).group(MyPageGroupLabel.ACCOUNT))
        let caption = try #require(account.caption)

        #expect(caption == ACCOUNT_CARD_CAPTION)
        #expect(caption.hasPrefix("탈퇴하면"), "\(caption)")
        #expect(caption.contains("되돌릴 수 없"), "\(caption)")
    }

    /// 부연은 「계정」 카드에만 있다 — 설정·안내 행에 경고를 달 이유가 없다.
    @Test("부연은 계정 카드에만 붙는다")
    func captionOnlyOnAccount() {
        for group in myPageGroups(links: allLinks) where group.label != MyPageGroupLabel.ACCOUNT {
            #expect(group.caption == nil, "\(group.label) 그룹에 부연이 붙었다")
        }
    }

    // ─────────────────────────── 없는 기능을 만들지 않는다 ───────────────────────────

    /// 서버 API 가 없는 메뉴는 행을 만들지 않는다(`docs/BACKEND-GAP-CLEANUP.md`).
    /// 레퍼런스 앱의 「로그인 수단 안내」도 같은 이유로 없다 — 이 화면이 아는 서버 값은 이름뿐이다.
    ///
    /// ### 금지어에서 「탑승 기록」이 빠진 이유 (2026-11-01)
    /// **전제가 깨졌다 — 서버가 이제 준다.** `GET /api/v1/users/me/parties` 가 생겨
    /// 하차까지 끝난 탑승 기록을 돌려준다(실측: 기록 2건, `dropoffTime` 내림차순 + 커서 페이징).
    /// 그래서 「지난 탑승 기록」 행이 들어왔고(34 재도입, `docs/BACKEND-GAP-CLEANUP.md` §6)
    /// 이 목록에 그 말이 남아 있으면 **행을 추가하는 순간 이 테스트가 빨개진다.**
    ///
    /// 나머지 다섯은 **여전히 서버에 없다** — 고객센터(문의 접수 API), 매너 점수·마일리지(평가 API),
    /// 결제(요금 확정·결제 API), 로그인 수단. 그쪽은 계속 막는다.
    ///
    /// 반대로 `AccountDeleteRulesTest` 의 「탑승 기록」 금지는 **성격이 다르니 건드리지 마라** —
    /// 그건 탈퇴 경고가 「탑승 기록도 지워진다」고 거짓말하지 못하게 막는 것이고, 서버는 실제로
    /// 기록을 지우지 않는다(`docs/BACKEND-GAP-CLEANUP.md` §6).
    @Test("서버가 주지 않는 것으로 행을 만들지 않는다")
    func noRowsWithoutServerSupport() {
        let texts = myPageGroups(links: allLinks).flatMap(\.rows).map(\.text)

        for absent in ["고객센터", "매너 점수", "마일리지", "결제", "로그인 수단"] {
            #expect(!texts.contains { $0.contains(absent) }, "없는 기능 행이 생겼다: \(absent)")
        }
        // 행 이름이 겹치면 사용자가 같은 것을 두 군데서 찾는다
        #expect(texts.count == Set(texts).count)
    }

    // ─────────────────────────── 지난 탑승 기록 (2026-11-01) ───────────────────────────

    /// 34 로 들어가는 입구가 **있어야** 한다. 서버에 `GET /api/v1/users/me/parties` 가 생겨
    /// 되살린 행이고(`docs/BACKEND-GAP-CLEANUP.md` §6), 이 행이 없으면 끝난 탑승을
    /// **다시 볼 길이 앱 안에 하나도 없다** — 33 도착 완료를 한 번 보고 끝이다.
    ///
    /// 기호가 `chevron`(앱 안)인 것도 함께 못 박는다. `external`(↗)로 잘못 달면 사용자는
    /// 브라우저가 열릴 줄 알고 누른다 — 이 화면의 기호 규칙이 거짓이 된다.
    @Test("지난 탑승 기록 행이 마이페이지에 있다")
    func rideHistoryRowExists() throws {
        let rows = try #require(myPageGroups(links: allLinks).group(MyPageGroupLabel.RIDES)).rows

        #expect(rows.map(\.text) == ["지난 탑승 기록"])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.action == .rideHistory)
        #expect(row.mark == .chevron)
        #expect(!row.danger, "기록 보기는 되돌릴 수 없는 동작이 아니다")
    }

    /// 행 이름이 「내 탑승」이 아니라 **「지난」 탑승 기록**이어야 한다.
    ///
    /// 예약 개념이 서버에 없는 지금 「내 탑승」은 진행 중인 방까지 있을 것처럼 읽힌다 — 그게
    /// 예전 34 삭제 사유의 일부였다(「예정」 탭 + 35 와의 순환 링크). 진행 중인 방은 이
    /// 엔드포인트에 **들어오지 않으므로**(실측) 들어간 사용자는 빈 목록을 보고 자기 방이
    /// 사라졌다고 읽는다.
    @Test("행 이름이 진행 중인 방까지 보여 줄 것처럼 읽히지 않는다")
    func rideRowNameSaysPast() throws {
        let rows = try #require(myPageGroups(links: allLinks).group(MyPageGroupLabel.RIDES)).rows
        #expect(rows.count == 1)
        let text = try #require(rows.first).text

        #expect(text.hasPrefix("지난"), "\(text)")
        #expect(!text.contains("예정"), "「예정」은 서버에 없는 개념이다: \(text)")
    }
}

private extension Array where Element == MyPageGroup {
    func group(_ label: String) -> MyPageGroup? {
        first { $0.label == label }
    }

    func rowTexts(_ label: String) -> [String] {
        group(label)?.rows.map(\.text) ?? []
    }
}
