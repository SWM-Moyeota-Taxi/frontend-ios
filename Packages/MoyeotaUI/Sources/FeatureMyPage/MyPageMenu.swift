import PresentationCore

// 35 마이페이지 메뉴의 **구성 규칙** — 어떤 행이 어느 그룹에 생기는가.
//
// 화면(`MyPageScreen`)에서 떼어 둔 이유: 「주소가 없으면 행이 사라지고, 행이 다 사라지면 그룹도
// 사라진다」는 규칙은 눈으로 확인하려면 **값을 바꿔 다시 빌드해야** 하는 종류다(실제로 QA 가
// 그렇게 돌렸다 — `_workspace/113_qa-verifier_report.md` §B8). 순수 함수로 두면 테스트가 고정한다.

/// 그룹 머리말. 테스트와 화면이 같은 값을 보게 한 곳에 둔다.
enum MyPageGroupLabel {
    /// 지난 탑승 기록. 「설정」 위에 따로 둔 이유는 `myPageGroups` 주석에 있다.
    static let RIDES = "탑승"
    static let SETTINGS = "설정"
    static let INFO = "안내"
    static let ACCOUNT = "계정"
}

/// 「계정」 카드 아래 한 줄. **「탈퇴하면」으로 시작하는 것이 중요하다** — 로그아웃과 탈퇴가 한 카드에
/// 들어오면서 주어가 없는 문장("계정과 저장한 정보가 사라지고…")은 바로 위의 로그아웃에까지
/// 걸리는 말로 읽힌다. 로그아웃은 아무것도 지우지 않는다.
let ACCOUNT_CARD_CAPTION = "탈퇴하면 계정과 저장한 정보가 사라지고 되돌릴 수 없어요"

/// 행을 눌렀을 때 일어나는 일. **주소를 행이 들고 있다**(`openWeb`·`sendMail`).
///
/// 화면이 다시 nil 을 확인할 필요가 없어지고, 「개인정보 처리방침 행이 PRIVACY_URL 로 나가는가」를
/// 단위 테스트가 값으로 검사할 수 있다. 외부 이동 수단은 화면이 `PresentationCore/ExternalIntents` 로
/// 옮긴다 — 이 파일은 UIKit 을 모른다.
enum MyPageAction: Equatable, Sendable {

    /// OS 앱 알림 설정 (앱 밖). 앱 안 토글을 두지 않는 이유는 `openAppNotificationSettings` 참고.
    case notificationSettings

    /// 브라우저로 공개 페이지 열기 (앱 밖).
    case openWeb(url: String)

    /// 메일 앱으로 문의 열기 (앱 밖).
    case sendMail(address: String)

    /// 34 지난 탑승 기록 (앱 안). `GET /api/v1/users/me/parties` 로 하차까지 끝난 탑승만 받는다.
    ///
    /// 2026-11-01 에 서버가 이 엔드포인트를 주면서 생긴 행이다 — 그전까지는 「완료 방 목록 API 가
    /// 없다」가 이유여서 행 자체를 두지 않았다(`docs/BACKEND-GAP-CLEANUP.md` §1).
    case rideHistory

    /// 확인 다이얼로그 → 세션 정리 → 04a 로그인 (앱 안).
    case logout

    /// 37 회원 탈퇴 (앱 안).
    case deleteAccount
}

/// 행 오른쪽 기호. 이 화면의 규칙은 **↗ = 앱 밖으로 나간다, › = 앱 안에서 다음 단계로 간다** 다.
///
/// 아이콘 세트가 없는 앱이라 행마다 뜻이 다른 그림을 붙일 수 없다. 대신 이 두 기호에만 뜻을 주고
/// 나머지는 글자로 말한다 — 레퍼런스 앱처럼 행마다 아이콘을 두려면 아이콘 자산이 먼저 있어야 한다.
enum MyPageRowMark: Equatable, Sendable {
    case external
    case chevron
}

struct MyPageRow: Equatable, Sendable {
    var text: String
    var action: MyPageAction
    var mark: MyPageRowMark
    /// 되돌릴 수 없는 행 — 빨간 글자. 한 카드 안에서 색이 다른 유일한 행이다.
    var danger: Bool

    init(text: String, action: MyPageAction, mark: MyPageRowMark, danger: Bool = false) {
        self.text = text
        self.action = action
        self.mark = mark
        self.danger = danger
    }
}

struct MyPageGroup: Equatable, Sendable {
    var label: String
    var rows: [MyPageRow]
    /// 카드 **아래** 한 줄 부연. nil 이면 그리지 않는다.
    var caption: String?

    init(label: String, rows: [MyPageRow], caption: String? = nil) {
        self.label = label
        self.rows = rows
        self.caption = caption
    }
}

/// 35 의 메뉴 그룹 목록. 순서가 화면 순서다 — 탑승 → 설정 → 안내 → 계정.
///
/// ### 왜 이 순서인가
/// 자주 쓰는 것이 위, 되돌릴 수 없는 것이 맨 아래다. 「안내」(약관·개인정보·문의)는 평소에 보지
/// 않지만 **찾을 때는 반드시 찾아야 하는** 묶음이라 계정보다 위에 둔다. 그룹 안에서도 같은 기준이다:
/// 개인정보 처리방침이 가장 많이 찾는 문서고(스토어 심사도 이 경로를 본다), 계정 카드는
/// 로그아웃 → 탈퇴 순으로 파괴적인 쪽이 아래다.
///
/// ### 「탑승」이 「설정」 안이 아니라 맨 위의 새 그룹인 이유 (2026-11-01)
/// 「설정」은 지금 `알림 설정` 한 행뿐이고 그건 **앱 밖**으로 나가는 행이다(`external`).
/// 지난 탑승 기록은 앱 안으로 들어가는 행(`chevron`)이라 성격이 반대고, 한 카드에 섞으면
/// 이 화면이 기호에 준 뜻(↗ = 앱 밖, › = 앱 안)이 카드 경계와 어긋나 읽힌다. 그리고 사용자가
/// 마이페이지에서 가장 자주 찾을 값이라 맨 위가 맞다 — 설정·약관은 「찾을 때만」 보는 것들이다.
///
/// ### 빈 그룹을 거르는 규칙은 하나다
/// 마지막 `filter` 한 줄이 **모든 그룹**에 적용된다. 「안내」만 특별히 처리하지 않는 이유는,
/// 나중에 다른 그룹이 조건부 행만 갖게 돼도 빈 카드가 생기지 않게 하기 위해서다.
/// (지금은 「설정」·「계정」의 행이 조건 없이 생기므로 「안내」만 사라질 수 있다.)
func myPageGroups(links: SupportLinkTargets) -> [MyPageGroup] {
    var infoRows: [MyPageRow] = []
    if let url = links.privacyUrl {
        infoRows.append(MyPageRow(text: "개인정보 처리방침", action: .openWeb(url: url), mark: .external))
    }
    if let url = links.termsUrl {
        infoRows.append(MyPageRow(text: "이용약관", action: .openWeb(url: url), mark: .external))
    }
    if let address = links.contactEmail {
        infoRows.append(MyPageRow(text: "문의하기", action: .sendMail(address: address), mark: .external))
    }

    let groups = [
        MyPageGroup(
            label: MyPageGroupLabel.RIDES,
            rows: [
                // 「내 탑승」이 아니라 **「지난」** 탑승 기록이다 — 예약 개념이 서버에 없는 지금
                // 「내 탑승」은 진행 중인 방까지 있을 것처럼 읽힌다(그게 예전 34 삭제 사유의 일부였다:
                // 「예정」 탭 + 35 와의 순환 링크). 진행 중인 방은 홈·탐색 배너가 보여 준다.
                MyPageRow(text: "지난 탑승 기록", action: .rideHistory, mark: .chevron),
            ]
        ),
        MyPageGroup(
            label: MyPageGroupLabel.SETTINGS,
            rows: [
                MyPageRow(text: "알림 설정", action: .notificationSettings, mark: .external),
            ]
        ),
        MyPageGroup(label: MyPageGroupLabel.INFO, rows: infoRows),
        MyPageGroup(
            label: MyPageGroupLabel.ACCOUNT,
            rows: [
                // 로그아웃이 탈퇴보다 훨씬 흔한 동작인데 예전엔 13sp 회색 글자 한 줄이었다 — 더 흔한
                // 기능이 더 작아 위계가 뒤집혀 있었다. 이제 탈퇴와 같은 56pt 카드 행이다.
                // 오탭 보호는 색(탈퇴만 빨강)과 확인 단계가 맡는다: 로그아웃은 확인 다이얼로그,
                // 탈퇴는 37 에서 비밀번호 + 또 한 번의 다이얼로그다.
                MyPageRow(text: "로그아웃", action: .logout, mark: .chevron),
                MyPageRow(text: "탈퇴하기", action: .deleteAccount, mark: .chevron, danger: true),
            ],
            caption: ACCOUNT_CARD_CAPTION
        ),
    ]
    return groups.filter { !$0.rows.isEmpty }
}
